#!/bin/zsh
set -euo pipefail

APP_PATH="${1:-${HOME}/Applications/TargetBridge 5K Sender.app}"
EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/TargetBridge"
LABEL="com.targetbridge.sender5k"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${PLIST_DIR}/${LABEL}.plist"
STATE_DIR="${HOME}/Library/Application Support/TargetBridge/Sender"
ENABLED_PATH="${STATE_DIR}/enabled"

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Sender executable not found: $EXECUTABLE_PATH" >&2
  exit 1
fi

mkdir -p "$PLIST_DIR" "$STATE_DIR"
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
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string ${APP_PATH}" "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:3 string --args' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:4 string --connect' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:5 string --receiver' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:6 string auto' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:7 string --transport' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:8 string thunderbolt' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:9 string --path' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:10 string thunderbolt' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:11 string --mode' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:12 string extended' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:13 string --preset' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:14 string native5k60' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:15 string --audio' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:16 string 0' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:17 string --retry' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:18 string 1' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:19 string --large-cursor' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:20 string 0' "$PLIST_TEMPLATE"
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

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl enable "gui/$(id -u)/${LABEL}"
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

echo "iMac 5K Display Sender monitor mode enabled: $APP_PATH"
echo "If macOS requests Screen Recording once, grant it, quit the app, and run this installer once more."
