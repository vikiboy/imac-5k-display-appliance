#!/bin/zsh
set -euo pipefail

APP_PATH="${1:-${HOME}/Applications/TargetBridge 5K Sender.app}"
EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/TargetBridge"
LABEL="com.vikiboy.imac5kdisplay.sender"
LEGACY_LABEL="com.targetbridge.sender5k"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${PLIST_DIR}/${LABEL}.plist"
LEGACY_PLIST_PATH="${PLIST_DIR}/${LEGACY_LABEL}.plist"
STATE_DIR="${HOME}/Library/Application Support/TargetBridge/Sender"
ENABLED_PATH="${STATE_DIR}/enabled"
PREFERENCE_DOMAIN="com.vikiboy.imac5kdisplay.sender"
PREVENT_DISPLAY_SLEEP_KEY="fd.tbdisplaysender.preventDisplaySleep"
ORIGINAL_PREVENT_SLEEP_PATH="${STATE_DIR}/prevent-display-sleep.original"
REQUIRE_STABLE_CODESIGN="${TB_REQUIRE_STABLE_CODESIGN:-1}"
DEFAULTS_BIN="${TB_DEFAULTS_BIN:-/usr/bin/defaults}"
LAUNCHCTL_BIN="${TB_LAUNCHCTL_BIN:-/bin/launchctl}"
CODESIGN_BIN="${TB_CODESIGN_BIN:-/usr/bin/codesign}"
PLIST_BUDDY_BIN="${TB_PLIST_BUDDY_BIN:-/usr/libexec/PlistBuddy}"

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

force_stop_existing_sender() {
  stop_existing_sender && return 0

  local pid
  local -a sender_pids
  sender_pids=("${(@f)$(matching_sender_pids)}")
  for pid in "${sender_pids[@]}"; do
    [[ -n "$pid" ]] || continue
    /bin/kill -KILL "$pid" 2>/dev/null || true
  done
  for _ in {1..20}; do
    [[ -z "$(matching_sender_pids)" ]] && return 0
    /bin/sleep 0.1
  done

  echo "Exact installed sender is still running; rollback remains disabled" >&2
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
if [[ ! -x "$CODESIGN_BIN" ]]; then
  echo "Required code-signature verifier is unavailable" >&2
  exit 1
fi
if [[ ! -x "$PLIST_BUDDY_BIN" ]]; then
  echo "Required property-list verifier is unavailable" >&2
  exit 1
fi

"$CODESIGN_BIN" --verify --deep --strict "$APP_PATH"
bundle_identifier="$("$PLIST_BUDDY_BIN" -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
bundle_executable="$("$PLIST_BUDDY_BIN" -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$bundle_identifier" != "com.vikiboy.imac5kdisplay.sender" || "$bundle_executable" != "TargetBridge" ]]; then
  echo "Sender identity mismatch; refusing to install launch agent" >&2
  exit 65
fi
if [[ "$REQUIRE_STABLE_CODESIGN" == 1 ]]; then
  signature_info="$("$CODESIGN_BIN" -d --verbose=4 "$APP_PATH" 2>&1)"
  designated_requirement="$("$CODESIGN_BIN" -d -r- "$APP_PATH" 2>&1)"
  if [[ "$signature_info" == *"Signature=adhoc"* ]]; then
    echo "Sender is ad-hoc signed; refusing monitor mode because Screen Recording permission would be unstable." >&2
    exit 65
  fi
  if [[ "$designated_requirement" != *'identifier "com.vikiboy.imac5kdisplay.sender"'* ||
        "$designated_requirement" != *"certificate root ="* ]]; then
    echo "Sender lacks a stable certificate-backed designated requirement." >&2
    exit 65
  fi
fi

mkdir -p "$PLIST_DIR" "$STATE_DIR"

