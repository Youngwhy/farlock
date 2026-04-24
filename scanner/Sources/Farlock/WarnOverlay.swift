import AppKit

// Full-screen semi-transparent overlay that shows a countdown and listens for
// Esc to cancel the pending lock. One window per connected display so
// multi-monitor setups can't hide the warning on the screen the user isn't
// looking at.

final class WarnOverlay {
    private let totalSeconds: Double
    private let reason: String
    private let onCommit: () -> Void
    private let onCancel: () -> Void
    private let logger: FileLogger

    private var windows: [NSWindow] = []
    private var labels: [NSTextField] = []
    private var countdownTimer: Timer?
    private var monitor: Any?
    private var startedAt: Date = .distantPast

    init(totalSeconds: Double,
         reason: String,
         logger: FileLogger,
         onCommit: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.totalSeconds = totalSeconds
        self.reason = reason
        self.logger = logger
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    private func titleText() -> String {
        switch reason {
        case "signal_lost": return "iPhone signal lost"
        default:            return "iPhone out of range"
        }
    }

    func show() {
        startedAt = Date()
        let screens = NSScreen.screens
        let displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        logger.log(
            "WarnOverlay.show: screens=\(screens.count) "
            + "main=\(NSScreen.main.map { "\($0.frame)" } ?? "nil") "
            + "displayAsleep=\(displayAsleep)"
        )

        // One window per screen. CGShieldingWindowLevel() sits above .screenSaver
        // and above any third-party utility windows that normally steal the top
        // spot; it's the level macOS uses for the login/lock curtain itself.
        for (i, screen) in screens.enumerated() {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.isOpaque = false
            window.backgroundColor = NSColor.black.withAlphaComponent(0.55)
            window.ignoresMouseEvents = false
            window.collectionBehavior = [
                .canJoinAllSpaces,
                .stationary,
                .fullScreenAuxiliary,
                .ignoresCycle,
            ]
            window.hasShadow = false

            let content = NSView(frame: screen.frame)
            window.contentView = content

            let title = NSTextField(labelWithString: titleText())
            title.font = NSFont.systemFont(ofSize: 40, weight: .semibold)
            title.textColor = .white
            title.alignment = .center
            title.frame = NSRect(
                x: 0, y: screen.frame.height * 0.55,
                width: screen.frame.width, height: 60
            )
            content.addSubview(title)

            let countdown = NSTextField(labelWithString: formatCountdown(totalSeconds))
            countdown.font = NSFont.systemFont(ofSize: 22)
            countdown.textColor = NSColor.white.withAlphaComponent(0.92)
            countdown.alignment = .center
            countdown.frame = NSRect(
                x: 0, y: screen.frame.height * 0.48,
                width: screen.frame.width, height: 40
            )
            content.addSubview(countdown)

            // Order-front first for key status (so Esc monitor catches events),
            // then orderFrontRegardless to win against .accessory activation
            // quirks — .accessory apps can't always grab focus, and without a
            // regardless-order the window can silently stay behind active apps.
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()

            windows.append(window)
            labels.append(countdown)

            logger.log(
                "WarnOverlay.show: window[\(i)] frame=\(screen.frame) "
                + "isVisible=\(window.isVisible) "
                + "level=\(window.level.rawValue) "
                + "isOnActiveSpace=\(window.isOnActiveSpace)"
            )
        }

        NSApp.activate(ignoringOtherApps: true)

        // Local monitor for Esc while this app has focus.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 { // Esc
                self?.dismiss(commit: false)
                return nil
            }
            return ev
        }

        // Start the countdown timer regardless of screen availability so we
        // don't get stuck in a "scheduled but never fires" state if the window
        // creation above no-ops for some reason.
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(countdownTimer!, forMode: .common)

        if screens.isEmpty {
            logger.log("WarnOverlay.show: no screens available — countdown running blind")
        }
    }

    private func tick() {
        let remaining = max(0, totalSeconds - Date().timeIntervalSince(startedAt))
        let text = formatCountdown(remaining)
        for label in labels { label.stringValue = text }
        if remaining <= 0 {
            dismiss(commit: true)
        }
    }

    private func formatCountdown(_ secs: Double) -> String {
        return String(format: "Locking in %ds — press Esc to cancel", Int(ceil(secs)))
    }

    private func dismiss(commit: Bool) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        labels.removeAll()
        if commit { onCommit() } else { onCancel() }
    }

    // External cancel (e.g., target came back in range).
    func cancelExternally() {
        dismiss(commit: false)
    }

    var isVisible: Bool {
        return !windows.isEmpty
    }
}
