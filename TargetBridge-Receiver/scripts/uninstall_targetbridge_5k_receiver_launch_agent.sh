#!/bin/zsh
set -euo pipefail

PLIST_PATH="${HOME}/Library/LaunchAgents/com.targetbridge.receiver5k.plist"
APP_PATH="${1:-${HOME}/Applications/TargetBridge 5K Receiver.app}"
EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/TargetBridge5KReceiver"
DEFAULTS_BIN="${TB_DEFAULTS_BIN:-/usr/bin/defaults}"
LAUNCHCTL_BIN="${TB_LAUNCHCTL_BIN:-/bin/launchctl}"
SYSADMINCTL_BIN="${TB_SYSADMINCTL_BIN:-/usr/sbin/sysadminctl}"
APPLIANCE_PREFS_DOMAIN="com.vikiboy.imac5k-display-appliance"
SCREEN_SAVER_DOMAIN="com.apple.screensaver"
SCREEN_SAVER_IDLE_KEY="idleTime"
ORIGINAL_IDLE_KEY="OriginalScreenSaverIdleTime"
MANAGES_IDLE_KEY="ManagesScreenSaverIdleTime"
ORIGINAL_LOCK_KEY="OriginalScreenLockDelay"
MANAGES_LOCK_KEY="ManagesScreenLockDelay"
BACKED_UP_IDLE_PATTERN='^(-1|[0-9]+)$'
BACKED_UP_LOCK_PATTERN='^(off|immediate|[0-9]+)$'
SCREEN_LOCK_SECONDS_PATTERN='screenLock delay is ([0-9]+) seconds'
SCREEN_LOCK_IMMEDIATE_PATTERN='screenLock delay is immediate'
SCREEN_LOCK_OFF_PATTERN='screenLock is off'

read_screen_lock_delay() {
  local output
  if ! output="$($SYSADMINCTL_BIN -screenLock status 2>&1)"; then
    echo "Unable to read the current screen-lock delay" >&2
    return 1
  fi

  if [[ "$output" =~ $SCREEN_LOCK_SECONDS_PATTERN ]]; then
    print -r -- "${match[1]}"
  elif [[ "$output" =~ $SCREEN_LOCK_IMMEDIATE_PATTERN ]]; then
    print -r -- immediate
  elif [[ "$output" =~ $SCREEN_LOCK_OFF_PATTERN ]]; then
    print -r -- off
  else
    echo "Unrecognized screen-lock status; preserved management backup" >&2
    return 65
  fi
}

set_screen_lock_delay() {
  local target="$1"
  local command_status
  local xtrace_was_enabled=0
  [[ -o xtrace ]] && xtrace_was_enabled=1

  set +x
  if "$SYSADMINCTL_BIN" -screenLock "$target" -password "$TB_APPLIANCE_ACCOUNT_PASSWORD" \
       >/dev/null 2>&1; then
    command_status=0
  else
    command_status=$?
  fi
  (( xtrace_was_enabled == 0 )) || set -x
  return "$command_status"
}

