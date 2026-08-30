#!/bin/zsh
set -euo pipefail

APP_PATH="${1:-${HOME}/Applications/TargetBridge 5K Receiver.app}"
EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/TargetBridge5KReceiver"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${PLIST_DIR}/com.targetbridge.receiver5k.plist"
ENABLE_RECEIVE_OVERLAP="${TB_INSTALL_RECEIVE_OVERLAP:-0}"
DISABLE_SCREEN_LOCK="${TB_APPLIANCE_DISABLE_SCREEN_LOCK:-0}"
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
NONNEGATIVE_INTEGER_PATTERN='^[0-9]+$'
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
    echo "Unrecognized screen-lock status; no screen-lock change was made" >&2
    return 65
  fi
}

set_screen_lock_delay() {
  local target="$1"
  local command_status
  local xtrace_was_enabled=0
  [[ -o xtrace ]] && xtrace_was_enabled=1

  # sysadminctl accepts the account password only as an argument. Disable shell
  # tracing before expanding it, suppress tool output, and never persist it.
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

  # bootout terminates the `open -W` supervisor, but LaunchServices owns the
  # app process. Stop only this exact installed executable before bootstrap so
  # the new supervisor cannot attach to a stale singleton.
  for _ in {1..50}; do
    [[ -z "$(matching_receiver_pids)" ]] && return 0
    /bin/sleep 0.1
  done

  echo "Existing iMac 5K Display Appliance did not quit; launch agent not started." >&2
  return 1
}

if [[ "$ENABLE_RECEIVE_OVERLAP" != "0" &&
      "$ENABLE_RECEIVE_OVERLAP" != "1" ]]; then
  echo "TB_INSTALL_RECEIVE_OVERLAP must be 0 or 1" >&2
  exit 64
fi

if [[ "$DISABLE_SCREEN_LOCK" != "0" && "$DISABLE_SCREEN_LOCK" != "1" ]]; then
  echo "TB_APPLIANCE_DISABLE_SCREEN_LOCK must be 0 or 1" >&2
  exit 64
fi

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Receiver executable not found: $EXECUTABLE_PATH" >&2
  exit 1
fi

if [[ ! -x "$DEFAULTS_BIN" || ! -x "$LAUNCHCTL_BIN" ]]; then
  echo "Required macOS preference or service tool is unavailable" >&2
  exit 1
fi

if [[ "$DISABLE_SCREEN_LOCK" == "1" ]]; then
  if [[ ! -x "$SYSADMINCTL_BIN" ]]; then
    echo "Required macOS screen-lock tool is unavailable" >&2
    exit 1
  fi
  # Presence is required, but an explicitly empty password is valid for an
  # account that has no password.
  if [[ -z "${TB_APPLIANCE_ACCOUNT_PASSWORD+x}" ]]; then
    echo "TB_APPLIANCE_ACCOUNT_PASSWORD must be set when screen-lock management is enabled" >&2
    exit 64
  fi
fi

# A running receiver holds a display-sleep assertion only while a MacBook is
# actively streaming. Disable the iMac's local screen saver separately so it
# cannot cover a newly connected stream. Preserve the original current-host
# value once; a reinstall must never replace that backup with the managed 0.
managed_idle_time="$($DEFAULTS_BIN read "$APPLIANCE_PREFS_DOMAIN" "$MANAGES_IDLE_KEY" 2>/dev/null || true)"
if [[ "$managed_idle_time" != "1" ]]; then
  if original_idle_time="$($DEFAULTS_BIN -currentHost read "$SCREEN_SAVER_DOMAIN" "$SCREEN_SAVER_IDLE_KEY" 2>/dev/null)"; then
    if [[ ! "$original_idle_time" =~ $NONNEGATIVE_INTEGER_PATTERN ]]; then
      echo "Unexpected screen saver idleTime: $original_idle_time" >&2
      exit 65
    fi
  else
    # -1 represents an absent preference so uninstall can restore absence.
    original_idle_time=-1
  fi
  "$DEFAULTS_BIN" write "$APPLIANCE_PREFS_DOMAIN" "$ORIGINAL_IDLE_KEY" -int "$original_idle_time"
  # Write the marker before changing idleTime. If installation is interrupted,
  # uninstall still has enough information to restore the original preference.
  "$DEFAULTS_BIN" write "$APPLIANCE_PREFS_DOMAIN" "$MANAGES_IDLE_KEY" -bool true
