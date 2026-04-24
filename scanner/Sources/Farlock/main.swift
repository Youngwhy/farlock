// Farlock — single-process iPhone proximity auto-lock for macOS.
//
// Consolidates the former Swift scanner + Hammerspoon Lua policy layer into
// one agent binary. Launched as a user-level launchd agent; shows NSWindow
// overlays from within the same process by running as an accessory-policy
// NSApplication.
//
// Usage:
//   Farlock --config ~/Library/Application\\ Support/farlock/config.json
//   Farlock --scan-only --output /tmp/scan.json    # legacy/debug mode
//   Farlock --help
//
// First run requires two OS permission approvals that cannot be scripted:
//   • Bluetooth (prompt appears the first time the process starts a scan)
//   • (Optional) Accessibility — only needed if the keystroke fallback path
//     in Locker is used. SACLockScreenImmediate does not require it.

import Foundation
import AppKit
import CoreBluetooth

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

struct CLIOptions {
    var configPath: String = "~/Library/Application Support/farlock/config.json"
    var scanOnly: Bool = false
    var scanOutput: String = "~/Library/Application Support/iphone-proximity-scanner/scan.json"
    var verbose: Bool = false
}

func parseCLI() -> CLIOptions {
    var opts = CLIOptions()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--config":
            guard !args.isEmpty else { fatalError("--config requires a path") }
            opts.configPath = args.removeFirst()
        case "--scan-only":
            opts.scanOnly = true
        case "--output":
            guard !args.isEmpty else { fatalError("--output requires a path") }
            opts.scanOutput = args.removeFirst()
        case "--verbose", "-v":
            opts.verbose = true
        case "--help", "-h":
            printHelp()
            exit(0)
        default:
            FileHandle.standardError.write(Data("Unknown flag: \(a)\n".utf8))
            printHelp()
            exit(2)
        }
    }
    return opts
}

func printHelp() {
    let help = """
    Farlock — iPhone proximity auto-lock agent.

    Default mode (run as a launchd agent):
      Farlock --config PATH   Load JSON config and start the agent.

    Debug / bootstrap helpers:
      Farlock --scan-only     Passive scan; write snapshot JSON only.
      --output PATH                    Snapshot file path (with --scan-only).
      --verbose                        Log each discovery to stderr.
      -h, --help                       This help.
    """
    print(help)
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

let cli = parseCLI()

// --scan-only mode: no AppKit, no detector, just write snapshots. Useful for
// the installer's "which BLE device is your iPhone?" step.
if cli.scanOnly {
    let logger = FileLogger(path: "~/Library/Logs/farlock.log")
    let defaultCfg = Config.default
    let scanner = Scanner(
        cfg: defaultCfg, logger: logger,
        snapshotPath: cli.scanOutput,
        onTargetSample: { _ in },
        onDiscovery: { _ in }
    )
    scanner.start()
    RunLoop.main.run()
    exit(0)
}

// Normal mode.
let cfg: Config = {
    do {
        return try Config.load(from: cli.configPath)
    } catch {
        FileHandle.standardError.write(Data(
            "Failed to load config at \(cli.configPath): \(error)\nUsing defaults.\n".utf8))
        return Config.default
    }
}()

let logger = FileLogger(path: cfg.logFile)

if cfg.rearmRssi <= cfg.awayRssi {
    logger.log(String(format:
        "config invalid: rearmRssi (%.0f dBm) must be greater than awayRssi (%.0f dBm). " +
        "Using rearm = awayRssi + 5 dBm at runtime; config file NOT modified. " +
        "Fix persistently with: farlock rearm-rssi <dBm greater than %.0f>.",
        cfg.rearmRssi, cfg.awayRssi, cfg.awayRssi))
}

// Must run as an accessory-policy NSApplication so:
//   (a) the dock icon never appears
//   (b) we can still create NSWindows for the warn overlay
//   (c) key events reach our windows
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = AppController(cfg: cfg, logger: logger)
controller.start()

logger.log("Farlock agent online")
app.run()
