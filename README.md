# Farlock

> Lock your Mac when your iPhone walks away.

Farlock is a small background agent that watches for your paired iPhone over Bluetooth LE. When the phone's BLE signal drops below a threshold you set, Farlock pops a full-screen countdown overlay and then locks the Mac. When the signal climbs back — or when you press `Esc` — nothing happens. No cloud, no account, no password-typing tricks. One Swift binary, a LaunchAgent, and a small CLI.

## Features

- **RSSI-native thresholds.** You set the trigger and rearm points as raw dBm values you read off your own logs, not as meters run through a path-loss model that lies about your room. (BLE RSSI varies ±10 dB across Mac/iPhone/case combinations — meter math hides that.)
- **Warn before lock.** A full-screen countdown gives you a grace window to press `Esc` — no accidental locks while grabbing coffee.
- **Auto-dismiss on return.** If the signal climbs back above the rearm threshold during the countdown, the overlay vanishes on its own.
- **Active-mode RSSI polling.** Once the target is discovered, Farlock connects to the peripheral and calls `readRSSI()` every 2 s, so reactions stay fast even when iPhone's advertising interval lengthens.
- **Signal-lost vs. weak-signal.** Locks triggered by "phone dropped off BLE entirely" are distinguished from "phone drifted out of range" and logged separately.
- **Trusted Wi-Fi bypass.** Disable auto-lock while connected to networks you name (home, office).
- **Zero runtime deps.** Just the compiled binary — no Hammerspoon, no Python hot path, no menu-bar UI.

## Quick start

