#!/bin/zsh
set -euo pipefail

installer="${1:-../scripts/install_targetbridge_5k_sender_launch_agent.sh}"

[[ -f "$installer" ]] || {
  print -u2 -- "sender installer not found: $installer"
  exit 2
}

require_literal() {
  local expected="$1"
  if ! /usr/bin/grep -Fq -- "$expected" "$installer"; then
    print -u2 -- "missing sender appliance contract: $expected"
    exit 1
  fi
}

# The strict 2017-iMac appliance refuses lossy video packets. Assert both
# launchd's environment and LaunchServices' explicit environment so `open`
# cannot silently start HEVC when it creates the application process.
require_literal "ProgramArguments:0 string /bin/zsh"
require_literal "ProgramArguments:2 string marker-gate"
require_literal "plutil -replace ProgramArguments.2"
require_literal "plutil -remove ProgramArguments.3"
require_literal 'ProgramArguments:4 string ${ENABLED_PATH}'
require_literal "ProgramArguments:5 string /usr/bin/open"
require_literal "ProgramArguments:7 string -n"
require_literal "ProgramArguments:8 string --env"
require_literal "ProgramArguments:9 string DPCM=1"
require_literal 'ProgramArguments:10 string ${APP_PATH}'
require_literal "EnvironmentVariables:DPCM string 1"
require_literal "matching_sender_pids()"
require_literal "stop_existing_sender()"
require_literal "force_stop_existing_sender()"
require_literal '/bin/kill -TERM "$pid"'
require_literal '/bin/kill -KILL "$pid"'
require_literal 'CODESIGN_BIN="${TB_CODESIGN_BIN:-/usr/bin/codesign}"'
require_literal 'REQUIRE_STABLE_CODESIGN="${TB_REQUIRE_STABLE_CODESIGN:-1}"'
require_literal 'Sender is ad-hoc signed'
require_literal 'certificate-backed designated requirement'
require_literal 'bundle_identifier'
require_literal "MUTATION_STARTED=1"
require_literal "prior state was restored"

# Monitor-mode lifecycle follows the source display's sleep state and keeps the
# inherited preference reversible instead of silently pinning both panels on.
require_literal 'PREVENT_DISPLAY_SLEEP_KEY="fd.tbdisplaysender.preventDisplaySleep"'
require_literal 'ORIGINAL_PREVENT_SLEEP_PATH="${STATE_DIR}/prevent-display-sleep.original"'
require_literal 'write "$PREFERENCE_DOMAIN" "$PREVENT_DISPLAY_SLEEP_KEY" -bool false'
require_literal 'LAUNCHCTL_BIN="${TB_LAUNCHCTL_BIN:-/bin/launchctl}"'
require_literal 'LEGACY_LABEL="com.targetbridge.sender5k"'
require_literal 'HAD_LEGACY_JOB=0'
require_literal 'bootout "gui/$(id -u)/${LEGACY_LABEL}"'
require_literal 'install -m 0644 "$PREVIOUS_LEGACY_PLIST" "$LEGACY_PLIST_PATH"'

# These are the user-facing plug-in defaults for this personal appliance.
require_literal "ProgramArguments:14 string auto"
require_literal "ProgramArguments:16 string thunderbolt"
require_literal "ProgramArguments:18 string thunderbolt"
require_literal "ProgramArguments:20 string extended"
require_literal "ProgramArguments:22 string native5k60"
require_literal "ProgramArguments:24 string 0"
require_literal "ProgramArguments:26 string 1"
require_literal "ProgramArguments:28 string 0"
require_literal "ProgramArguments:29 string --require-enabled-marker"
require_literal "ProgramArguments:30 string 1"
require_literal "RunAtLoad bool false"

mutation_line=$(/usr/bin/grep -n '^MUTATION_STARTED=1$' "$installer" |
  /usr/bin/tail -1 | /usr/bin/cut -d: -f1)
bootout_line=$(/usr/bin/awk -v start="$mutation_line" \
  'NR > start && /"\$LAUNCHCTL_BIN" bootout/ { print NR; exit }' "$installer")
stop_line=$(/usr/bin/awk -v start="$mutation_line" \
  'NR > start && /^stop_existing_sender$/ { print NR; exit }' "$installer")
bootstrap_line=$(/usr/bin/awk -v start="$mutation_line" \
  'NR > start && /"\$LAUNCHCTL_BIN" bootstrap/ { print NR; exit }' "$installer")
if [[ -z "$bootout_line" || -z "$stop_line" || -z "$bootstrap_line" ]] ||
   (( bootout_line >= stop_line || stop_line >= bootstrap_line )); then
  print -u2 -- "sender installer must boot out, stop the exact app, then bootstrap"
  exit 1
fi

marker_line=$(/usr/bin/awk -v start="$mutation_line" \
  'NR > start && /^touch "\$ENABLED_PATH"$/ { print NR; exit }' "$installer")
if [[ -z "$marker_line" ]] || (( marker_line >= bootstrap_line )); then
  print -u2 -- "sender installer must establish one launch marker before its single bootstrap"
  exit 1
fi
if (( $(/usr/bin/grep -F -c '"$LAUNCHCTL_BIN" bootstrap "gui/$(id -u)" "$PLIST_PATH"' "$installer") != 2 )); then
  print -u2 -- "unexpected sender bootstrap authority count"
  exit 1
fi
if /usr/bin/grep -Fq -- 'kickstart -k' "$installer"; then
  print -u2 -- "sender installer must not combine PathState launch with kickstart"
  exit 1
fi

/bin/zsh -n "$installer"
print -- "sender appliance installer contract passed"
