import Foundation
import AppKit

// Locks the screen. Tries three methods in order of cleanliness:
//
//   1. SACLockScreenImmediate() — private API inside login.framework. Same
//      one BLEUnlock uses. No Accessibility permission needed.
//
//   2. Carbon keystroke ctrl+cmd+q (the documented user shortcut for lock).
//      Requires Accessibility, but if we have it this works everywhere.
//
//   3. /System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession -suspend
//      Old trick. Works on most macOS versions without special entitlements
//      but is the least reliable on brand-new releases.
//
// After issuing the lock, we optionally fall back to ScreenSaverEngine so we
// always end up with *something* on screen even if the primary path silently
// no-ops.

final class Locker {
    private let logger: FileLogger
    private let sacLockScreenImmediate: (@convention(c) () -> Int32)?

    init(logger: FileLogger) {
        self.logger = logger
        self.sacLockScreenImmediate = {
            let paths = [
                "/System/Library/PrivateFrameworks/login.framework/Versions/A/login",
                "/System/Library/PrivateFrameworks/login.framework/login",
            ]
            for path in paths {
                guard let handle = dlopen(path, RTLD_NOW) else { continue }
                if let sym = dlsym(handle, "SACLockScreenImmediate") {
                    return unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)
                }
            }
            return nil
        }()
    }

    func lock() {
        if let fn = sacLockScreenImmediate {
            let rc = fn()
            if rc == 0 {
                logger.log("lock: SACLockScreenImmediate() ok")
                return
            } else {
                logger.log("lock: SACLockScreenImmediate() returned \(rc); trying fallback")
            }
        } else {
            logger.log("lock: SACLockScreenImmediate unavailable; trying fallback")
        }

        if lockViaKeystroke() {
            logger.log("lock: keystroke ctrl+cmd+q posted")
            return
        }

        if lockViaCGSession() {
            logger.log("lock: CGSession -suspend ok")
            return
        }

        // Final fallback: launch the screensaver. Assumes the user has
        // "Require password immediately after screensaver" set.
        if let url = URL(string: "file:///System/Library/CoreServices/ScreenSaverEngine.app") {
            NSWorkspace.shared.open(url)
            logger.log("lock: launched ScreenSaverEngine as last-resort fallback")
        }
    }

    // Carbon-style keycode for Q is 0x0C.
    private func lockViaKeystroke() -> Bool {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return false }
        let flags: CGEventFlags = [.maskControl, .maskCommand]
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0x0C, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x0C, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func lockViaCGSession() -> Bool {
        let path = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let task = Process()
        task.launchPath = path
        task.arguments = ["-suspend"]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}
