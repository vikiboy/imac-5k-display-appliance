#!/bin/zsh
set -euo pipefail

LABEL="com.targetbridge.sender5k"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
ENABLED_PATH="${HOME}/Library/Application Support/TargetBridge/Sender/enabled"

launchctl disable "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
[[ ! -e "$ENABLED_PATH" ]] || unlink "$ENABLED_PATH"
[[ ! -e "$PLIST_PATH" ]] || unlink "$PLIST_PATH"

echo "iMac 5K Display Sender monitor mode disabled. The app and display arrangement were left installed."
