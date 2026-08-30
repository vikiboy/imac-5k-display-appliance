#!/bin/zsh
set -euo pipefail

power_source="${1:-src/tb_power_lifecycle.c}"
receiver_source="${2:-benchmarks/benchmark_targetbridge_raw_receiver.m}"

[[ -f "$power_source" && -f "$receiver_source" ]] || {
  print -u2 "display session activity contract failed: source file missing"
  exit 1
}

[[ "$(rg -c 'IOPMAssertionDeclareUserActivity\(' "$power_source")" == "1" ]]
rg -q 'kIOPMUserActiveRemote' "$power_source"
rg -q 'IOPMAssertionID activityAssertion =[[:space:]]*' "$power_source"
rg -q 'lifecycle->user_activity_assertion = \(uint32_t\)activityAssertion' "$power_source"
rg -q 'tb_power_release\([[:space:][:print:]]*' "$power_source"
rg -q '&lifecycle->user_activity_assertion' "$power_source"
! rg -q 'refresh_session_activity|USER_ACTIVITY_REFRESH|last_user_activity_refresh' \
  "$power_source" "$receiver_source"

# Receiver/source wake must recreate the complete bounded session pair. A
# display-sleep assertion by itself prevents a future idle sleep but cannot wake
# a panel that slept while the source display was unavailable.
power_gate="$(sed -n '/displayPowerGateHandler =/,/^        };/p' "$receiver_source")"
print -r -- "$power_gate" | rg -q \
  'tb_power_lifecycle_begin_session\(&powerLifecycle\)'
if print -r -- "$power_gate" | rg -q \
  'tb_power_lifecycle_hold_display_awake\(&powerLifecycle\)'; then
  print -u2 'display session activity contract failed: source wake does not request panel wake'
  exit 1
fi

display_create_line="$(rg -n 'kIOPMAssertionTypePreventUserIdleDisplaySleep' "$power_source" | head -1 | cut -d: -f1)"
wake_line="$(rg -n 'IOPMAssertionDeclareUserActivity\(' "$power_source" | head -1 | cut -d: -f1)"
activity_release_line="$(rg -n '&lifecycle->user_activity_assertion' "$power_source" | tail -1 | cut -d: -f1)"
display_release_line="$(rg -n '&lifecycle->display_sleep_assertion' "$power_source" | tail -1 | cut -d: -f1)"

[[ -n "$display_create_line" && -n "$wake_line" && \
   -n "$activity_release_line" && -n "$display_release_line" ]] || {
  print -u2 "display session activity contract failed: lifecycle marker missing"
  exit 1
}
(( display_create_line < wake_line )) || {
  print -u2 "display session activity contract failed: hold display assertion before waking panel"
  exit 1
}
(( activity_release_line < display_release_line )) || {
  print -u2 "display session activity contract failed: release wake ID before display assertion"
  exit 1
}

print "display session activity contract passed (one wake per active interval, hold display assertion, release at session end)"
