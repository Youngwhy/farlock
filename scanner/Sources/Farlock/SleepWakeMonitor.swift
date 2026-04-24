import Foundation
import AppKit

// Wraps NSWorkspace notifications for sleep, wake, screen-locked, and
// screen-unlocked events. Mirrors the subset of hs.caffeinate.watcher events
// the Lua script actually used.

final class SleepWakeMonitor {
    enum Event {
        case willSleep
        case didWake
        case screensLocked
        case screensUnlocked
    }

    private let handler: (Event) -> Void
    private var observers: [NSObjectProtocol] = []

    init(handler: @escaping (Event) -> Void) {
        self.handler = handler
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        observers.append(nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in self?.handler(.willSleep) })

        observers.append(nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.handler(.didWake) })

        observers.append(dnc.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] _ in self?.handler(.screensLocked) })

        observers.append(dnc.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] _ in self?.handler(.screensUnlocked) })
    }

    deinit {
        let nc  = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        for o in observers {
            nc.removeObserver(o)
            dnc.removeObserver(o)
        }
    }
}