matching_receiver_pids() {
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

stop_existing_receiver() {
  local pid
  local -a receiver_pids
  receiver_pids=("${(@f)$(matching_receiver_pids)}")
  for pid in "${receiver_pids[@]}"; do
    [[ -n "$pid" ]] || continue
    /bin/kill -TERM "$pid" 2>/dev/null || true
  done
  for _ in {1..50}; do
    [[ -z "$(matching_receiver_pids)" ]] && return 0
    /bin/sleep 0.1
  done
  echo "iMac 5K Display Appliance did not quit; uninstall is incomplete." >&2
  return 1
}

if [[ ! -x "$DEFAULTS_BIN" || ! -x "$LAUNCHCTL_BIN" ]]; then
  echo "Required macOS preference or service tool is unavailable" >&2
  exit 1
fi

"$LAUNCHCTL_BIN" bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
stop_existing_receiver
if [[ -f "$PLIST_PATH" ]]; then
  rm "$PLIST_PATH"
fi

managed_idle_time="$($DEFAULTS_BIN read "$APPLIANCE_PREFS_DOMAIN" "$MANAGES_IDLE_KEY" 2>/dev/null || true)"
if [[ "$managed_idle_time" == "1" ]]; then
  current_idle_time="$($DEFAULTS_BIN -currentHost read "$SCREEN_SAVER_DOMAIN" "$SCREEN_SAVER_IDLE_KEY" 2>/dev/null || true)"
  if [[ "$current_idle_time" == "0" ]]; then
    if ! original_idle_time="$($DEFAULTS_BIN read "$APPLIANCE_PREFS_DOMAIN" "$ORIGINAL_IDLE_KEY" 2>/dev/null)" ||
       [[ ! "$original_idle_time" =~ $BACKED_UP_IDLE_PATTERN ]]; then
      echo "Cannot safely restore the original screen saver idleTime; preserved management backup" >&2
      exit 65
    fi

    if [[ "$original_idle_time" == "-1" ]]; then
      "$DEFAULTS_BIN" -currentHost delete "$SCREEN_SAVER_DOMAIN" "$SCREEN_SAVER_IDLE_KEY" >/dev/null 2>&1 || true
      echo "Restored the original absent local screen saver preference"
    else
      "$DEFAULTS_BIN" -currentHost write "$SCREEN_SAVER_DOMAIN" "$SCREEN_SAVER_IDLE_KEY" -int "$original_idle_time"
      echo "Restored local screen saver idleTime to $original_idle_time seconds"
    fi
  else
    # The user changed or removed the setting after installation. Their newer
    # choice takes precedence over the install-time backup.
    echo "Local screen saver setting changed after installation; preserving the current value"
  fi

  # Clear the marker only after restore/preservation succeeds. Delete it first
  # so a harmless orphaned backup can never make a later install look managed.
  "$DEFAULTS_BIN" delete "$APPLIANCE_PREFS_DOMAIN" "$MANAGES_IDLE_KEY"
  "$DEFAULTS_BIN" delete "$APPLIANCE_PREFS_DOMAIN" "$ORIGINAL_IDLE_KEY" >/dev/null 2>&1 || true
fi

managed_screen_lock="$($DEFAULTS_BIN read "$APPLIANCE_PREFS_DOMAIN" "$MANAGES_LOCK_KEY" 2>/dev/null || true)"
if [[ "$managed_screen_lock" == "1" ]]; then
  if [[ ! -x "$SYSADMINCTL_BIN" ]]; then
    echo "Required macOS screen-lock tool is unavailable; preserved management backup" >&2
    exit 1
  fi

  current_screen_lock="$(read_screen_lock_delay)"
  if [[ "$current_screen_lock" == "off" ]]; then
    if ! original_screen_lock="$($DEFAULTS_BIN read "$APPLIANCE_PREFS_DOMAIN" "$ORIGINAL_LOCK_KEY" 2>/dev/null)" ||
       [[ ! "$original_screen_lock" =~ $BACKED_UP_LOCK_PATTERN ]]; then
      echo "Cannot safely restore the original screen-lock delay; preserved management backup" >&2
      exit 65
    fi

    if [[ "$original_screen_lock" != "off" ]]; then
      if [[ -z "${TB_APPLIANCE_ACCOUNT_PASSWORD+x}" ]]; then
        echo "TB_APPLIANCE_ACCOUNT_PASSWORD must be set to restore the managed screen-lock delay" >&2
        exit 64
      fi
      if ! set_screen_lock_delay "$original_screen_lock"; then
        echo "Unable to restore the original screen-lock delay; preserved management backup" >&2
        exit 77
      fi
    fi
    echo "Restored the original screen-lock delay: $original_screen_lock"
  else
    # A newer security choice always wins, including immediate or N seconds.
    echo "Screen-lock setting changed after installation; preserving the current value"
  fi

  "$DEFAULTS_BIN" delete "$APPLIANCE_PREFS_DOMAIN" "$MANAGES_LOCK_KEY"
  "$DEFAULTS_BIN" delete "$APPLIANCE_PREFS_DOMAIN" "$ORIGINAL_LOCK_KEY" >/dev/null 2>&1 || true
fi

echo "iMac 5K Display Appliance login item removed. The app itself was left installed."
