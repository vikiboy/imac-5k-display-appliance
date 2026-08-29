#!/bin/zsh
set -euo pipefail

APP_PATH="${1:-${HOME}/Applications/TargetBridge 5K Receiver.app}"
EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/TargetBridge5KReceiver"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${PLIST_DIR}/com.targetbridge.receiver5k.plist"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Receiver executable not found: $EXECUTABLE_PATH" >&2
  exit 1
fi

mkdir -p "$PLIST_DIR"
PLIST_WORK_DIR="$(mktemp -d)"
PLIST_TEMPLATE="${PLIST_WORK_DIR}/agent.plist"
cleanup() {
  [[ ! -e "$PLIST_TEMPLATE" ]] || unlink "$PLIST_TEMPLATE"
  rmdir "$PLIST_WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# PlistBuddy serializes and XML-escapes the caller-supplied path instead of
# interpolating it into raw XML.
/usr/libexec/PlistBuddy -c 'Add :Label string com.targetbridge.receiver5k' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string ${EXECUTABLE_PATH}" "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :KeepAlive bool true' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ThrottleInterval integer 10' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :LimitLoadToSessionType array' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :LimitLoadToSessionType:0 string Aqua' "$PLIST_TEMPLATE"

plutil -lint "$PLIST_TEMPLATE"
install -m 0644 "$PLIST_TEMPLATE" "$PLIST_PATH"
launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
# Clear a stale disabled override before bootstrap. launchd otherwise accepts
# the plist but can leave a previously disabled receiver inactive.
launchctl enable "gui/$(id -u)/com.targetbridge.receiver5k"
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

echo "TargetBridge 5K Receiver will start at login: $APP_PATH"
