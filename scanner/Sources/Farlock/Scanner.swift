import Foundation
import CoreBluetooth

// BLE scanner wrapper around CBCentralManager. Emits RSSI samples for the
// configured target to a callback, and optionally writes a debug snapshot
// JSON to disk.
//
// Matching rules (any match wins):
//   • Config.targetName       — exact match of peripheral.name or cached name
//   • Config.targetUuid       — CBPeripheral.identifier.uuidString
//   • Config.targetMacAddr    — resolved static MAC (via LEDeviceLookup)
//
// Active mode: if Config.activeMode is true, once the target is first seen we
// connect to it and call readRSSI() on an interval. Falls back to passive
// scanning if the connection stalls.

final class Scanner: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Sample {
        let rssi: Int
        let name: String?
        let macAddr: String?
        let uuid: UUID
        let at: Date
    }

    private let cfg: Config
    private let logger: FileLogger
    private let lookup = LEDeviceLookup()
    private let queue = DispatchQueue(label: "proximity-scanner.ble")

    // Callbacks to the AppController.
    private let onTargetSample: (Sample?) -> Void
    private let onDiscovery: (String) -> Void  // arbitrary human-readable info

    private var central: CBCentralManager!
    private var seen: [UUID: Sample] = [:]
    private var targetUuid: UUID?
    private var activePeripheral: CBPeripheral?
    private var activeReadTimer: DispatchSourceTimer?
    private var activeLastReadAt: Date?
    private var passiveTickTimer: DispatchSourceTimer?

    // When the AppController is showing the warn overlay, it flips this on so
    // the Scanner pushes every single RSSI update through (instead of waiting
    // for the next poll tick). That makes the "come back and the countdown
    // cancels" path responsive within ~2 s (active mode) or the next
    // advertisement (passive).
    var emitAllSamples: Bool = false

    // Optional debug snapshot writer.
    private let snapshotPath: String?
    private var snapshotTimer: DispatchSourceTimer?

    init(cfg: Config,
         logger: FileLogger,
         snapshotPath: String? = nil,
         onTargetSample: @escaping (Sample?) -> Void,
         onDiscovery: @escaping (String) -> Void)
    {
        self.cfg = cfg
        self.logger = logger
        self.snapshotPath = snapshotPath
        self.onTargetSample = onTargetSample
        self.onDiscovery = onDiscovery
        super.init()
    }

    func start() {
        central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])

        // Periodic passive "tick" that runs on the main detection cadence.
        // Emits a nil sample if we have not received any reading since the
        // last tick — lets the Detector's signal-lost timer run.
        let tick = DispatchSource.makeTimerSource(queue: queue)
        tick.schedule(deadline: .now() + cfg.pollIntervalSeconds,
                      repeating: cfg.pollIntervalSeconds)
        tick.setEventHandler { [weak self] in self?.emitLatestSample() }
        tick.resume()
        passiveTickTimer = tick

        if let path = snapshotPath {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1.0, repeating: 1.0)
            t.setEventHandler { [weak self] in self?.writeSnapshot(to: path) }
            t.resume()
            snapshotTimer = t
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            logger.log("Bluetooth powered on; starting scan")
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        case .poweredOff:
            logger.log("Bluetooth powered off")
        case .unauthorized:
            logger.log("Bluetooth unauthorized — grant Bluetooth access in System Settings > Privacy & Security > Bluetooth, then relaunch")
        case .unsupported:
            logger.log("Bluetooth LE unsupported on this hardware; exiting")
            exit(3)
        default:
            logger.log("Bluetooth state \(central.state.rawValue); waiting")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let rssiValue = RSSI.intValue
        if rssiValue == 127 { return }

        let info = lookup.lookup(uuid: peripheral.identifier.uuidString)
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? info?.name
        let mac = info?.macAddr

        let sample = Sample(
            rssi: rssiValue,
            name: name ?? seen[peripheral.identifier]?.name,
            macAddr: mac ?? seen[peripheral.identifier]?.macAddr,
            uuid: peripheral.identifier,
            at: Date()
        )
        seen[peripheral.identifier] = sample

        if isTarget(sample) {
            if targetUuid == nil {
                targetUuid = peripheral.identifier
                onDiscovery("target matched: \(peripheral.identifier) name=\(name ?? "nil") mac=\(mac ?? "nil")")
                if cfg.activeMode && activePeripheral == nil {
                    activePeripheral = peripheral
                    peripheral.delegate = self
                    central.connect(peripheral, options: nil)
                }
            }
            if emitAllSamples {
                onTargetSample(sample)
            }
            // Otherwise let the periodic tick pick it up from `seen[]`.
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === activePeripheral else { return }
        logger.log("active-mode: connected to \(peripheral.identifier)")
        activeLastReadAt = Date()
        peripheral.readRSSI()

        activeReadTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + cfg.activeReadInterval,
                       repeating: cfg.activeReadInterval)
        timer.setEventHandler { [weak self, weak peripheral] in
            self?.activeTick(peripheral: peripheral)
        }
        timer.resume()
        activeReadTimer = timer
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral === activePeripheral else { return }
        logger.log("active-mode: connect failed: \(error?.localizedDescription ?? "unknown")")
        tearDownActive()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral === activePeripheral else { return }
        logger.log("active-mode: disconnected: \(error?.localizedDescription ?? "clean")")
        tearDownActive()
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard peripheral === activePeripheral else { return }
        if let err = error {
            logger.log("active-mode: readRSSI error: \(err.localizedDescription)")
            return
        }
        let value = RSSI.intValue
        if value == 127 { return }
        activeLastReadAt = Date()

        let info = lookup.lookup(uuid: peripheral.identifier.uuidString)
        let prev = seen[peripheral.identifier]
        let sample = Sample(
            rssi: value,
            name: prev?.name ?? peripheral.name ?? info?.name,
            macAddr: prev?.macAddr ?? info?.macAddr,
            uuid: peripheral.identifier,
            at: Date()
        )
        seen[peripheral.identifier] = sample
        if emitAllSamples {
            onTargetSample(sample)
        }
    }

    // MARK: Target matching

    private func isTarget(_ s: Sample) -> Bool {
        if let want = cfg.targetName, let have = s.name, want == have { return true }
        if let want = cfg.targetUuid,
           s.uuid.uuidString.replacingOccurrences(of: "-", with: "").uppercased()
           == want.replacingOccurrences(of: "-", with: "").uppercased() {
            return true
        }
        if let want = cfg.targetMacAddr, let have = s.macAddr,
           normalizeMac(want) == normalizeMac(have) {
            return true
        }
        return false
    }

    private func normalizeMac(_ s: String) -> String {
        return s.uppercased()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    // MARK: Active mode lifecycle

    private func activeTick(peripheral: CBPeripheral?) {
        guard let peripheral = peripheral, peripheral === activePeripheral else { return }
        let stall = Date().timeIntervalSince(activeLastReadAt ?? .distantPast)
        if stall > cfg.activeStallTimeout {
            logger.log(String(format:
                "active-mode: stall %.1fs exceeded %.1fs; reconnecting",
                stall, cfg.activeStallTimeout))
            central.cancelPeripheralConnection(peripheral)
            return
        }
        switch peripheral.state {
        case .connected:
            peripheral.readRSSI()
        case .disconnected, .disconnecting:
            central.connect(peripheral, options: nil)
        default:
            break
        }
    }

    private func tearDownActive() {
        activeReadTimer?.cancel()
        activeReadTimer = nil
        activeLastReadAt = nil
        activePeripheral = nil
        // Passive scan is still running; we'll rediscover and retry.
    }

    // MARK: Passive tick — emits nil if no sample has been received recently.

    private func emitLatestSample() {
        guard let uuid = targetUuid, let last = seen[uuid] else {
            // No target ever matched. Still emit nil so the detector can
            // pick up its initial state.
            onTargetSample(nil)
            return
        }
        // Consider "recent" = within the poll interval * 2. Otherwise emit
        // nil so the signal-lost timer can count.
        let maxAge = cfg.pollIntervalSeconds * 2
        if Date().timeIntervalSince(last.at) <= maxAge {
            onTargetSample(last)
        } else {
            onTargetSample(nil)
        }
    }

    // MARK: Debug snapshot writer

    private func writeSnapshot(to path: String) {
        let now = Date()
        let ttl: TimeInterval = 30
        let fresh = seen.filter { now.timeIntervalSince($0.value.at) < ttl }
        var devices: [String: [String: Any]] = [:]
        for (_, s) in fresh {
            var entry: [String: Any] = [
                "address": s.uuid.uuidString,
                "rssi": s.rssi,
                "lastSeen": s.at.timeIntervalSince1970,
            ]
            if let n = s.name { entry["name"] = n }
            if let m = s.macAddr { entry["macAddr"] = m }
            devices[s.uuid.uuidString] = entry
        }
        let payload: [String: Any] = [
            "timestamp": now.timeIntervalSince1970,
            "devices": devices,
        ]
        do {
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            logger.log("snapshot write failed: \(error)")
        }
    }
}
