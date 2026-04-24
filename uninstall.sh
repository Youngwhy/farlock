#!/bin/bash
# iPhone Proximity Auto-Lock — uninstaller (single Swift agent build).
#
# Removes the LaunchAgent and config directory. Does NOT delete log files
# (small, useful as history) — delete manually if you want.

set -euo pipefail

LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.farlock.plist"
CONFIG_DIR="$HOME/Library/Application Support/farlock"
SCAN_DIR="$HOME/Library/Application Support/iphone-proximity-scanner"

# Legacy Hammerspoon-based install artifacts. Removed if still present.
LEGACY_LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.proximity-scanner.plist"
LEGACY_HS_LUA="$HOME/.hammerspoon/iphone_proximity_lock.lua"
LEGACY_HS_INIT="$HOME/.hammerspoon/init.lua"

GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
say()  { printf "%s[uninstall]%s %s\n" "$GREEN"  "$NC" "$*"; }
warn() { printf "%s[warn]%s      %s\n" "$YELLOW" "$NC" "$*"; }

# New LaunchAgent
if [ -f "$LAUNCH_AGENT" ]; then
  launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT" 2>/dev/null || true
  rm -f "$LAUNCH_AGENT"
  say "Removed LaunchAgent."
fi

# farlock CLI installed on PATH by install.sh
for candidate in \
  "/opt/homebrew/bin/farlock" \
  "/usr/local/bin/farlock" \
  "$HOME/.local/bin/farlock" \
  "$HOME/bin/farlock"; do
  if [ -f "$candidate" ] || [ -L "$candidate" ]; then
    rm -f "$candidate"
    say "Removed CLI: $candidate"
  fi
done

# Legacy LaunchAgent
if [ -f "$LEGACY_LAUNCH_AGENT" ]; then
  launchctl bootout "gui/$(id -u)" "$LEGACY_LAUNCH_AGENT" 2>/dev/null || true
  rm -f "$LEGACY_LAUNCH_AGENT"
  say "Removed legacy (Hammerspoon-era) LaunchAgent."
fi

# Config directory
if [ -d "$CONFIG_DIR" ]; then
  rm -rf "$CONFIG_DIR"
  say "Removed $CONFIG_DIR"
fi

# Debug snapshot dir (from --scan-only runs)
rm -rf "$SCAN_DIR"

# Legacy Hammerspoon Lua script + require()
if [ -f "$LEGACY_HS_LUA" ]; then
  rm -f "$LEGACY_HS_LUA"
  say "Removed legacy $LEGACY_HS_LUA"
fi
if [ -f "$LEGACY_HS_INIT" ]; then
  TMP="$LEGACY_HS_INIT.tmp.$$"
  awk '
    /^-- iphone-farlock \(installed by install\.sh\)$/ { skip = 3; next }
    skip > 0 { skip--; next }
    /require\("iphone_proximity_lock"\)/ { next }
    /hs\.allowAppleScript\(true\)/ { next }
    { print }
  ' "$LEGACY_HS_INIT" > "$TMP"
  if [ -s "$TMP" ]; then
    mv "$TMP" "$LEGACY_HS_INIT"
    say "Cleaned require() from legacy init.lua"
  else
    rm -f "$TMP" "$LEGACY_HS_INIT"
    say "init.lua was empty after cleanup; removed."
  fi
fi

# Legacy App Nap override
defaults delete org.hammerspoon.Hammerspoon NSAppSleepDisabled 2>/dev/null || true

cat <<EOF

${GREEN}Uninstall complete.${NC}

Kept in place (remove manually if you want):
  • Log files — ~/Library/Logs/farlock.log, farlock.{out,err}.log
  • Bluetooth permission — System Settings > Privacy & Security > Bluetooth

EOF
