# Component tests — 2026-08-29

> These tests were run from an uncommitted working tree during integration.
> They must be repeated from the final immutable commit before publication.

## Sender

- Configuration: Debug tests on Apple Silicon macOS
- Result: **125 tests, 0 failures**
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
| `test_native_metal_renderer` | Apple GPU shader/pipeline and DPCM fixture passed |

The native Metal fixture exercised real GPU pipeline compilation, NV12
presentation setup, Display P3 labeling, malformed TBD2 rejection, and 192
repeated TBD2 submissions. The repeated submissions completed with exactly
three upload-buffer allocations, one decoded-buffer allocation, and one cached
texture-view creation. The lifecycle fixture also injects command-buffer,
encoder, buffer, and bounded-drain failures.

## Not proved by this file

- Radeon Pro 575 GPU compatibility or performance;
- sustained 5K60 DPCM over the cable;
- end-to-end latency;
- exact source-to-drawable geometry on the receiver;
- memory, thermal, battery, or storage behavior during a long session;
- plug/unplug or sleep/wake recovery.

Those results belong in a separate hardware result produced from the final
committed source.
