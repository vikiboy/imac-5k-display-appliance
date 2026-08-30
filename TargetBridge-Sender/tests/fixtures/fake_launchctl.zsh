#!/bin/zsh
set -euo pipefail

# Exercise the real installer and uninstaller without mutating launchd.
if [[ -n "${TB_FAKE_LAUNCHCTL_FAIL_OPERATION:-}" &&
      "${1:-}" == "$TB_FAKE_LAUNCHCTL_FAIL_OPERATION" ]]; then
  if [[ -n "${TB_FAKE_LAUNCHCTL_START_PATH_ON_FAILURE:-}" ]]; then
    /usr/bin/nohup "$TB_FAKE_LAUNCHCTL_START_PATH_ON_FAILURE" 600 \
      >/dev/null 2>&1 &
    spawned_pid=$!
    if [[ -n "${TB_FAKE_LAUNCHCTL_PID_PATH:-}" ]]; then
      print -r -- "$spawned_pid" > "$TB_FAKE_LAUNCHCTL_PID_PATH"
    fi
  fi
  exit 70
fi
exit 0
