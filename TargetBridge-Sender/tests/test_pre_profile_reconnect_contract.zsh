#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
sender_dir="${script_dir:h}"
service="${sender_dir}/TBDisplaySender/TBDisplaySenderService.swift"
policy="${sender_dir}/TBDisplayShared/TBPreProfileReconnectPolicy.swift"

for required in "$service" "$policy"; do
  [[ -f "$required" ]] || {
    print -u2 -- "pre-profile reconnect contract failed: missing $required"
    exit 1
  }
done

# The retry ladder must only be armed by TCP-ready/no-profile evidence and
# must be used for the three wake-broker handoff failure surfaces.
rg -q 'preProfileReconnectPolicy\.handle\(\.tcpReadyWithoutProfile\)' "$service"
rg -q 'after: \.connectionEndedBeforeProfile' "$service"
rg -q 'after: \.displayProfileTimedOut' "$service"
retry_failure_count="$(rg -c 'after: \.retryConnectionFailedOrTimedOut' "$service")"
(( retry_failure_count >= 2 )) || {
  print -u2 -- "pre-profile reconnect contract failed: connect failure and timeout are not both covered"
  exit 1
}

# A received profile and every ordinary stop cancel/reset the finite retry.
rg -q 'preProfileReconnectPolicy\.handle\(\.displayProfileReceived\)' "$service"
rg -q 'cancelPreProfileReconnect\(resetPolicy: true\)' "$service"

# Appliance automation must regard the finite handoff as in progress instead
# of cancelling it and starting a competing outer-loop connection attempt.
automation="${sender_dir}/TBDisplaySender/TBDisplaySenderAutomation.swift"
automation_recovery_checks="$(rg -c 'session\.isRecoveringPreProfileConnection' "$automation")"
(( automation_recovery_checks >= 3 )) || {
  print -u2 -- "pre-profile reconnect contract failed: automation can cancel the handoff retry"
  exit 1
}
rg -q 'session\.hasNegotiatedDisplayProfile' "$automation"
rg -q 'automaticReconnectShouldResetBackoff' "$automation"
if rg -q 'let connectedAt = Date\(\)' "$automation"; then
  print -u2 -- "pre-profile reconnect contract failed: recovery-only time can reset outer backoff"
  exit 1
fi

# Capture/display allocation remains downstream of profile decoding; the
# reconnect helper is a control-plane-only path.
retry_helper="$(sed -n '/private func requestPreProfileReconnect/,/^    }/p' "$service")"
if print -r -- "$retry_helper" | rg -q 'startCapture|beginCaptureActivity|session\.create|SCStream|TBVideoPipeline'; then
  print -u2 -- "pre-profile reconnect contract failed: retry path allocates capture/display resources"
  exit 1
fi

print -- "sender pre-profile reconnect contract passed"
