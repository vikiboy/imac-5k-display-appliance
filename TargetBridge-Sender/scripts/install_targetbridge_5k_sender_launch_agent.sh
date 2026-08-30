#!/bin/zsh
set -euo pipefail

APP_PATH="${1:-${HOME}/Applications/TargetBridge 5K Sender.app}"
EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/TargetBridge"
LABEL="com.targetbridge.sender5k"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${PLIST_DIR}/${LABEL}.plist"
STATE_DIR="${HOME}/Library/Application Support/TargetBridge/Sender"
ENABLED_PATH="${STATE_DIR}/enabled"
PREFERENCE_DOMAIN="com.targetbridge.sender"
PREVENT_DISPLAY_SLEEP_KEY="fd.tbdisplaysender.preventDisplaySleep"
ORIGINAL_PREVENT_SLEEP_PATH="${STATE_DIR}/prevent-display-sleep.original"
DEFAULTS_BIN="${TB_DEFAULTS_BIN:-/usr/bin/defaults}"
LAUNCHCTL_BIN="${TB_LAUNCHCTL_BIN:-/bin/launchctl}"

matching_sender_pids() {
  /bin/ps -ww -axo pid=,command= 2>/dev/null | /usr/bin/awk \
    -v expected="$EXECUTABLE_PATH" '
      match($0, /^[[:space:]]*[0-9]+[[:space:]]+/) {
        prefix = substr($0, 1, RLENGTH)
        pid = prefix
        gsub(/[[:space:]]/, "", pid)
        command = substr($0, RLENGTH + 1)
        if (command == expected || index(command, expected " ") == 1) print pid
      }
    '
}

stop_existing_sender() {
  local pid
  local -a sender_pids
  sender_pids=("${(@f)$(matching_sender_pids)}")
  for pid in "${sender_pids[@]}"; do
    [[ -n "$pid" ]] || continue
    /bin/kill -TERM "$pid" 2>/dev/null || true
  done

  # `open --env` cannot change argv or environment in an existing singleton.
  # Wait for the exact installed executable to leave before launchd starts the
  # lossless appliance process; do not kill another TargetBridge checkout.
  for _ in {1..50}; do
    [[ -z "$(matching_sender_pids)" ]] && return 0
    /bin/sleep 0.1
  done

  echo "Existing iMac 5K Display Sender did not quit; launch agent not started." >&2
  return 1
}

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Sender executable not found: $EXECUTABLE_PATH" >&2
  exit 1
fi
if [[ ! -x "$DEFAULTS_BIN" ]]; then
  echo "Required macOS preference tool is unavailable" >&2
  exit 1
fi
if [[ ! -x "$LAUNCHCTL_BIN" ]]; then
  echo "Required launchd control tool is unavailable" >&2
  exit 1
fi

mkdir -p "$PLIST_DIR" "$STATE_DIR"

# A physical monitor follows the source Mac's display-sleep policy. The general
# upstream sender defaults to preventing display sleep while streaming, which
# is useful for presentations but wrong for this dedicated appliance. Preserve
# the user's original preference once, then make the appliance default false.
if [[ ! -e "$ORIGINAL_PREVENT_SLEEP_PATH" ]]; then
  original_prevent_sleep="$($DEFAULTS_BIN read "$PREFERENCE_DOMAIN" "$PREVENT_DISPLAY_SLEEP_KEY" 2>/dev/null || true)"
  case "$original_prevent_sleep" in
    0|1) ;;
    '') original_prevent_sleep=absent ;;
    *)
      echo "Unexpected prevent-display-sleep preference; no change was made" >&2
      exit 65
      ;;
  esac
  original_prevent_sleep_work="$(mktemp "${STATE_DIR}/prevent-display-sleep.original.XXXXXX")"
  print -r -- "$original_prevent_sleep" > "$original_prevent_sleep_work"
  /bin/chmod 0600 "$original_prevent_sleep_work"
  /bin/mv "$original_prevent_sleep_work" "$ORIGINAL_PREVENT_SLEEP_PATH"
else
  original_prevent_sleep="$(<"$ORIGINAL_PREVENT_SLEEP_PATH")"
  case "$original_prevent_sleep" in
    absent|0|1) ;;
    *)
      echo "Invalid saved prevent-display-sleep preference; no change was made" >&2
      exit 65
      ;;
  esac
fi
"$DEFAULTS_BIN" write "$PREFERENCE_DOMAIN" "$PREVENT_DISPLAY_SLEEP_KEY" -bool false
touch "$ENABLED_PATH"

PLIST_WORK_DIR="$(mktemp -d)"
PLIST_TEMPLATE="${PLIST_WORK_DIR}/agent.plist"
cleanup() {
  [[ ! -e "$PLIST_TEMPLATE" ]] || unlink "$PLIST_TEMPLATE"
  rmdir "$PLIST_WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

/usr/libexec/PlistBuddy -c "Add :Label string ${LABEL}" "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:0 string /usr/bin/open' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:1 string -W' "$PLIST_TEMPLATE"
# Pass the lossless transport through both launchd and `open`. LaunchServices
# does not retroactively apply launchd's environment to an already-running app,
# and a missing DPCM flag makes this strict receiver correctly reject HEVC.
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:2 string --env' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:3 string DPCM=1' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string ${APP_PATH}" "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:5 string --args' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:6 string --connect' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:7 string --receiver' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:8 string auto' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:9 string --transport' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:10 string thunderbolt' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:11 string --path' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:12 string thunderbolt' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:13 string --mode' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:14 string extended' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:15 string --preset' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:16 string native5k60' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:17 string --audio' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:18 string 0' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:19 string --retry' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:20 string 1' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:21 string --large-cursor' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:22 string 0' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables dict' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables:DPCM string 1' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :KeepAlive dict' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :KeepAlive:PathState dict' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c "Add ':KeepAlive:PathState:${ENABLED_PATH}' bool true" "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ThrottleInterval integer 15' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProcessType string Interactive' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :LimitLoadToSessionType array' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :LimitLoadToSessionType:0 string Aqua' "$PLIST_TEMPLATE"

plutil -lint "$PLIST_TEMPLATE"
install -m 0644 "$PLIST_TEMPLATE" "$PLIST_PATH"

"$LAUNCHCTL_BIN" bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
stop_existing_sender
"$LAUNCHCTL_BIN" enable "gui/$(id -u)/${LABEL}"
"$LAUNCHCTL_BIN" bootstrap "gui/$(id -u)" "$PLIST_PATH"

echo "iMac 5K Display Sender monitor mode enabled: $APP_PATH"
echo "TargetBridge no longer prevents source-display sleep (original preference preserved)"
echo "If macOS requests Screen Recording once, grant it, quit the app, and run this installer once more."
