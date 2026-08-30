# Research note: what "5K60" means and how to close the cadence gap

Display restart/wake is a separate control-plane problem. Its implemented
design and physical acceptance are documented in
[`sleeping-panel-control-plane.md`](sleeping-panel-control-plane.md).

## Current evidence (2026-08-30)

The working appliance creates a 5120 × 2880 virtual display whose macOS mode
and the iMac panel both run at 60 Hz. The tested DPCM path captures an exact 2×
BGRA raster and sends lossless 8-bit TBD2 frames. The separate raw diagnostic is
NV12/4:2:0 and is not evidence for full-resolution RGB fidelity.

The first `MTLDrawable.presentedTime` A/B found a promising overlap result, but
its success counts are **superseded**. The tested implementation replaced a
zero presentation timestamp with callback time even though Apple defines zero
as not presented or dropped. These rows are preserved only as historical
directional evidence:

| Receiver mode | Reported FPS (superseded oracle) | Reported p95 | p99 | Maximum | Packet/parser/queue/GPU-command failures |
|---|---:|---:|---:|---:|---:|
| Serial | 58.718 | 19.6 ms | 34.9 ms | 122 ms | 0 |
| Two-slot overlap | **59.293** | **19.0 ms** | **34.0 ms** | **54.15 ms** | 0 |

Overlap adds one fixed 64 MiB receive slot. Version 0.5 records zero/invalid timestamps as presentation
drops, keeps the first-frame cover in place until a real presentation, and
defaults `CAMetalLayer` to display-synchronized presentation. Version 0.6 also
re-evaluates the final callback snapshot at the drain deadline and treats an
accounting invariant as a fatal renderer state. The corrected five-minute A/B
selected overlap at 59.972 presented FPS from a 59.983 Hz source, one drop,
16.8 ms p99, and zero integrity errors; see the
[corrected hardware record](../repro/imac-2017-5K/results/2026-08-30-v0.9-corrected-overlap-ab.md).
This repository uses:

- **5K60 mode** for 5120 × 2880 on a 60 Hz display mode; and
- **locked 5K60 cadence** only for at least 58.5 unique presented frames per
  second under a continuously changing workload.

No duplicated, interpolated, AI-generated, or upscaled frame counts toward
that cadence.

Presentation policy sources:

