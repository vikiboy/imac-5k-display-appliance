#!/bin/zsh
set -euo pipefail

installer="${1:-../scripts/install_targetbridge_5k_receiver_launch_agent.sh}"
[[ -f "$installer" ]] || {
  print -u2 "receiver installer test failed: missing $installer"
  exit 1
}

bootout_line="$(grep -n '"$LAUNCHCTL_BIN" bootout' "$installer" | head -1 | cut -d: -f1)"
enable_line="$(grep -n '"$LAUNCHCTL_BIN" enable "gui/$(id -u)/com.targetbridge.receiver5k"' "$installer" | head -1 | cut -d: -f1)"
bootstrap_line="$(grep -n '"$LAUNCHCTL_BIN" bootstrap "gui/$(id -u)" "$PLIST_PATH"' "$installer" | head -1 | cut -d: -f1)"
overlap_flag_line="$(grep -n 'ENABLE_RECEIVE_OVERLAP=.*TB_INSTALL_RECEIVE_OVERLAP.*:-0' "$installer" | head -1 | cut -d: -f1)"
overlap_line="$(grep -n 'EnvironmentVariables:TB_RECEIVE_OVERLAP string 1' "$installer" | head -1 | cut -d: -f1)"
open_line="$(grep -n 'ProgramArguments:0 string /usr/bin/open' "$installer" | head -1 | cut -d: -f1)"
interactive_line="$(grep -n 'ProcessType string Interactive' "$installer" | head -1 | cut -d: -f1)"
stop_line="$(grep -n '^stop_existing_receiver$' "$installer" | head -1 | cut -d: -f1)"

[[ -n "$bootout_line" && -n "$enable_line" && -n "$bootstrap_line" &&
   -n "$overlap_flag_line" && -n "$overlap_line" && -n "$open_line" &&
   -n "$interactive_line" && -n "$stop_line" ]] || {
  print -u2 "receiver installer test failed: lifecycle command missing"
  exit 1
}
(( overlap_flag_line < overlap_line && overlap_line < bootout_line )) || {
  print -u2 "receiver installer test failed: overlap environment must be serialized before install"
  exit 1
}
(( bootout_line < enable_line && enable_line < bootstrap_line )) || {
  print -u2 "receiver installer test failed: expected bootout < enable < bootstrap"
  exit 1
}
(( open_line < bootout_line && bootout_line < stop_line &&
   stop_line < bootstrap_line )) || {
  print -u2 "receiver installer test failed: expected LaunchServices open and bootout < exact-stop < bootstrap"
  exit 1
}

print "receiver installer lifecycle order passed (overlap defaults off; disabled override cleared before bootstrap)"
