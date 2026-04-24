import Foundation

// Consumes a stream of raw RSSI samples and emits decisions the
// AppController turns into real actions. Keeps the design minimal:
//   • EWMA smoothing
//   • Direct RSSI thresholds (no distance math)
//   • away-dwell + signal-lost timers
//   • Wi-Fi bypass
//
// Thresholds are raw signal-strength cutoffs chosen by the user after
// observing their own logs. There is no meter/distance conversion: BLE RSSI
// varies too much with hardware and body blocking for a single path-loss
// model to be trustworthy, and exposing the knob directly avoids hiding that
// variance behind a false meter reading.

enum DetectorDecision {
    case stay(status: String)
    case scheduleLock(reason: String, status: String)
    case backInRange(status: String)
    case inactive(status: String)  // Trusted Wi-Fi, etc.
}

final class Detector {
    private let cfg: Config
    private let logger: FileLogger
    private var trustedWifiCheck: () -> String?

    private(set) var ewma: Double?

    private var awayBelowSince: Date?
    private var lastValidSampleAt: Date?
    private var sawAnyRssi = false

    private(set) var isAway: Bool = false
    var cooldownUntil: Date = .distantPast
    var screenLocked: Bool = false
    var lockPending: Bool = false
    var warnActive: Bool = false

    private var lastTrustedSSID: String?

    init(cfg: Config, logger: FileLogger, trustedWifiCheck: @escaping () -> String?) {
        self.cfg = cfg
        self.logger = logger
        self.trustedWifiCheck = trustedWifiCheck
    }

    // Called on each poll tick. rssi == nil means the target is not visible.
    func evaluate(rssi: Int?, now: Date = Date()) -> DetectorDecision {
        // Trusted Wi-Fi bypass.
        if let ssid = trustedWifiCheck() {
            if lastTrustedSSID != ssid {
                logger.log("Trusted Wi-Fi bypass active: \(ssid)")
            }
            lastTrustedSSID = ssid
            lockPending = false
            isAway = false
            awayBelowSince = nil
            return .inactive(status: "trusted wifi [\(ssid)]")
        }
        if let ssid = lastTrustedSSID {
            logger.log("Trusted Wi-Fi bypass ended: \(ssid)")
            lastTrustedSSID = nil
        }

        // Signal-lost path: total absence for too long.
        if rssi == nil {
            if sawAnyRssi,
               cfg.signalLostTimeoutSeconds > 0,
               let last = lastValidSampleAt,
               now.timeIntervalSince(last) >= cfg.signalLostTimeoutSeconds {
                let silent = now.timeIntervalSince(last)
                let status = String(format: "signal_lost silent=%.1fs", silent)
                if !isBusy(now: now) {
                    logger.log(String(format:
                        "Signal lost: no valid RSSI sample for %.1fs (threshold %.0fs)",
                        silent, cfg.signalLostTimeoutSeconds))
                    return .scheduleLock(reason: "signal_lost", status: status)
                }
                return .stay(status: status)
            }
            let silent = lastValidSampleAt.map { now.timeIntervalSince($0) } ?? 0
            return .stay(status: String(format: "no-sample silent=%.1fs", silent))
        }

        // Have a real sample.
        sawAnyRssi = true
        lastValidSampleAt = now

        let r = Double(rssi!)
        if ewma == nil {
            ewma = r
        } else {
            ewma = cfg.ewmaAlpha * r + (1.0 - cfg.ewmaAlpha) * ewma!
        }
        let (awayT, rearmT) = effectiveThresholds()
        let smoothed = ewma!
        let status = String(format: "ewma=%.1f away<=%.0f rearm>=%.0f", smoothed, awayT, rearmT)

        // Back-in-range.
        if isAway && smoothed >= rearmT {
            isAway = false
            awayBelowSince = nil
            return .backInRange(status: status)
        }

        // Dwell tracking. Only cancel the dwell when we cross back above
        // rearmT — samples inside the hysteresis band (awayT < x < rearmT)
        // leave the running timer alone so a brief noise spike doesn't keep
        // resetting the count.
        if smoothed <= awayT {
            if awayBelowSince == nil { awayBelowSince = now }
        } else if smoothed >= rearmT {
            awayBelowSince = nil
        }

        if !isAway {
            guard let since = awayBelowSince,
                  now.timeIntervalSince(since) >= cfg.awayDwellSeconds else {
                return .stay(status: status)
            }
            isAway = true
            logger.log("Away threshold crossed: \(status)")
        }

        if isBusy(now: now) {
            return .stay(status: status)
        }
        if smoothed <= awayT {
            return .scheduleLock(reason: "away", status: status)
        }
        return .stay(status: status)
    }

    func startCooldown(seconds: Double, now: Date = Date()) {
        cooldownUntil = now.addingTimeInterval(seconds)
    }

    func resetAway() {
        isAway = false
        awayBelowSince = nil
    }

    private func isBusy(now: Date) -> Bool {
        if now < cooldownUntil { return true }
        if screenLocked || lockPending || warnActive { return true }
        return false
    }

    // Thresholds are just the configured RSSI values. If the hysteresis gap
    // is inverted or collapsed, widen rearm by 5 dB at runtime so we still
    // have a usable band. Config file is NOT modified — main.swift warns the
    // user so they can fix it persistently with `farlock rearm-rssi`.
    private func effectiveThresholds() -> (Double, Double) {
        let away = cfg.awayRssi
        var rearm = cfg.rearmRssi
        if rearm <= away {
            rearm = away + 5
        }
        return (away, rearm)
    }
}
