# Phase two: lossless changed-tile transport

## Decision

Do not put this protocol change into the first stable personal appliance build.
The current path already carries exact 5120 × 2880, 8-bit 4:4:4 Display P3
frames and is usable. Changed tiles are a performance project, not a fidelity
repair. They should ship only after the full-frame path is the permanent
fallback and both ends pass interruption and resynchronization tests.

## Analogy

Remote framebuffers, compositors, and replicated databases share the same
shape: establish one complete state, then transmit small ordered changes. The
iMac's persistent decoded Metal texture can be the replicated framebuffer.
ScreenCaptureKit already attaches dirty rectangles to complete frames, so the
sender does not need a learned model to guess which pixels changed.

The analogy is backed by several independent systems rather than a guess:

- Apple explicitly describes using ScreenCaptureKit
  [`dirtyRects`](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/dirtyrects)
  to encode and transmit only changed regions, then composite them onto the
  receiver's previous frame in the
  [ScreenCaptureKit introduction](https://developer.apple.com/videos/play/wwdc2022/10155/?time=572).
- [RFB/VNC incremental updates](https://datatracker.ietf.org/doc/html/rfc6143#section-7.5.3)
  assume the client retains framebuffer state and provide a non-incremental
  refresh when that state is uncertain. That maps directly to FULL, PATCH, and
  RESYNC packets.
- Microsoft's [Desktop Duplication API](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/desktop-dup-api)
  supplies dirty and move metadata over a complete current GPU surface and
  permits conservative coalescing. Over-coverage is safe; under-coverage is a
  stale-pixel bug.
- [Wayland surface damage](https://wayland.freedesktop.org/docs/html/apa.html#protocol-spec-wl_surface-request-damage_buffer)
  is accumulated as double-buffered state and becomes visible atomically at
  commit. One logical patch frame should likewise present only after all of its
  rectangles complete.
- [VirtualGL's tile comparison](https://github.com/VirtualGL/virtualgl/blob/main/doc/advancedconfig.txt)
  documents the same tile-size CPU/bandwidth tradeoff and spoils queued frames
  to protect interaction latency.
- [Waypipe](https://gitlab.freedesktop.org/mstoeckl/waypipe/-/blob/master/README.md#latency)
  shows the boundary: changed-buffer transport helps static interfaces and
  text editors, while major animation changes can still create latency spikes.

TargetBridge draft [PR #158](https://github.com/swellweb/targetBridge/pull/158)
is especially relevant but remains unreviewed prior art on a 2020 iMac. Its
early one-bounding-box damage experiment averaged about 85% of the screen,
which is why a bounded set of disjoint regions—not one giant union box—is a
requirement here.

## Proposed wire contract

1. Every session begins with the existing full TBD2 frame (`0x25`). It becomes
   keyframe epoch `N` only after the receiver validates and presents it.
2. A new packet type carries a bounded header, epoch, monotonically increasing
   frame number, tile-aligned rectangles, per-rectangle lengths, and lossless
   TBD2 payloads for those rectangles.
3. Rectangles are clipped, overflow-checked, non-overlapping after coalescing,
   and aligned to the codec's 8 × 8 tiles. The receiver validates the complete
   packet before submitting any patch to Metal.
4. TCP preserves order. Any parse error, missing base epoch, geometry change,
   timeout, or reconnect discards the session texture and requires a new full
   keyframe. There is no attempt to guess missing pixels.
5. The receiver applies all patches for one frame in one command buffer and
   presents only after they complete. A partly applied logical frame is never
   displayed.
6. A periodic full keyframe and an immediate full keyframe after display-mode,
   color-space, or cursor-policy changes provide bounded recovery even before a
   reconnect.

## Sender policy

Start with a deterministic decision, measured against the current full-frame
baseline:

- merge nearby dirty rectangles while the resulting area remains cheaper;
- send patches below a declared dirty-area/encoded-size threshold;
- otherwise send one ordinary full TBD2 frame;
- keep the existing three-work-item ceiling and drop stale work under pressure;
- never read pixels back from the GPU and never write a frame to disk.

Apple also warns that retaining ScreenCaptureKit surfaces makes the capture
queue accumulate and increases latency. The sender must copy accepted regions
into one bounded app-owned latest-state texture, promptly release the capture
surface, and union damage across any frames deliberately skipped by pacing.

The test matrix must establish whether ScreenCaptureKit's dirty rectangles
include both the old and new standard-cursor footprints. If not, cursor movement
must use an explicit lossless overlay update or force a small union rectangle;
stale cursor pixels are a release blocker.

## Where a small classifier might help

Only after the deterministic version is correct, a small model could choose
between full frame, coalesced patches, and different tile groupings using
features that are already available: dirty-area ratio, rectangle count,
sampled spatial entropy, recent compression ratio, queue occupancy, and recent
send duration. It must not inspect semantic screen content, invent pixels, or
sit in the decoder.

The model ships only if it beats the deterministic threshold policy on a held-
out replay corpus and real hardware. Required wins are lower p99 capture-to-
present latency or fewer missed 16.7-ms deadlines without worse fidelity,
memory growth, thermal pressure, or resynchronization failures. Otherwise the
threshold policy remains simpler and preferable.

## Required tests

- exact CPU and GPU reconstruction for randomly generated rectangle sequences;
- malformed counts, offsets, lengths, overlap, integer overflow, and stale
  epoch rejection before Metal submission;
- forced disconnect at every byte boundary followed by a clean keyframe;
- dropped/repeated logical frame numbers and mode-change resynchronization;
- cursor movement over static text and high-contrast edges;
- full-screen video, scrolling text, static IDE, animation, and adversarial
  high-entropy content;
- bounded allocation, file-descriptor, queue-depth, and log-size assertions;
- measured full-frame fallback equivalence on the 2017 Radeon Pro 575;
- one-hour active run plus unplug/replug and sleep/wake acceptance.

Before shipping, the metadata oracle must show zero under-covered changed
pixels over at least 100,000 synthetic transitions and a one-hour real trace.
Sparse-workload A/B must reduce median wire bytes by at least 50%, preserve at
least 58.5 genuine presentations/s for ten minutes, keep presentation gaps at
p95 ≤20 ms and p99 ≤25 ms, and materially improve p99 latency or missed
16.7-ms deadlines across five paired runs. High-entropy fallback must remain
within 2% of full-frame TBD2 cadence/latency with no fidelity or recovery
regression. These are project acceptance thresholds, not industry standards.

This design can reduce bandwidth and improve cadence without compromising the
project's non-negotiable rule: every displayed pixel came from macOS, exactly.
