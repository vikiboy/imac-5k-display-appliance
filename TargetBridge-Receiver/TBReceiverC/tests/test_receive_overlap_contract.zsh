#!/bin/zsh
set -euo pipefail

receiver_source="${1:-benchmarks/benchmark_targetbridge_raw_receiver.m}"
[[ -f "$receiver_source" ]] || {
  print -u2 "receive overlap contract failed: missing $receiver_source"
  exit 1
}

rg -q 'primaryPayloadHighWater' "$receiver_source"
rg -q 'secondaryPayloadHighWater' "$receiver_source"

rg -q 'environment_flag_enabled\("TB_RECEIVE_OVERLAP"\)' "$receiver_source"
rg -q 'payloadSecondary = receiveOverlapEnabled' "$receiver_source"
rg -q 'dispatch_queue_create\(' "$receiver_source"
rg -q 'com\.targetbridge\.receiver5k\.receive-prefetch' "$receiver_source"
rg -q 'NSCAssert\(!receivePrefetchInFlight' "$receiver_source"
rg -q '17 \* NSEC_PER_SEC' "$receiver_source"
rg -q '2 \* NSEC_PER_SEC' "$receiver_source"
! rg -q 'DISPATCH_TIME_FOREVER' "$receiver_source"
rg -q 'shutdown\(peer, SHUT_RDWR\)' "$receiver_source"
rg -q '@finally' "$receiver_source"

prefetch_line="$(rg -n 'dispatch_async\(receivePrefetchQueue' "$receiver_source" | head -1 | cut -d: -f1)"
render_line="$(rg -n 'renderResult = tb_native_metal_render_(nv12_planes|dpcm)' "$receiver_source" | head -1 | cut -d: -f1)"
cleanup_line="$(rg -n '^        cancelReceivePrefetch\(\);' "$receiver_source" | tail -1 | cut -d: -f1)"

[[ -n "$prefetch_line" && -n "$render_line" && -n "$cleanup_line" ]] || {
  print -u2 "receive overlap contract failed: pipeline ordering marker missing"
  exit 1
}
(( prefetch_line < render_line && render_line < cleanup_line )) || {
  print -u2 "receive overlap contract failed: expected prefetch < render < cleanup"
  exit 1
}

secondary_allocations="$(rg -c 'malloc\(TB_MAX_PACKET_LENGTH - 1\)' "$receiver_source")"
[[ "$secondary_allocations" == "2" ]] || {
  print -u2 "receive overlap contract failed: expected exactly two fixed packet buffers"
  exit 1
}

print "receive overlap contract passed (two fixed slots, single-flight prefetch, bounded cleanup)"
