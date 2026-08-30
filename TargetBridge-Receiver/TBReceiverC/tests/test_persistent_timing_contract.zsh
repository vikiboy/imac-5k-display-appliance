#!/bin/zsh
set -euo pipefail

receiver_source="${1:-benchmarks/benchmark_targetbridge_raw_receiver.m}"
[[ -f "$receiver_source" ]] || {
  print -u2 "persistent timing contract failed: missing $receiver_source"
  exit 1
}

rg -q 'timingCapacity = serveForever \? 600 : expectedFrames' \
  "$receiver_source"
rg -q 'receivedFrames % timingCapacity' "$receiver_source"
rg -q '\(receivedFrames - 1\) % timingCapacity' "$receiver_source"
rg -q 'availableGaps < timingCapacity' "$receiver_source"
! rg -q 'serveForever \? 36000' "$receiver_source"

print "persistent timing contract passed (rolling 600-frame window, no ten-minute page ramp)"