PLIST_WORK_DIR="$(mktemp -d)"
PLIST_TEMPLATE="${PLIST_WORK_DIR}/agent.plist"
PREVIOUS_PLIST="${PLIST_WORK_DIR}/previous.plist"
PREVIOUS_LEGACY_PLIST="${PLIST_WORK_DIR}/previous-legacy.plist"
PREVIOUS_ORIGINAL_PREVENT_SLEEP="${PLIST_WORK_DIR}/previous-original-prevent-sleep"
MUTATION_STARTED=0
HAD_PREVIOUS_PLIST=0
HAD_LEGACY_PLIST=0
HAD_LEGACY_JOB=0
HAD_ENABLED_MARKER=0
HAD_ORIGINAL_PREVENT_SLEEP=0
PREVIOUS_PREVENT_SLEEP=absent

restore_preference_value() {
  case "$PREVIOUS_PREVENT_SLEEP" in
    absent)
      "$DEFAULTS_BIN" delete "$PREFERENCE_DOMAIN" "$PREVENT_DISPLAY_SLEEP_KEY" >/dev/null 2>&1 || true
      ;;
    0|1)
      "$DEFAULTS_BIN" write "$PREFERENCE_DOMAIN" "$PREVENT_DISPLAY_SLEEP_KEY" -bool "$PREVIOUS_PREVENT_SLEEP" >/dev/null 2>&1 || true
      ;;
  esac
}

cleanup() {
  local exit_status=$?
  set +e
  trap - EXIT
  if (( exit_status != 0 && MUTATION_STARTED == 1 )); then
    local sender_stopped=1
    "$LAUNCHCTL_BIN" disable "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || true
    "$LAUNCHCTL_BIN" bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
    "$LAUNCHCTL_BIN" disable "gui/$(id -u)/${LEGACY_LABEL}" >/dev/null 2>&1 || true
    "$LAUNCHCTL_BIN" bootout "gui/$(id -u)/${LEGACY_LABEL}" >/dev/null 2>&1 || true
    force_stop_existing_sender >/dev/null 2>&1 || sender_stopped=0
    if (( HAD_PREVIOUS_PLIST == 1 )); then
      install -m 0644 "$PREVIOUS_PLIST" "$PLIST_PATH"
    else
      [[ ! -e "$PLIST_PATH" ]] || unlink "$PLIST_PATH"
    fi
    if (( HAD_LEGACY_PLIST == 1 )); then
      install -m 0644 "$PREVIOUS_LEGACY_PLIST" "$LEGACY_PLIST_PATH"
    else
      [[ ! -e "$LEGACY_PLIST_PATH" ]] || unlink "$LEGACY_PLIST_PATH"
    fi
    if (( HAD_ENABLED_MARKER == 1 && sender_stopped == 1 )); then
      touch "$ENABLED_PATH"
    else
      [[ ! -e "$ENABLED_PATH" ]] || unlink "$ENABLED_PATH"
    fi
    restore_preference_value
    if (( HAD_ORIGINAL_PREVENT_SLEEP == 1 )); then
      install -m 0600 "$PREVIOUS_ORIGINAL_PREVENT_SLEEP" "$ORIGINAL_PREVENT_SLEEP_PATH"
    else
      [[ ! -e "$ORIGINAL_PREVENT_SLEEP_PATH" ]] || unlink "$ORIGINAL_PREVENT_SLEEP_PATH"
    fi
    if (( HAD_PREVIOUS_PLIST == 1 && HAD_ENABLED_MARKER == 1 && sender_stopped == 1 )); then
      "$LAUNCHCTL_BIN" enable "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || true
      "$LAUNCHCTL_BIN" bootstrap "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
    fi
    if (( HAD_LEGACY_JOB == 1 && HAD_LEGACY_PLIST == 1 && HAD_ENABLED_MARKER == 1 && sender_stopped == 1 )); then
      "$LAUNCHCTL_BIN" enable "gui/$(id -u)/${LEGACY_LABEL}" >/dev/null 2>&1 || true
      "$LAUNCHCTL_BIN" bootstrap "gui/$(id -u)" "$LEGACY_PLIST_PATH" >/dev/null 2>&1 || true
    fi
    if (( sender_stopped == 0 )); then
      echo "Rollback could not stop the exact sender; automatic mode remains disabled." >&2
    fi
    echo "Sender monitor-mode installation failed; prior state was restored." >&2
  fi
  [[ ! -e "$PLIST_TEMPLATE" ]] || unlink "$PLIST_TEMPLATE"
  [[ ! -e "$PREVIOUS_PLIST" ]] || unlink "$PREVIOUS_PLIST"
  [[ ! -e "$PREVIOUS_LEGACY_PLIST" ]] || unlink "$PREVIOUS_LEGACY_PLIST"
  [[ ! -e "$PREVIOUS_ORIGINAL_PREVENT_SLEEP" ]] || unlink "$PREVIOUS_ORIGINAL_PREVENT_SLEEP"
  rmdir "$PLIST_WORK_DIR" 2>/dev/null || true
  return "$exit_status"
}
trap cleanup EXIT

