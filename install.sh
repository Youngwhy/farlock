#!/bin/bash
# iPhone Proximity Auto-Lock — installer.
#
# Runs the full install flow: prereqs → build → config → target pick →
# LaunchAgent → register the `farlock` CLI on PATH.
#
# Runtime configuration (changing thresholds, re-picking the target, tailing
# logs, uninstalling) is handled by the separate `farlock` CLI that
# this installer puts on your PATH.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
AGENT_DIR="$SCRIPT_DIR/scanner"
AGENT_BIN="$AGENT_DIR/.build/release/Farlock"
CONFIG_EXAMPLE="$SCRIPT_DIR/config.example.json"
PLIST_SRC="$SCRIPT_DIR/com.farlock.plist"
CLI_SRC="$SCRIPT_DIR/farlock"

CONFIG_DIR="$HOME/Library/Application Support/farlock"
CONFIG_FILE="$CONFIG_DIR/config.json"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.farlock.plist"

STAMP=$(date +%s)

GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'
BOLD=$'\033[1m';     NC=$'\033[0m'

say()  { printf "%s[install]%s %s\n" "$GREEN"  "$NC" "$*"; }
warn() { printf "%s[warn]%s    %s\n" "$YELLOW" "$NC" "$*"; }
fail() { printf "%s[fail]%s    %s\n" "$RED"    "$NC" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [--list-paired]

Default: runs the full install flow.

  --list-paired     Print paired Bluetooth devices and exit (useful for
                    previewing what the picker will show).
  -h, --help        This help.

After install, all runtime actions use the 'farlock' CLI:
  farlock status
  farlock target
  farlock away-rssi [DBM]
  farlock rearm-rssi [DBM]
  farlock logs
  farlock list-paired
  farlock reload
  farlock uninstall
EOF
}

LIST_PAIRED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list-paired) LIST_PAIRED=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# -------- 0. --list-paired short-circuit ------------------------------------

if [ -n "$LIST_PAIRED" ]; then
  system_profiler SPBluetoothDataType -json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
rows = []
for c in d.get("SPBluetoothDataType", []):
    for k in ("device_connected", "device_not_connected"):
        for it in c.get(k, []):
            if isinstance(it, dict):
                for name, props in it.items():
                    if isinstance(props, dict):
                        rows.append((name,
                                     props.get("device_address",""),
                                     props.get("device_minorType",""),
                                     "connected" if k=="device_connected" else "",
                                     props.get("device_rssi","")))
w = max((len(r[0]) for r in rows), default=24)
for name, addr, minor, conn, rssi in rows:
    tags = ", ".join(x for x in [conn, minor, (f"rssi={rssi}dBm" if rssi else "")] if x)
    tag = f" ({tags})" if tags else ""
    print(f"  {name.ljust(w)}  {addr}{tag}")
'
  exit 0
fi

# -------- 1. Prerequisites ---------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || fail "macOS only."
command -v swift   >/dev/null || fail "Swift toolchain not found. Run 'xcode-select --install' first."
command -v python3 >/dev/null || fail "python3 not found (needed to parse scan output)."

# -------- 2. Build agent -----------------------------------------------------

say "Clean build (removing $AGENT_DIR/.build)..."
rm -rf "$AGENT_DIR/.build"
say "Building Farlock (release)..."
( cd "$AGENT_DIR" && swift build -c release )

# -------- 3. Config ----------------------------------------------------------

mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG_FILE" ]; then
  cp "$CONFIG_FILE" "$CONFIG_FILE.backup.$STAMP"
  say "Backed up existing config to config.json.backup.$STAMP"
fi
if [ ! -f "$CONFIG_FILE" ]; then
  cp "$CONFIG_EXAMPLE" "$CONFIG_FILE"
  say "Seeded config.json from config.example.json."
fi

# -------- 4. Target picker ---------------------------------------------------

say "Reading paired Bluetooth devices..."
PAIRED_JSON=$(mktemp -t paired.XXXXXX).json
rm -f "$PAIRED_JSON"
system_profiler SPBluetoothDataType -json 2>/dev/null > "$PAIRED_JSON" || true
trap 'rm -f "$PAIRED_JSON" "${SCAN_JSON:-}"' EXIT

LIST=$(python3 - "$PAIRED_JSON" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f: d = json.load(f)
except Exception:
    sys.exit(0)
rows = []
for controller in d.get("SPBluetoothDataType", []):
    for key in ("device_connected", "device_not_connected"):
        for entry in controller.get(key, []):
            if not isinstance(entry, dict): continue
            for name, props in entry.items():
                if not isinstance(props, dict): continue
                minor = props.get("device_minorType") or ""
                if ("Mac" in name or "MacBook" in name or "iMac" in name) and not minor:
                    continue
                rows.append((
                    name,
                    props.get("device_address") or "",
                    minor,
                    key == "device_connected",
                    props.get("device_rssi") or "",
                ))
def sort_key(r):
    name, addr, minor, conn, rssi = r
    return (0 if conn else 1, 1 if minor else 0, name.lower())
for row in sorted(rows, key=sort_key):
    name, addr, minor, conn, rssi = row
    print("|".join([name, addr, minor, "1" if conn else "0", str(rssi)]))
PY
)

TARGET_NAME=""
TARGET_MAC=""

if [ -z "$LIST" ]; then
  warn "No paired Bluetooth devices found. Pair your iPhone in System Settings > Bluetooth first, then re-run this script."
