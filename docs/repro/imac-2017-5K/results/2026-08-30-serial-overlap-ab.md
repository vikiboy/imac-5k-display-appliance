# 2017 iMac serial/two-slot cadence A/B — 2026-08-30

> **Superseded cadence oracle:** this A/B was useful for selecting bounded
> receive overlap, but its presented-frame counts are not release evidence.
> The tested build substituted callback time when
> `MTLDrawable.presentedTime` was zero; Apple defines zero as not presented or
> dropped. Version 0.5 counts that outcome as a presentation drop and sets
> `displaySyncEnabled` to `YES` by default. Only the exact diagnostic override
> `TB_DISPLAY_SYNC=0` disables synchronization. The rows below are retained as
> historical evidence and must be repeated with the corrected, synchronized
> binary.

This is a sanitized engineering record for the exact 2017 27-inch Retina 5K
iMac (`iMac18,3`, Radeon Pro 575). The virtual display was
**2560 × 1440 HiDPI points backed by 5120 × 2880 pixels at 60 Hz**. A separate
direct Thunderbolt Bridge TCP test measured **17.06 Gbit/s**.

The fidelity run used the 8-bit BGRA-to-TBD2/DPCM path. The raw diagnostic is a
different NV12/4:2:0 path and was not used to make a full-resolution RGB claim.

## Result

The same changing 5K source was used for both receiver configurations. These
superseded cadence figures were derived from receiver presentation callbacks,
not packet arrival or sender capture counts, but a callback with a zero hardware
timestamp was incorrectly counted as presented.

| Receiver mode | Reported FPS (superseded oracle) | Reported gap p95 | p99 | Maximum | Malformed | Queue drops | Renderer failures | GPU-command errors | Admission drops |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Serial, one receive slot | 58.718 | 19.6 ms | 34.9 ms | 122 ms | 0 | 0 | 0 | 0 | 0 |
| Bounded overlap, two receive slots | **59.293** | **19.0 ms** | **34.0 ms** | **54.15 ms** | 0 | 0 | 0 | 0 | 0 |

The overlap mode is the **provisional candidate** for this hardware. It adds one
reusable receive buffer capped at 64 MiB; it does not add an unbounded queue or
write frames to disk. The reported FPS and maximum-gap direction did not cost an
observed malformed frame, queue/admission drop, renderer failure, or GPU-command
error.

This is not a perfect-60 or production claim. The reported presentation-success
and gap columns are untrustworthy; the packet/parser/queue/GPU-command integrity
counters remain useful. The overlap's reported p99 of 34.0 ms would also miss
the project's 25 ms locked-60 research gate. The record does not
measure end-to-end input latency, prove cursor behavior, clear reconnect and
sleep/wake gates, or clear the one-hour resource gate. The earlier resource run
remains a [qualified failure](2026-08-29-active-resource-soak.md) because receiver
RSS increased +6.251 MiB/hour despite zero heap leaks, storage growth, or
thermal warnings.

The sanitized summary does not bind both configurations to a published binary
hash and immutable commit. Re-run the commands below and record those identities
before using this result as release evidence.

The iMac also had `/Applications/Luna Secondary.app` installed, but verification
found no Luna/Astropad process, user or system launch item, system extension, or
loaded kernel extension; the MacBook had no Luna/Astropad app, process, or system
extension. The app was left installed. Current evidence treats it as inert and
not part of this runtime; uninstalling it is not a prerequisite.

## Reproduce

Build the receiver/link diagnostics and the changing Retina source from the
repository root:

```sh
(
  cd TargetBridge-Receiver/TBReceiverC
  make benchmark-network-metal-universal
)

xcrun clang -fobjc-arc -Wall -Wextra -Werror \
  -framework AppKit -framework CoreGraphics -framework QuartzCore \
  TargetBridge-Sender/Diagnostics/probe_virtual_display_animation.m \
  -o TargetBridge-Sender/.build/Diagnostics/probe_virtual_display_animation

scp TargetBridge-Receiver/TBReceiverC/benchmark_tb_link_universal \
  '<imac-ssh>:/tmp/'
```

For the direct-link test, run the receiver in one iMac terminal and the sender
in one MacBook terminal. Replace only the bracketed link-local addresses; keep
them out of published results:

```sh
# iMac
/tmp/benchmark_tb_link_universal receive '<imac-tb-ip>' 54322 8589934592

# MacBook
./TargetBridge-Receiver/TBReceiverC/benchmark_tb_link_universal \
  send '<imac-tb-ip>' 54322 8589934592
```

Install the same reviewed receiver app first with serial receive, then with
overlap. These commands stream the checked-in installer to the iMac, preserve
the installed app path, and therefore do not disturb the sender's stable Screen
Recording identity:

```sh
ssh '<imac-ssh>' \
  'TB_INSTALL_RECEIVE_OVERLAP=0 /bin/zsh -s -- "$HOME/Applications/TargetBridge 5K Receiver.app"' \
  < TargetBridge-Receiver/scripts/install_targetbridge_5k_receiver_launch_agent.sh

# Run the controlled motion session, end it, and save the sanitized summary.
TargetBridge-Sender/.build/Diagnostics/probe_virtual_display_animation 600

ssh '<imac-ssh>' \
  'TB_INSTALL_RECEIVE_OVERLAP=1 /bin/zsh -s -- "$HOME/Applications/TargetBridge 5K Receiver.app"' \
  < TargetBridge-Receiver/scripts/install_targetbridge_5k_receiver_launch_agent.sh

# Repeat the identical motion session.
TargetBridge-Sender/.build/Diagnostics/probe_virtual_display_animation 600
```

After each session, extract only the receiver's summary fields from the iMac's
unified log. Inspect the raw output locally, then publish a scrubbed row rather
than hostnames, addresses, paths, or surrounding screen contents:

```sh
log show --last 20m --style compact \
  --predicate 'subsystem == "com.targetbridge.receiver5k"' | \
  grep 'session=ended' | \
  grep -E 'presentedFPS|presentGapP95MS|presentGapP99MS|presentGapMaxMS|receiveOverlap|malformed|queueDrops|gpuDrops|rendererFailures'
```

Record `git rev-parse HEAD`, `git status --short`, and SHA-256 hashes of both
installed executables alongside the private raw run. Use the project-owned
[motion-source screenshot](../../../blog/assets/native-retina-motion-source.png)
only to identify the source raster. It is a MacBook capture, not an iMac output
screenshot; macOS remote capture omits the receiver's shielding/Metal surface.
