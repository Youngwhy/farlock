import Foundation
import AppKit

// Orchestrates Scanner -> Detector -> (WarnOverlay + Locker). Lives on the
// main queue because AppKit (NSWindow, NSTimer) must be driven from there.

final class AppController {
    private let cfg: Config
    private let logger: FileLogger

    private let wifi = WifiMonitor()
    private var scanner: Scanner!
    private var detector: Detector!
    private var locker: Locker!
    private var sleepWake: SleepWakeMonitor!

    private var warn: WarnOverlay?
    private var lastLockReason: String = "unknown"
    private var lockWatchdog: Timer?

    // If commitLock fires but screensLocked never arrives, lockPending would
    // stay true forever and block every future scheduleLock. This watchdog
    // unsticks that state after a grace period.
    private let lockWatchdogSeconds: TimeInterval = 10.0

    init(cfg: Config, logger: FileLogger) {
        self.cfg = cfg
        self.logger = logger
    }

    func start() {
        locker = Locker(logger: logger)
        detector = Detector(
            cfg: cfg, logger: logger,
            trustedWifiCheck: { [weak self] in
                guard let self = self else { return nil }
                return self.wifi.trustedSSID(in: self.cfg.trustedWifiSSIDs)
            }
        )

        sleepWake = SleepWakeMonitor { [weak self] event in
            self?.handleSleepWake(event)
        }
        sleepWake.start()

        scanner = Scanner(
            cfg: cfg,
            logger: logger,
            snapshotPath: nil,  // disabled in unified build; enable for debugging
            onTargetSample: { [weak self] sample in
                // Bounce to main so state mutations are single-threaded.
                DispatchQueue.main.async { self?.consumeSample(sample) }
            },
            onDiscovery: { [weak self] msg in
                self?.logger.log(msg)
            }
        )
        scanner.start()

        logger.log("AppController started; target=\(targetDescription())")
    }

    private func targetDescription() -> String {
        var parts: [String] = []
        if let n = cfg.targetName { parts.append("name=\(n)") }
        if let u = cfg.targetUuid { parts.append("uuid=\(u)") }
        if let m = cfg.targetMacAddr { parts.append("mac=\(m)") }
        return parts.isEmpty ? "<none — set targetName/targetUuid/targetMacAddr>" : parts.joined(separator: " ")
    }

    // MARK: Sample handling

    private func consumeSample(_ sample: Scanner.Sample?) {
        let decision = detector.evaluate(rssi: sample?.rssi)
        let prefix: String = {
            if let s = sample {
                return "rssi=\(s.rssi) name=\(s.name ?? "nil")"
            } else {
                return "rssi=nil"
            }
        }()
        switch decision {
        case .stay(let status):
            logger.log("tick: \(prefix) \(status)")
        case .backInRange(let status):
            logger.log("back in range: \(prefix) \(status)")
            if let w = warn {
                w.cancelExternally()
                warn = nil
                detector.warnActive = false
                detector.lockPending = false
                scanner.emitAllSamples = false
            }
        case .inactive(let status):
            logger.log("inactive: \(prefix) \(status)")
            if let w = warn {
                w.cancelExternally()
                warn = nil
                detector.warnActive = false
                detector.lockPending = false
                scanner.emitAllSamples = false
            }
        case .scheduleLock(let reason, let status):
            scheduleLock(reason: reason, status: "\(prefix) \(status)")
        }
    }

    // MARK: Lock flow

    private func scheduleLock(reason: String, status: String) {
        guard warn == nil, !detector.lockPending else { return }
        detector.lockPending = true
        detector.warnActive = true
        lastLockReason = reason
        detector.startCooldown(seconds: cfg.lockAttemptCooldownSeconds)
        logger.log("scheduleLock: \(reason) | \(status)")

        if cfg.warnBeforeLockSeconds <= 0 {
            commitLock()
            return
        }

        // During the countdown we want every advertisement / readRSSI push
        // to reach the detector so "iPhone came back" is recognized within a
        // second or two instead of at the next 5 s poll tick.
        scanner.emitAllSamples = true

        let overlay = WarnOverlay(
            totalSeconds: cfg.warnBeforeLockSeconds,
            reason: reason,
            logger: logger,
            onCommit: { [weak self] in self?.commitLock() },
            onCancel: { [weak self] in self?.cancelLock() }
        )
        warn = overlay
        overlay.show()
    }

    private func commitLock() {
        logger.log("commitLock reason=\(lastLockReason)")
        warn = nil
        detector.warnActive = false
        scanner.emitAllSamples = false
        locker.lock()

        // Watchdog: if screensLocked never fires (all lock paths silently
        // no-op), clear lockPending so future away events can still trigger.
        lockWatchdog?.invalidate()
        lockWatchdog = Timer.scheduledTimer(withTimeInterval: lockWatchdogSeconds,
                                            repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if !self.detector.screenLocked && self.detector.lockPending {
                self.logger.log(String(format:
                    "lock watchdog: screensLocked never arrived within %.0fs; clearing lockPending",
                    self.lockWatchdogSeconds))
                self.detector.lockPending = false
            }
            self.lockWatchdog = nil
        }
    }

    private func cancelLock() {
        logger.log("cancelLock (user pressed Esc)")
        warn = nil
        detector.warnActive = false
        scanner.emitAllSamples = false
        detector.lockPending = false
        detector.resetAway()
        detector.startCooldown(seconds: cfg.warnCancelCooldownSeconds)
        lockWatchdog?.invalidate(); lockWatchdog = nil
    }

    // MARK: Sleep / wake / lock

    private func handleSleepWake(_ event: SleepWakeMonitor.Event) {
        switch event {
        case .willSleep:
            logger.log("system will sleep")
            if let w = warn { w.cancelExternally(); warn = nil }
            detector.warnActive = false
            detector.lockPending = false
        case .didWake:
            logger.log("system did wake")
            detector.resetAway()
            detector.startCooldown(seconds: cfg.unlockCooldownSeconds)
        case .screensLocked:
            logger.log("screen locked")
            detector.screenLocked = true
            detector.lockPending = false
            lockWatchdog?.invalidate(); lockWatchdog = nil
        case .screensUnlocked:
            logger.log("screen unlocked")
            detector.screenLocked = false
            detector.lockPending = false
            detector.resetAway()
            detector.startCooldown(seconds: cfg.unlockCooldownSeconds)
            lockWatchdog?.invalidate(); lockWatchdog = nil
        }
    }
}
