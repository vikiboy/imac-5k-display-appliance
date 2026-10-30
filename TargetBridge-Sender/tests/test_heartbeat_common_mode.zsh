#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
service="${script_dir:h}/TBDisplaySender/TBDisplaySenderService.swift"

[[ -f "$service" ]] || {
  print -u2 -- "sender heartbeat contract failed: missing service source"
  exit 1
}

heartbeat_body="$(sed -n '/private func startHeartbeat()/,/private func startFirstFrameWatchdog/p' "$service")"
send_body="$(sed -n '/private func send(_ packet: Data)/,/func sendInputEvent/p' "$service")"

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
[[ "$send_body" == *'guard let activeConnection = connection else { return }'* ]] || {
  print -u2 -- "sender heartbeat contract failed: control sends do not pin the active connection"
  exit 1
}
[[ "$send_body" == *'self.connection === activeConnection'* ]] || {
  print -u2 -- "sender heartbeat contract failed: delayed errors can tear down a replacement connection"
  exit 1
}
[[ "$send_body" == *'teardownReason: "sender_control_send_failed"'* ]] || {
  print -u2 -- "sender heartbeat contract failed: send errors do not recycle the stale session"
  exit 1
}
[[ "$send_body" == *'persistArrangement: false'* ]] || {
  print -u2 -- "sender heartbeat contract failed: recovery can overwrite the saved display arrangement"
  exit 1
}
[[ "$send_body" != *'.contentProcessed({ _ in })'* ]] || {
  print -u2 -- "sender heartbeat contract failed: send errors are still discarded"
  exit 1
}

print -- "sender common-mode heartbeat and send-failure recovery contracts passed"
