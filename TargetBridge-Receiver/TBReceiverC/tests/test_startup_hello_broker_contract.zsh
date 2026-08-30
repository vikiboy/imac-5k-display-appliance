#!/bin/zsh
set -euo pipefail

receiver_source="${1:-benchmarks/benchmark_targetbridge_raw_receiver.m}"
[[ -f "$receiver_source" ]] || {
  print -u2 "startup HELLO broker contract failed: missing $receiver_source"
  exit 1
}

# A sleeping display is not a drawable surface even if Core Graphics still
# lists it as active.
rg -q 'CGDisplayIsAsleep\(displayID\)' "$receiver_source"

# Both startup and full admission must share the one packet classifier. This
# prevents a wake-only listener from drifting into a more permissive protocol.
[[ "$(rg -c 'receive_pre_session_hello_before\(' "$receiver_source")" == "3" ]]
[[ "$(rg -c 'tb_pre_session_classify\(' "$receiver_source")" == "1" ]]
rg -q 'peer_arrived_via_bridge0_link_local\(peer\)' "$receiver_source"
rg -q 'getpeername\(' "$receiver_source"

# The startup path exists only for persistent appliance mode, advertises a
# non-drawable control plane, closes the temporary peer, and bounds both packet
# admission and the physical panel wake.
rg -q 'if \(!screen && serveForever\)' "$receiver_source"
rg -q 'startup=hello-broker-listening.*surface=false' "$receiver_source"
rg -q 'TB_SERVE_PEER_IDLE_TIMEOUT_SECONDS' "$receiver_source"
rg -q 'CACurrentMediaTime\(\) \+ 8\.0' "$receiver_source"
rg -q 'close\(peer\);' "$receiver_source"
rg -q 'g_startup_termination_signal' "$receiver_source"
rg -q 'record_startup_termination_signal' "$receiver_source"
if rg -q 'pthread_sigmask\(' "$receiver_source"; then
  print -u2 'startup HELLO broker contract failed: thread-local signal-mask handoff returned'
  exit 1
fi

# One process-wide async-signal-safe latch must cover broker setup and the
# renderer/listener startup interval. The ordinary dispatch sources are created
# and activated before the POSIX disposition changes to SIG_IGN, after which a
# latched startup request is replayed through the normal shutdown gate. This
# avoids a thread-local mask handoff that could lose a signal delivered to a
# Bonjour/AppKit worker.
handler_install_line="$(rg -n 'sigaction\(SIGTERM, &startupAction' "$receiver_source" | cut -d: -f1)"
broker_call_line="$(rg -n '^            screen = wait_for_native_panel_after_sender_hello' "$receiver_source" | cut -d: -f1)"
term_source_line="$(rg -n 'dispatch_source_t sigtermSource = termination_signal_source' "$receiver_source" | cut -d: -f1)"
int_source_line="$(rg -n 'dispatch_source_t sigintSource = termination_signal_source' "$receiver_source" | cut -d: -f1)"
term_ignore_line="$(rg -n 'signal\(SIGTERM, SIG_IGN\)' "$receiver_source" | cut -d: -f1)"
replay_line="$(rg -n 'source=startup-handoff' "$receiver_source" | cut -d: -f1)"
[[ -n "$handler_install_line" && -n "$broker_call_line" && \
   -n "$term_source_line" && -n "$int_source_line" && \
   -n "$term_ignore_line" && -n "$replay_line" ]] || {
  print -u2 'startup HELLO broker contract failed: signal lifecycle marker missing'
  exit 1
}
(( handler_install_line < broker_call_line && \
   broker_call_line < term_source_line && \
   term_source_line <= int_source_line && \
   int_source_line < term_ignore_line && \
   term_ignore_line < replay_line )) || {
  print -u2 'startup HELLO broker contract failed: signal ownership handoff changed'
  exit 1
}

# Only a promoted HELLO requests the pre-surface wake. The full display session
# uses the bounded begin-session operation so a later source sleep -> wake can
# issue one fresh activity event as well as hold the display assertion.
[[ "$(rg -c 'tb_power_lifecycle_request_panel_wake\(' "$receiver_source")" == "2" ]]
rg -q 'tb_power_lifecycle_begin_session\(&powerLifecycle\)' "$receiver_source"

broker_definition_line="$(rg -n '^static NSScreen \*wait_for_native_panel_after_sender_hello' "$receiver_source" | cut -d: -f1)"
renderer_check_line="$(rg -n '^        if \(!MTLCreateSystemDefaultDevice\(\)\)' "$receiver_source" | cut -d: -f1)"
full_listener_line="$(rg -n '^        int listener = make_listener' "$receiver_source" | tail -1 | cut -d: -f1)"

[[ -n "$broker_definition_line" && -n "$broker_call_line" && \
   -n "$renderer_check_line" && -n "$full_listener_line" ]] || {
  print -u2 'startup HELLO broker contract failed: lifecycle marker missing'
  exit 1
}
(( broker_definition_line < broker_call_line && \
   broker_call_line < renderer_check_line && \
   renderer_check_line < full_listener_line )) || {
  print -u2 'startup HELLO broker contract failed: listener-first ordering changed'
  exit 1
}

print 'startup HELLO broker contract passed (direct bridge, probe-inert, bounded wake)'