- [Apple: `MTLDrawable.presentedTime`](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime)
- [Apple: `CAMetalLayer.displaySyncEnabled`](https://developer.apple.com/documentation/quartzcore/cametallayer/displaysyncenabled)

The product-default acceptance run uses `displaySyncEnabled == YES`. The exact
`TB_DISPLAY_SYNC=0` override is reserved for controlled latency/tearing
diagnostics and must be reported explicitly; a result from that override cannot
stand in for synchronized physical acceptance.

## Analogy 1: overlap independent stages with a tiny fixed ring

The current receiver performs these stages serially:

```text
read packet n from Thunderbolt -> submit n on main/Metal -> read packet n+1
```

Process samples put the packet read near 14.7 ms and the main/Metal submission
near 6.5 ms. Serial work therefore predicts about 21.2 ms per update, or roughly
47 updates per second.

Apple's Metal guidance solves the analogous CPU/GPU stall with a small ring of
reusable buffers: processor A can prepare frame `n+1` while processor B consumes
frame `n`, with a semaphore bounding the work in flight. GNOME 48 used the same
concurrency idea in its display compositor; after five years of review and
testing, dynamic triple buffering reduced skipped frames and improved perceived
smoothness.

For this receiver, **two** receive slots are enough:

```text
slot A: main/Metal submits packet n
slot B: Thunderbolt fills packet n+1
```

The predicted critical path becomes `max(14.7, 6.5) = 14.7 ms`, within a
16.67-ms refresh interval. The first exact-hardware experiment improved the
reported FPS and bounded the worst observed gap without introducing a packet,
parser, queue, or GPU-command failure. Because its presentation oracle was
flawed, overlap remains enabled only as a resource-bounded candidate until the
corrected rerun. It:

- changes only the iMac receiver and does not disturb Screen Recording consent;
- preserves the exact existing packet and pixel path;
- adds one reusable buffer capped at 64 MiB;
- creates no disk cache and no growing queue; and
- can be disabled for a direct A/B comparison.

Sources:

- [Apple: Synchronizing CPU and GPU work](https://developer.apple.com/documentation/metal/synchronizing-cpu-and-gpu-work)
- [Apple: Metal triple-buffering best practice](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/TripleBuffering.html)
- [GNOME 48 performance notes](https://release.gnome.org/48/#performance-improvements)

The sanitized command recipe and complete A/B summary are in the
[2026-08-30 result](../repro/imac-2017-5K/results/2026-08-30-serial-overlap-ab.md).

## Analogy 2: transmit damage, not an unchanged framebuffer

Ordinary desktop motion usually changes only a fraction of 14.7 million pixels.
Several independent display systems exploit this fact:

- Apple says ScreenCaptureKit dirty rectangles can be encoded and transmitted
  instead of a whole frame, then copied over the receiver's previous frame.
- RFB/VNC defines display updates as rectangles that transition one valid
  framebuffer state to another, and requests a full refresh when the retained
  state is lost.
- Chromium tracks compositor damage so small updates avoid repainting and
  swapping an entire surface.
- Wayland makes damage part of an atomic surface commit.
- RDP uses retained client surfaces, blits, capability negotiation, frame
  boundaries, and acknowledgements.

This is unusually strong analogical evidence: Apple's capture API directly
exposes the metadata needed to transfer the mature remote-framebuffer idea into
this app.

Sources:

- [Apple WWDC22: ScreenCaptureKit dirty rectangles](https://developer.apple.com/videos/play/wwdc2022/10155/?time=572)
- [Apple: `SCStreamFrameInfo.dirtyRects`](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/dirtyrects)
- [RFC 6143: Remote Framebuffer Protocol](https://www.rfc-editor.org/rfc/rfc6143)
- [Chromium compositor damage tracking](https://chromium.googlesource.com/chromium/src.git/+/69.0.3466.3/cc/README.md#damage)
- [Wayland `wl_surface.damage_buffer`](https://wayland.freedesktop.org/docs/html/apa.html#protocol-spec-wl_surface-request-damage_buffer)
- [Microsoft RDP Graphics Pipeline overview](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/5229ee1e-1cb4-4178-9739-a36f1258b685)

The safe design remains deterministic and lossless:

1. Negotiate a new patch capability; preserve full TBD2 as the only fallback.
2. Start every session with a complete 5K keyframe and a new epoch.
3. Accumulate dirty regions across any capture frame dropped by backpressure.
4. Validate bounds, dimensions, sequence, epoch, and every blob before Metal.
5. Apply one logical update atomically to a persistent receiver texture.
6. Require a full keyframe after reconnect, wake, mode change, sequence gap,
   parse error, GPU error, or uncertain retained contents.
7. Send periodic keyframes as a bounded repair mechanism.

The first prototype should convert damage into a **bounded, sorted set of
disjoint 8×8-aligned rectangles**. It may merge nearby regions when the extra
encoded pixels are cheaper than another header, but it must not collapse all
damage into one unconditional union box: TargetBridge draft PR #158 measured
that shortcut at roughly 85% of the screen on its test workload. A hard
rectangle cap and an encoded-byte/area threshold select the ordinary full TBD2
frame whenever fragmentation would cost more. CopyRect is also deferred because
ScreenCaptureKit identifies changed destinations but does not provide a
dependable copy source.

## Why AI is not the first optimization

ScreenCaptureKit already supplies ground-truth change metadata. A learned model
cannot improve correctness and would add compute, privacy, reproducibility, and
failure modes. A deterministic policy can choose patch versus full frame using
dirty area, rectangle count, recent encoded size, and queue occupancy.

A small classifier is considered only if that policy is correct and a held-out
replay plus real hardware show a measurable p99 latency or missed-deadline win.
It may choose an encoding strategy; it may never synthesize pixels.

## Acceptance gates

For both the two-slot receiver and later dirty-region protocol:

- at least 58.5 unique receiver presentations per second for ten minutes under
  a controlled continuously changing 5K workload;
- present-gap p50 15.7–17.7 ms, p95 at most 20 ms, p99 at most 25 ms, and no
  more than 0.1% of gaps above 33.3 ms;
- zero malformed frames, queue-full events, GPU errors, silent drops, stale
  epochs, scaling, or RGB mismatches;
- fixed allocations after warmup, stable FDs and threads, no hot-path disk
  writes, and no thermal-pressure warning;
- receiver RSS no more than 80 MiB above the one-slot baseline and post-warmup
  growth no more than 2 MiB/hour;
- automatic recovery across restart, reconnect, display sleep/wake, and
  shutdown while either receive slot is occupied.

Full-screen high-entropy 5K motion is reported separately. Dirty rectangles may
cover the entire screen there, so a locked lossless 60-fps claim requires the
full-frame path itself to pass the same presentation gate.