fi
"$DEFAULTS_BIN" -currentHost write "$SCREEN_SAVER_DOMAIN" "$SCREEN_SAVER_IDLE_KEY" -int 0

# Screen-lock changes are security-sensitive and therefore opt-in. A dedicated
# iMac appliance may disable the idle lock so a cable reconnect can immediately
# foreground the receiver; normal installations retain the macOS lock policy.
if [[ "$DISABLE_SCREEN_LOCK" == "1" ]]; then
  managed_screen_lock="$($DEFAULTS_BIN read "$APPLIANCE_PREFS_DOMAIN" "$MANAGES_LOCK_KEY" 2>/dev/null || true)"
  if [[ "$managed_screen_lock" != "1" ]]; then
    original_screen_lock="$(read_screen_lock_delay)"
    "$DEFAULTS_BIN" write "$APPLIANCE_PREFS_DOMAIN" "$ORIGINAL_LOCK_KEY" -string "$original_screen_lock"
    # As with idleTime, mark ownership before mutation so an interrupted install
    # retains the original value for uninstall/recovery.
    "$DEFAULTS_BIN" write "$APPLIANCE_PREFS_DOMAIN" "$MANAGES_LOCK_KEY" -bool true
  elif ! original_screen_lock="$($DEFAULTS_BIN read "$APPLIANCE_PREFS_DOMAIN" "$ORIGINAL_LOCK_KEY" 2>/dev/null)" ||
       [[ ! "$original_screen_lock" =~ $BACKED_UP_LOCK_PATTERN ]]; then
    echo "Cannot safely continue managed screen-lock setup; preserved management marker" >&2
    exit 65
  fi
  if ! set_screen_lock_delay off; then
    echo "Unable to disable screen lock; preserved the original setting for recovery" >&2
    exit 77
  fi
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
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:0 string /usr/bin/open' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:1 string -W' "$PLIST_TEMPLATE"
# Launch the bundle through LaunchServices so AppKit can register a regular
# foreground application. Direct launchd execution registers a UIElement and
# makes Core Graphics' documented foreground-only cursor hide ineffective.
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:2 string --env' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:3 string TB_RECEIVE_OVERLAP=${ENABLE_RECEIVE_OVERLAP}" "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string ${APP_PATH}" "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :KeepAlive bool true' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ThrottleInterval integer 10' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProcessType string Interactive' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :LimitLoadToSessionType array' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :LimitLoadToSessionType:0 string Aqua' "$PLIST_TEMPLATE"
# Keep the experimental two-slot receive pipeline off until the exact iMac has
# passed its live serial/overlap A/B gate. Opt-in still remains bounded to one
# additional reusable 64 MiB packet slot and never creates a disk cache.
if [[ "$ENABLE_RECEIVE_OVERLAP" == "1" ]]; then
  /usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables dict' "$PLIST_TEMPLATE"
  /usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables:TB_RECEIVE_OVERLAP string 1' "$PLIST_TEMPLATE"
fi

plutil -lint "$PLIST_TEMPLATE"
install -m 0644 "$PLIST_TEMPLATE" "$PLIST_PATH"
"$LAUNCHCTL_BIN" bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
stop_existing_receiver
# Clear a stale disabled override before bootstrap. launchd otherwise accepts
# the plist but can leave a previously disabled receiver inactive.
"$LAUNCHCTL_BIN" enable "gui/$(id -u)/com.targetbridge.receiver5k"
"$LAUNCHCTL_BIN" bootstrap "gui/$(id -u)" "$PLIST_PATH"

echo "iMac 5K Display Appliance will start at login: $APP_PATH"
echo "Experimental receive overlap enabled: $ENABLE_RECEIVE_OVERLAP"
echo "Local screen saver disabled while the display appliance is installed (original setting preserved)"
if [[ "$DISABLE_SCREEN_LOCK" == "1" ]]; then
  echo "Screen lock disabled for dedicated-appliance reconnects (original setting preserved)"
else
  echo "Screen lock unchanged (set TB_APPLIANCE_DISABLE_SCREEN_LOCK=1 to opt in)"
fi