/usr/libexec/PlistBuddy -c "Add :Label string ${LABEL}" "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:0 string /bin/zsh' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:1 string -c' "$PLIST_TEMPLATE"
# KeepAlive is allowed to launch a job once speculatively while PathState is
# false. This wrapper exits before LaunchServices or the app exists, closing the
# race between bootstrap and creating the enabled marker. The app repeats the
# marker check as defense in depth.
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:2 string marker-gate' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:3 string imac5k-monitor-launch' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string ${ENABLED_PATH}" "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:5 string /usr/bin/open' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:6 string -W' "$PLIST_TEMPLATE"
# Never let LaunchServices reuse a different checkout or rollback carrying the
# same upstream-compatible bundle identifier. `-n` makes the exact stable path
# below the process whose arguments, environment and TCC identity are used.
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:7 string -n' "$PLIST_TEMPLATE"
# Pass the lossless transport through both launchd and `open`. LaunchServices
# does not retroactively apply launchd's environment to an already-running app,
# and a missing DPCM flag makes this strict receiver correctly reject HEVC.
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:8 string --env' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:9 string DPCM=1' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:10 string ${APP_PATH}" "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:11 string --args' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:12 string --connect' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:13 string --receiver' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:14 string auto' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:15 string --transport' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:16 string thunderbolt' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:17 string --path' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:18 string thunderbolt' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:19 string --mode' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:20 string extended' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:21 string --preset' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:22 string native5k60' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:23 string --audio' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:24 string 0' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:25 string --retry' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:26 string 1' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:27 string --large-cursor' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:28 string 0' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:29 string --require-enabled-marker' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:30 string 1' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables dict' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables:DPCM string 1' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :KeepAlive dict' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :KeepAlive:PathState dict' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c "Add ':KeepAlive:PathState:${ENABLED_PATH}' bool true" "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool false' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ThrottleInterval integer 15' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :ProcessType string Interactive' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :LimitLoadToSessionType array' "$PLIST_TEMPLATE"
/usr/libexec/PlistBuddy -c 'Add :LimitLoadToSessionType:0 string Aqua' "$PLIST_TEMPLATE"

# PlistBuddy treats quote characters as its own parser syntax. Replace this one
# argument with plutil so the shell quotes survive literally in the plist.
/usr/bin/plutil -replace ProgramArguments.2 -string '[[ -e "$1" ]] || exit 0; shift; exec "$@"' "$PLIST_TEMPLATE"
# `plutil -replace` inserts before an array element on current macOS instead of
# consuming PlistBuddy's quote-safe placeholder. Remove that shifted placeholder
# so `$0` is the diagnostic command name and `$1` is the real enabled marker.
/usr/bin/plutil -remove ProgramArguments.3 "$PLIST_TEMPLATE"

plutil -lint "$PLIST_TEMPLATE"

# Validate all reversible state before touching preferences, markers or the
# registered job. This keeps a bad app/plist from leaving a half-enabled setup.
PREVIOUS_PREVENT_SLEEP="$($DEFAULTS_BIN read "$PREFERENCE_DOMAIN" "$PREVENT_DISPLAY_SLEEP_KEY" 2>/dev/null || true)"
case "$PREVIOUS_PREVENT_SLEEP" in
  0|1) ;;
  '') PREVIOUS_PREVENT_SLEEP=absent ;;
  *)
    echo "Unexpected prevent-display-sleep preference; no change was made" >&2
    exit 65
    ;;
