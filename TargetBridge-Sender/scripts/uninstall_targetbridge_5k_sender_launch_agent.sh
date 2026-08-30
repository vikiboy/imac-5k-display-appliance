#!/bin/zsh
set -euo pipefail

LABEL="com.targetbridge.sender5k"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
ENABLED_PATH="${HOME}/Library/Application Support/TargetBridge/Sender/enabled"
STATE_DIR="${HOME}/Library/Application Support/TargetBridge/Sender"
PREFERENCE_DOMAIN="com.targetbridge.sender"
PREVENT_DISPLAY_SLEEP_KEY="fd.tbdisplaysender.preventDisplaySleep"
ORIGINAL_PREVENT_SLEEP_PATH="${STATE_DIR}/prevent-display-sleep.original"
DEFAULTS_BIN="${TB_DEFAULTS_BIN:-/usr/bin/defaults}"
LAUNCHCTL_BIN="${TB_LAUNCHCTL_BIN:-/bin/launchctl}"

restore_prevent_display_sleep() {
  [[ -e "$ORIGINAL_PREVENT_SLEEP_PATH" ]] || return 0
  local original current
  original="$(<"$ORIGINAL_PREVENT_SLEEP_PATH")"
  case "$original" in
    absent|0|1) ;;
    *)
      echo "Invalid saved prevent-display-sleep preference; preserved backup" >&2
      return 65
      ;;
  esac
  current="$($DEFAULTS_BIN read "$PREFERENCE_DOMAIN" "$PREVENT_DISPLAY_SLEEP_KEY" 2>/dev/null || true)"
  case "$current" in
    0)
      if [[ "$original" == absent ]]; then
        "$DEFAULTS_BIN" delete "$PREFERENCE_DOMAIN" "$PREVENT_DISPLAY_SLEEP_KEY" >/dev/null 2>&1 || true
      else
        "$DEFAULTS_BIN" write "$PREFERENCE_DOMAIN" "$PREVENT_DISPLAY_SLEEP_KEY" -bool "$original"
      fi
      ;;
    1|'')
      # Preserve a later explicit user change or already-removed preference.
      ;;
    *)
      echo "Unexpected current prevent-display-sleep preference; preserved backup" >&2
      return 65
      ;;
  esac
  /bin/unlink "$ORIGINAL_PREVENT_SLEEP_PATH"
}

if [[ ! -x "$DEFAULTS_BIN" ]]; then
  echo "Required macOS preference tool is unavailable" >&2
  exit 1
fi
if [[ ! -x "$LAUNCHCTL_BIN" ]]; then
  echo "Required launchd control tool is unavailable" >&2
  exit 1
fi

"$LAUNCHCTL_BIN" disable "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || true
"$LAUNCHCTL_BIN" bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
[[ ! -e "$ENABLED_PATH" ]] || unlink "$ENABLED_PATH"
[[ ! -e "$PLIST_PATH" ]] || unlink "$PLIST_PATH"
restore_prevent_display_sleep

echo "iMac 5K Display Sender monitor mode disabled. The app and display arrangement were left installed; the prior display-sleep preference was restored when unchanged."
