#!/bin/zsh
set -euo pipefail

installer="${1:-../scripts/install_targetbridge_5k_receiver_launch_agent.sh}"
[[ -f "$installer" ]] || {
  print -u2 "receiver installer test failed: missing $installer"
  exit 1
}

bootout_line="$(grep -n 'launchctl bootout' "$installer" | head -1 | cut -d: -f1)"
enable_line="$(grep -n 'launchctl enable "gui/$(id -u)/com.targetbridge.receiver5k"' "$installer" | head -1 | cut -d: -f1)"
bootstrap_line="$(grep -n 'launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"' "$installer" | head -1 | cut -d: -f1)"

[[ -n "$bootout_line" && -n "$enable_line" && -n "$bootstrap_line" ]] || {
  print -u2 "receiver installer test failed: lifecycle command missing"
  exit 1
}
(( bootout_line < enable_line && enable_line < bootstrap_line )) || {
  print -u2 "receiver installer test failed: expected bootout < enable < bootstrap"
  exit 1
}

print "receiver installer lifecycle order passed (disabled override cleared before bootstrap)"
