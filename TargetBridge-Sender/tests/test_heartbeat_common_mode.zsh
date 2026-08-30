#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
service="${script_dir:h}/TBDisplaySender/TBDisplaySenderService.swift"

[[ -f "$service" ]] || {
  print -u2 -- "sender heartbeat contract failed: missing service source"
  exit 1
}

heartbeat_body="$(sed -n '/private func startHeartbeat()/,/private func startFirstFrameWatchdog/p' "$service")"

[[ "$heartbeat_body" == *'Timer(timeInterval: 2, repeats: true)'* ]] || {
  print -u2 -- "sender heartbeat contract failed: two-second timer missing"
  exit 1
}
[[ "$heartbeat_body" == *'RunLoop.main.add(timer, forMode: .common)'* ]] || {
  print -u2 -- "sender heartbeat contract failed: timer is not in common run-loop modes"
  exit 1
}
[[ "$heartbeat_body" != *'Timer.scheduledTimer'* ]] || {
  print -u2 -- "sender heartbeat contract failed: default-mode scheduled timer returned"
  exit 1
}

print -- "sender common-mode heartbeat contract passed"