Requires macOS 12+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Youngwhy/farlock.git
cd farlock
./install.sh
```

The installer:

1. Builds the Swift agent.
2. Seeds `~/Library/Application Support/farlock/config.json` with sensible default thresholds (`awayRssi: -60`, `rearmRssi: -55`).
3. Lists your paired Bluetooth devices and asks which one is your iPhone.
4. Captures the CoreBluetooth UUID so matching survives MAC rotation.
5. Registers a LaunchAgent (auto-restarted across sleep, wake, reboot, and crashes).
6. Drops the `farlock` CLI into a directory on your `PATH`.

macOS will prompt for Bluetooth access the first time the agent runs — approve it once and you're done.

**Tuning.** The defaults are a starting point, not a guess at your room. Run `farlock logs` and walk around: the `ewma=` value you see at "still at my desk" should be above `rearmRssi`, and the value at "actually left the room" should be at or below `awayRssi`. Adjust with `farlock away-rssi` / `farlock rearm-rssi` until it matches your habits.

## The CLI

After installation, the `farlock` command manages everything at runtime.

```bash
farlock status                 # agent state + full config with descriptions
farlock target                 # re-pick the target from paired devices
farlock away-rssi              # show current away (lock) threshold in dBm
farlock away-rssi -60          # set away threshold to -60 dBm
farlock rearm-rssi             # show current rearm (cancel) threshold in dBm
farlock rearm-rssi -55         # set rearm threshold to -55 dBm
farlock list-paired            # inspect paired Bluetooth devices
farlock logs                   # stream the proximity log
farlock reload                 # kickstart the LaunchAgent
farlock uninstall              # clean removal
```

Threshold values are raw RSSI in dBm (negative; less-negative = closer). `rearmRssi` must be strictly greater than `awayRssi`; the gap between them is the hysteresis band (at least 5 dB to survive ordinary BLE noise, 8–12 dB for more margin). Advanced knobs — EWMA α, dwell and timeout seconds, trusted Wi-Fi — live in `config.json`. Edit and then run `farlock reload`.

### What a healthy log looks like

```
$ farlock logs
2026-04-22 18:03:12 tick: rssi=-55 name=iPhone ewma=-56.2 away<=-75 rearm>=-65
2026-04-22 18:03:17 tick: rssi=-54 name=iPhone ewma=-55.8 away<=-75 rearm>=-65
2026-04-22 18:03:22 tick: rssi=-63 name=iPhone ewma=-58.3 away<=-75 rearm>=-65
...
2026-04-22 18:03:42 Away threshold crossed: ewma=-77.1 away<=-75 rearm>=-65
2026-04-22 18:03:42 scheduleLock: away
2026-04-22 18:03:47 commitLock reason=away
2026-04-22 18:03:47 lock: SACLockScreenImmediate() ok
```

The `ewma=` column is the one to watch while tuning — it's the smoothed RSSI the decision runs against.


## What it is not

- **Not a replacement for your login password or Touch ID.** Farlock shortens the window during which a shoulder-surfer can read your screen while you're away. It is not an authentication mechanism.
- **Not cryptographically paired.** Matching is by advertised name / OS-reported UUID / resolved MAC. A determined attacker who can spoof BLE advertisements could block an auto-lock. That risk is negligible against the "walked to the kitchen" threat model, but it is real.

## Configuration

Edit `~/Library/Application Support/farlock/config.json`, then run `farlock reload`.

| Field | Default | What it does |
| --- | --- | --- |
| `targetName` / `targetMacAddr` / `targetUuid` | — | iPhone identifiers. Any match wins. |
| `activeMode` | `true` | Connect and `readRSSI()` on a 2 s interval for steadier samples. |
| `awayRssi` | `-60` | If smoothed RSSI drops to this (dBm) or below, the away-dwell timer starts. More negative = requires phone to be further. |
| `rearmRssi` | `-55` | If smoothed RSSI climbs to this or above, away state clears / countdown cancels. Must be strictly greater than `awayRssi`; the gap is your hysteresis band (at least 5 dB; widen to 8–12 dB for more margin). |
| `awayDwellSeconds` | `10` | How long the "below away threshold" state must persist before warning. |
| `signalLostTimeoutSeconds` | `45` | Lock with reason `signal_lost` if no valid sample for this long. |
| `warnBeforeLockSeconds` | `5` | Countdown length before committing the lock. |
| `warnCancelCooldownSeconds` | `60` | After an `Esc` cancel, ignore away state this long. |
| `ewmaAlpha` | `0.35` | 0–1 smoothing factor. Higher = snappier and noisier. |
| `trustedWifiSSIDs` | `[]` | Auto-lock is disabled while connected to any listed network. |

### How to pick your RSSI thresholds

1. Run `farlock logs` in a terminal and leave it open.
2. Sit where you normally work. Note the `ewma=` value that stabilises (call it `A`). That is "present" for your setup.
3. Walk to where you'd want Farlock to have triggered already (kitchen, other room). Note the `ewma=` value there (call it `B`).
4. Set `awayRssi` a few dB above `B` (i.e. a slightly stronger signal than "definitely gone") and `rearmRssi` a few dB below `A` (slightly weaker than "clearly at my desk"). Leave at least 8 dB between them.

Example: present ewma around −60, away ewma around −80 → `awayRssi: -75`, `rearmRssi: -65`.

Expect to retune if you change Mac models, iPhone models, desk layout, or cases — any of those can shift the entire RSSI range by 5–15 dB.

## Troubleshooting

| Symptom | Try |
| --- | --- |
| iPhone not in the paired list | Pair it in **System Settings → Bluetooth** first, then re-run `./install.sh`. |
| Locks too often | Raise `awayDwellSeconds`, or lower `awayRssi` (more negative, so it takes a weaker signal to trigger). |
| Rarely locks | Raise `awayRssi` (less negative). Watch logs at your "gone" spot and see what RSSI it actually reports. |
| Overlay flickers on/off near a boundary | Widen the hysteresis gap: push `awayRssi` lower or `rearmRssi` higher (or both). |
| Everything looks noisy | Lower `ewmaAlpha` (try `0.2`). It will react more slowly but smooth harder. |

## Uninstall

```bash
farlock uninstall
# or, from the repo:
./uninstall.sh
```

Removes the LaunchAgent, config, and CLI. Logs are left in place — delete them by hand if you want a truly clean slate.