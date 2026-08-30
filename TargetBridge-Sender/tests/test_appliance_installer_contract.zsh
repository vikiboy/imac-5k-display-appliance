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
require_literal "ProgramArguments:0 string /usr/bin/open"
require_literal "ProgramArguments:2 string --env"
require_literal "ProgramArguments:3 string DPCM=1"
require_literal 'ProgramArguments:4 string ${APP_PATH}'
require_literal "EnvironmentVariables:DPCM string 1"
require_literal "matching_sender_pids()"
require_literal "stop_existing_sender()"
require_literal '/bin/kill -TERM "$pid"'

# Monitor-mode lifecycle follows the source display's sleep state and keeps the
# inherited preference reversible instead of silently pinning both panels on.
require_literal 'PREVENT_DISPLAY_SLEEP_KEY="fd.tbdisplaysender.preventDisplaySleep"'
require_literal 'ORIGINAL_PREVENT_SLEEP_PATH="${STATE_DIR}/prevent-display-sleep.original"'
require_literal 'write "$PREFERENCE_DOMAIN" "$PREVENT_DISPLAY_SLEEP_KEY" -bool false'
require_literal 'LAUNCHCTL_BIN="${TB_LAUNCHCTL_BIN:-/bin/launchctl}"'

# These are the user-facing plug-in defaults for this personal appliance.
require_literal "ProgramArguments:8 string auto"
require_literal "ProgramArguments:10 string thunderbolt"
require_literal "ProgramArguments:12 string thunderbolt"
require_literal "ProgramArguments:14 string extended"
require_literal "ProgramArguments:16 string native5k60"
require_literal "ProgramArguments:18 string 0"
require_literal "ProgramArguments:20 string 1"
require_literal "ProgramArguments:22 string 0"

bootout_line=$(/usr/bin/grep -n '"$LAUNCHCTL_BIN" bootout' "$installer" |
  /usr/bin/head -1 | /usr/bin/cut -d: -f1)
stop_line=$(/usr/bin/grep -n '^stop_existing_sender$' "$installer" |
  /usr/bin/head -1 | /usr/bin/cut -d: -f1)
bootstrap_line=$(/usr/bin/grep -n '"$LAUNCHCTL_BIN" bootstrap' "$installer" |
  /usr/bin/head -1 | /usr/bin/cut -d: -f1)
if [[ -z "$bootout_line" || -z "$stop_line" || -z "$bootstrap_line" ]] ||
   (( bootout_line >= stop_line || stop_line >= bootstrap_line )); then
  print -u2 -- "sender installer must boot out, stop the exact app, then bootstrap"
  exit 1
fi

/bin/zsh -n "$installer"
print -- "sender appliance installer contract passed"