esac

if [[ -e "$ORIGINAL_PREVENT_SLEEP_PATH" ]]; then
  original_prevent_sleep="$(<"$ORIGINAL_PREVENT_SLEEP_PATH")"
  case "$original_prevent_sleep" in
    absent|0|1) ;;
    *)
      echo "Invalid saved prevent-display-sleep preference; no change was made" >&2
      exit 65
      ;;
  esac
  HAD_ORIGINAL_PREVENT_SLEEP=1
  install -m 0600 "$ORIGINAL_PREVENT_SLEEP_PATH" "$PREVIOUS_ORIGINAL_PREVENT_SLEEP"
else
  original_prevent_sleep="$PREVIOUS_PREVENT_SLEEP"
fi
if [[ -e "$PLIST_PATH" ]]; then
  HAD_PREVIOUS_PLIST=1
  install -m 0644 "$PLIST_PATH" "$PREVIOUS_PLIST"
fi
if [[ -e "$LEGACY_PLIST_PATH" ]]; then
  HAD_LEGACY_PLIST=1
  install -m 0644 "$LEGACY_PLIST_PATH" "$PREVIOUS_LEGACY_PLIST"
fi
if "$LAUNCHCTL_BIN" print "gui/$(id -u)/${LEGACY_LABEL}" >/dev/null 2>&1; then
  HAD_LEGACY_JOB=1
fi
[[ ! -e "$ENABLED_PATH" ]] || HAD_ENABLED_MARKER=1

MUTATION_STARTED=1
[[ ! -e "$ENABLED_PATH" ]] || unlink "$ENABLED_PATH"
"$LAUNCHCTL_BIN" bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
# Build 18 used a different label but the same enabled marker and executable.
# Retire it before recreating the marker, otherwise both jobs can launch the
# sender and create duplicate virtual displays after an in-place upgrade.
"$LAUNCHCTL_BIN" disable "gui/$(id -u)/${LEGACY_LABEL}" >/dev/null 2>&1 || true
"$LAUNCHCTL_BIN" bootout "gui/$(id -u)/${LEGACY_LABEL}" >/dev/null 2>&1 || true
"$LAUNCHCTL_BIN" bootout "gui/$(id -u)" "$LEGACY_PLIST_PATH" >/dev/null 2>&1 || true
stop_existing_sender
[[ ! -e "$LEGACY_PLIST_PATH" ]] || unlink "$LEGACY_PLIST_PATH"
install -m 0644 "$PLIST_TEMPLATE" "$PLIST_PATH"

# A physical monitor follows the source Mac's display-sleep policy. Preserve
# the pre-appliance value once. Establish the monitor marker before the single
# bootstrap so PathState and the installer cannot race to launch two `open -n`
# app instances. Rollback force-stops an ambiguously launched exact-path app and
# restores every prior artifact if bootstrap reports failure.
if (( HAD_ORIGINAL_PREVENT_SLEEP == 0 )); then
  original_prevent_sleep_work="$(mktemp "${STATE_DIR}/prevent-display-sleep.original.XXXXXX")"
  print -r -- "$original_prevent_sleep" > "$original_prevent_sleep_work"
  /bin/chmod 0600 "$original_prevent_sleep_work"
  /bin/mv "$original_prevent_sleep_work" "$ORIGINAL_PREVENT_SLEEP_PATH"
fi
"$DEFAULTS_BIN" write "$PREFERENCE_DOMAIN" "$PREVENT_DISPLAY_SLEEP_KEY" -bool false
touch "$ENABLED_PATH"
"$LAUNCHCTL_BIN" enable "gui/$(id -u)/${LABEL}"
"$LAUNCHCTL_BIN" bootstrap "gui/$(id -u)" "$PLIST_PATH"
MUTATION_STARTED=0

echo "iMac 5K Display Sender monitor mode enabled: $APP_PATH"
echo "TargetBridge no longer prevents source-display sleep (original preference preserved)"
echo "First setup has two explicit phases: grant Screen Recording once, quit the app, then run this installer once more."