else
  echo
  printf "%sPaired Bluetooth devices (select your iPhone):%s\n" "$BOLD" "$NC"
  i=0
  while IFS='|' read -r name addr minor connected rssi; do
    i=$((i+1))
    tags=""
    [ "$connected" = "1" ] && tags="connected"
    [ -n "$minor" ] && { [ -n "$tags" ] && tags="$tags, "; tags="${tags}${minor}"; }
    [ -n "$rssi" ]  && { [ -n "$tags" ] && tags="$tags, "; tags="${tags}rssi=${rssi}dBm"; }
    if [ -n "$tags" ]; then
      printf "  [%d] %-36s (%s)\n" "$i" "$name" "$tags"
    else
      printf "  [%d] %s\n" "$i" "$name"
    fi
  done <<< "$LIST"
  echo
  printf "%sEnter number%s: " "$BOLD" "$NC"
  read -r choice
  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    PICK=$(echo "$LIST" | sed -n "${choice}p")
    if [ -n "$PICK" ]; then
      TARGET_NAME=$(echo "$PICK" | cut -d'|' -f1)
      TARGET_MAC=$(echo "$PICK" | cut -d'|' -f2)
    fi
  elif [ -n "$choice" ]; then
    TARGET_NAME="$choice"
  fi
fi

# -------- 4b. UUID capture ---------------------------------------------------

TARGET_UUID=""
if [ -n "$TARGET_NAME" ]; then
  SCAN_JSON=$(mktemp -t proxscan.XXXXXX).json
  rm -f "$SCAN_JSON"
  say "Scanning BLE briefly to capture '$TARGET_NAME' UUID (10 s)..."
  "$AGENT_BIN" --scan-only --output "$SCAN_JSON" >/dev/null 2>&1 &
  SCAN_PID=$!
  sleep 10
  kill "$SCAN_PID" 2>/dev/null || true
  wait "$SCAN_PID" 2>/dev/null || true

  if [ -s "$SCAN_JSON" ]; then
    TARGET_UUID=$(python3 - "$SCAN_JSON" "$TARGET_NAME" <<'PY'
import json, sys
with open(sys.argv[1]) as f: d = json.load(f)
name = sys.argv[2]
best = None
for uuid, e in d.get("devices", {}).items():
    if e.get("name") == name:
        if best is None or e.get("rssi", -999) > best[1]:
            best = (uuid, e.get("rssi", -999))
print(best[0] if best else "")
PY
)
  fi
fi

# -------- 5. Patch target fields in config.json -----------------------------

if [ -n "$TARGET_NAME" ]; then
  python3 - "$CONFIG_FILE" "$TARGET_NAME" "$TARGET_MAC" "$TARGET_UUID" <<'PY'
import json, sys
path, name, mac, uuid = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path) as f: cfg = json.load(f)
cfg["targetName"] = name
cfg["targetMacAddr"] = mac or None
cfg["targetUuid"] = uuid or None
with open(path, "w") as f: json.dump(cfg, f, indent=2)
PY
  say "Target: name='$TARGET_NAME' mac='${TARGET_MAC:-?}' uuid='${TARGET_UUID:-?}'"
  [ -z "$TARGET_UUID" ] && warn "UUID not captured. Name + MAC matching will still work."
else
  warn "No target chosen. Use 'farlock target' later to set it."
fi

# -------- 6. LaunchAgent -----------------------------------------------------

mkdir -p "$(dirname "$LAUNCH_AGENT")"
sed -e "s|__AGENT_BIN_PATH__|$AGENT_BIN|g" \
    -e "s|__HOME__|$HOME|g" \
    "$PLIST_SRC" > "$LAUNCH_AGENT"

launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT"
say "LaunchAgent installed and started."

# -------- 7. Register farlock CLI on PATH ----------------------------

pick_cli_dir() {
  # Preference order: /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, ~/bin.
  # Whatever's writable without sudo wins.
  local candidates=(
    "/opt/homebrew/bin"
    "/usr/local/bin"
    "$HOME/.local/bin"
    "$HOME/bin"
  )
  for d in "${candidates[@]}"; do
    if [ -d "$d" ] && [ -w "$d" ]; then
      echo "$d"; return 0
    fi
    # ~/.local/bin and ~/bin can be created if missing.
    if [ "$d" = "$HOME/.local/bin" ] || [ "$d" = "$HOME/bin" ]; then
      mkdir -p "$d" 2>/dev/null && { echo "$d"; return 0; }
    fi
  done
  return 1
}

CLI_DIR=$(pick_cli_dir || true)
if [ -n "$CLI_DIR" ]; then
  CLI_DEST="$CLI_DIR/farlock"
  # Rewrite the placeholder so the CLI knows where the repo lives.
  sed "s|__INSTALL_DIR__|$SCRIPT_DIR|g" "$CLI_SRC" > "$CLI_DEST"
  chmod +x "$CLI_DEST"
  say "Installed CLI at $CLI_DEST"

  if ! echo ":$PATH:" | grep -q ":$CLI_DIR:"; then
    warn "$CLI_DIR is not on your PATH. Add this to your shell rc:"
    warn "  export PATH=\"$CLI_DIR:\$PATH\""
  fi
else
  warn "Could not find a writable PATH dir. Run the CLI directly: $SCRIPT_DIR/farlock"
fi

# -------- Final instructions -------------------------------------------------

cat <<EOF

${GREEN}${BOLD}=== Install complete ===${NC}

Verify:
  farlock status
  farlock logs

Tune thresholds (RSSI in dBm — negative; less-negative = closer):
  ${BOLD}How to:${NC} leave 'farlock logs' running and note the ewma= value at
          your usual spot and at the spot where you'd want it locked.
          Pick values in between.
  farlock away-rssi -60   # ewma drops to/below this -> start lock countdown
  farlock rearm-rssi -55  # ewma climbs to/above this -> cancel countdown
  farlock target          # re-pick the target iPhone

Uninstall:
  farlock uninstall

EOF
