#!/bin/zsh
set -euo pipefail

receiver_source="${1:-benchmarks/benchmark_targetbridge_raw_receiver.m}"
sender_source="${2:-../../TargetBridge-Sender/TBDisplaySender/TBDisplaySenderService.swift}"
protocol_source="${3:-../../TargetBridge-Sender/TBDisplayShared/TBMonitorProtocol.swift}"

for source in "$receiver_source" "$sender_source" "$protocol_source"; do
  [[ -f "$source" ]] || {
    print -u2 -- "display lifecycle contract failed: missing $source"
    exit 1
  }
done

# Only public workspace power/session notifications drive authorization.
rg -q 'NSWorkspace\.willSleepNotification' "$sender_source"
rg -q 'NSWorkspace\.screensDidSleepNotification' "$sender_source"
rg -q 'NSWorkspace\.didWakeNotification' "$sender_source"
rg -q 'NSWorkspace\.screensDidWakeNotification' "$sender_source"
! rg -q 'com\.apple\.(screenIsUnlocked|screensaver)' "$sender_source" "$receiver_source"
rg -q 'NSWorkspaceSessionDidBecomeActiveNotification' "$receiver_source"
rg -q 'NSWorkspaceSessionDidResignActiveNotification' "$receiver_source"
rg -q 'CGSessionCopyCurrentDictionary' "$receiver_source"
rg -q 'tb_current_console_session_lock_state' "$receiver_source"

# The optional packets/capability preserve old-peer framing behavior.
rg -q 'receiverSurfaceState = 0x39' "$protocol_source"
rg -q 'sourceDisplayState = 0x3A' "$protocol_source"
rg -q 'supportsDisplayLifecycle: Bool\?' "$protocol_source"
rg -q 'receiverEpoch: UInt64\?' "$protocol_source"
rg -q 'supportsDisplayLifecycle\\\":true' "$receiver_source"

# Frame work is gated only after a whole packet is read, before parse/Metal.
gate_line="$(rg -n 'if \(!framesAllowed\)' "$receiver_source" | head -1 | cut -d: -f1)"
parse_line="$(rg -n 'tb_raw_nv12_parse\(' "$receiver_source" | tail -1 | cut -d: -f1)"
[[ -n "$gate_line" && -n "$parse_line" ]] && (( gate_line < parse_line ))
rg -q 'markFreshFramePresentedForGeneration' "$receiver_source"
rg -q 'admitLegacyFrameForGeneration' "$receiver_source"
rg -q 'tb_power_lifecycle_end_session\(&powerLifecycle\)' "$receiver_source"

# A peer that emits the lifecycle packet has opted into the strict control
# plane. Malformed state must close that session instead of falling through to
# the source_epoch==0 legacy-frame admission path.
rg -q 'sessionEndReason = "malformed-source-display-state"' "$receiver_source"
rg -q 'sessionRejected = true;' "$receiver_source"

# A fresh lifecycle generation gets its own renderer presentation epoch. The
# opaque cover may be removed only after that exact epoch presents; a change in
# the process-global presentation count is not sufficient evidence.
rg -q 'acceptedFrameGeneration != rendererPresentationGeneration' "$receiver_source"
rg -q 'pendingFreshRendererEpoch = nextRendererEpoch' "$receiver_source"
rg -q 'liveStats\.last_presented_epoch >=' "$receiver_source"
! rg -q 'presented_frames > pendingFreshPresentedBaseline' "$receiver_source"
rg -q 'tb_native_metal_get_runtime_stats' "$receiver_source"

print -- "display lifecycle source contract passed"
