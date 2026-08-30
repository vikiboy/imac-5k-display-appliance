# Component tests — 2026-08-29

> The complete receiver suite was repeated from immutable source commit
> `fa8b8ce6272dcd851d4d7ac152d910eb323e3551`. The sender is unchanged from its
> final identity build and its suite was repeated before that build was
> installed.

## Sender

- Configuration: Debug tests on Apple Silicon macOS
- Result: **133 tests, 0 failures, 0 skips**
- Covered suites include connection diagnostics, display profiles, injected
  click state, input bindings, menu metrics, monitor protocol, receiver
  discovery, and automation parsing.

## Receiver and shared codec

| Executable | Result |
|---|---:|
| `test_net_parser` | 73 checks passed |
| `test_dpcm` | 290 checks passed |
| `test_dpcm_gpu_lifecycle` | 43 injected lifecycle checks passed |
| `test_input_queue` | 562 checks, 0 failures |
| `test_receiver_profile` | 13 checks passed |
| `test_renderer_policy` | 22 checks passed |
| `test_raw_nv12` | 99 checks, 0 failures |
| `test_pre_session` | 16 checks, 0 failures |
| `test_shutdown_gate` | Idle listener, active peer, descriptor reuse, and post-shutdown admission fixture passed |
| Receiver installer order | Disabled launchd override is cleared before bootstrap |
| `test_native_metal_renderer` | Apple GPU shader/pipeline and DPCM fixture passed |
| `test_appkit_launch_lifecycle` | One launch completion; key-capable borderless appliance window |
| AppKit source contract | `NSApp run` is the sole launch owner; reconnect cannot call `makeKeyAndOrderFront:` |

The native Metal fixture exercised real GPU pipeline compilation, NV12
presentation setup, Display P3 labeling, malformed TBD2 rejection, and 192
repeated TBD2 submissions. The repeated submissions completed with exactly
three upload-buffer allocations, one decoded-buffer allocation, and one cached
texture-view creation. The receiver transition fixture additionally verified
the hidden-idle → covered-drawable → GPU completion → presented-epoch sequence
used to prevent stale desktop frames from flashing during reconnect. The
lifecycle fixture also injects command-buffer, encoder, buffer, and
bounded-drain failures.

The final receiver was then installed on the 2017 iMac. A one-minute idle
baseline sampled seven times and recorded 0.0% receiver CPU, exactly 16,336 KiB
RSS at every sample, 11 open file descriptors at every sample, and zero
application-support/log growth. The raw privacy-scrubbed sample is
[`2026-08-29-idle-resource-baseline.tsv`](2026-08-29-idle-resource-baseline.tsv).
This is an idle sanity check, not a substitute for the pending animated
one-hour soak.

## Not proved by this file

- Radeon Pro 575 GPU compatibility or performance;
- sustained 5K DPCM at a requested 60 FPS target over the cable, including
  corrected physical-presentation telemetry;
- end-to-end latency;
- exact source-to-drawable geometry on the receiver;
- memory, thermal, battery, or storage behavior during a long session;
- plug/unplug or sleep/wake recovery.

Those results belong in a separate hardware result produced from the final
committed source.
