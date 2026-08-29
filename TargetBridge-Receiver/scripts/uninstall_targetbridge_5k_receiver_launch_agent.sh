#!/bin/zsh
set -euo pipefail

PLIST_PATH="${HOME}/Library/LaunchAgents/com.targetbridge.receiver5k.plist"
launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
if [[ -f "$PLIST_PATH" ]]; then
  rm "$PLIST_PATH"
fi

echo "TargetBridge 5K Receiver login item removed. The app itself was left installed."
