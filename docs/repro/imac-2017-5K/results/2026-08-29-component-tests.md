# Component tests — 2026-08-29

> These tests were repeated from immutable source commit
> `fe6e3484bec86cdc98355d25ddae2b48ab5ae1a4`. A later identity-only release
> commit must repeat packaging and the affected UI/build checks before it can be
> distributed.

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

The native Metal fixture exercised real GPU pipeline compilation, NV12
presentation setup, Display P3 labeling, malformed TBD2 rejection, and 192
repeated TBD2 submissions. The repeated submissions completed with exactly
three upload-buffer allocations, one decoded-buffer allocation, and one cached
texture-view creation. The receiver transition fixture additionally verified
the hidden-idle → covered-drawable → GPU completion → presented-epoch sequence
used to prevent stale desktop frames from flashing during reconnect. The
lifecycle fixture also injects command-buffer, encoder, buffer, and
bounded-drain failures.

## Not proved by this file

- Radeon Pro 575 GPU compatibility or performance;
- sustained 5K60 DPCM over the cable;
- end-to-end latency;
- exact source-to-drawable geometry on the receiver;
- memory, thermal, battery, or storage behavior during a long session;
- plug/unplug or sleep/wake recovery.

Those results belong in a separate hardware result produced from the final
committed source.
