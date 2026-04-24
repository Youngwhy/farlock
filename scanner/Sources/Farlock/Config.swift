import Foundation

// Minimal runtime config. All fields have sensible defaults so a config.json
// carrying just the target identifier is enough to get going.
struct Config: Codable {
    // Target identification — any match wins.
    var targetName: String?
    var targetMacAddr: String?
    var targetUuid: String?

    // Active-mode BLE polling.
    var activeMode: Bool
    var activeReadInterval: Double
    var activeStallTimeout: Double

    // Evaluation cadence.
    var pollIntervalSeconds: Double

    // EWMA smoothing alpha (higher = snappier, more susceptible to spikes).
    var ewmaAlpha: Double

    // RSSI thresholds (dBm, negative; less-negative = closer).
    //
    // These are raw signal-strength cutoffs, not distances. RSSI varies a lot
    // with Mac/iPhone model, antenna orientation, body blocking, and case
    // material (easily ±10 dB across setups), so we let the user observe
    // their own numbers in `farlock logs` and pick values directly rather
    // than guessing at a path-loss model that hides that variance.
    //
    //   awayRssi  — EWMA must drop to or below this to start the dwell timer.
    //   rearmRssi — EWMA must climb back to or above this to re-arm / cancel.
    //
    // rearmRssi must be strictly greater than awayRssi (i.e. rearm is closer).
    // The gap between them is the hysteresis band; at least 5 dB is required
    // to survive ordinary BLE RSSI noise, 8–12 dB gives more margin.
    var awayRssi: Double
    var rearmRssi: Double

    // Timeouts.
    var awayDwellSeconds: Double
    var signalLostTimeoutSeconds: Double
    var warnBeforeLockSeconds: Double
    var warnCancelCooldownSeconds: Double
    var lockAttemptCooldownSeconds: Double
    var unlockCooldownSeconds: Double

    // Policy.
    var trustedWifiSSIDs: [String]

    // Paths.
    var logFile: String

    static let `default` = Config(
        targetName: nil,
        targetMacAddr: nil,
        targetUuid: nil,
        activeMode: true,
        activeReadInterval: 2.0,
        activeStallTimeout: 10.0,
        pollIntervalSeconds: 5.0,
        ewmaAlpha: 0.35,
        awayRssi: -60,
        rearmRssi: -55,
        awayDwellSeconds: 10,
        signalLostTimeoutSeconds: 20,
        warnBeforeLockSeconds: 5,
        warnCancelCooldownSeconds: 60,
        lockAttemptCooldownSeconds: 20,
        unlockCooldownSeconds: 90,
        trustedWifiSSIDs: [],
        logFile: "~/Library/Logs/farlock.log"
    )

    static func load(from path: String) throws -> Config {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        // Merge with defaults so partial configs work.
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var merged = try defaultsAsDictionary()
        for (k, v) in json { merged[k] = v }
        let mergedData = try JSONSerialization.data(withJSONObject: merged)
        return try decoder.decode(Config.self, from: mergedData)
    }

    private static func defaultsAsDictionary() throws -> [String: Any] {
        let data = try JSONEncoder().encode(Config.default)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
