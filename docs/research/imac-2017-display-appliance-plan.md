# A software display appliance for the 2017 5K iMac

Research and build plan, 2026-08-29

## Verdict

An intact 2017 27-inch 5K iMac cannot be turned into a literal DisplayPort or
Thunderbolt display sink by a driver. Its Thunderbolt controller is wired as a
computer host and Apple documents its display path as output-only. The panel has
no routed external video-input path for software to enable.

It can, however, be turned into a native-feeling display appliance entirely in
user space:

1. The MacBook creates a real 5K HiDPI virtual display.
2. The virtual framebuffer is captured without a CPU pixel copy.
3. Pixels cross a direct Thunderbolt Bridge link as data.
4. The iMac updates a persistent 5K Metal surface and presents it on its panel.

The important design change is to stop treating this as video streaming. The
right abstraction is a deadline-driven, replicated framebuffer using the same
ideas as DisplayLink, RDP/RFB, Display Stream Compression, JPEG XS, and Looking
Glass.

Literal zero latency is impossible because there are two compositors and a 60 Hz
panel scanout. The falsifiable target is a pipeline that normally stays within
one 16.67 ms refresh, never accumulates a queue, preserves 4:4:4 text fidelity,
and renders the cursor independently so pointing feels sub-frame.

## The exact 2017 boundary

The target is `iMac18,3`, not a 2020 iMac.

| Property | 2017 iMac | Consequence |
|---|---|---|
| Panel | 5120 x 2880, 60 Hz, P3, one billion colors | The desired output exists and macOS can drive it natively. |
| GPU | Radeon Pro 570/575/580, Polaris/GDDR5 | Metal compute is available, but custom shaders must be benchmarked on the exact model. |
| Fixed video engine | Polaris-era UVD plus Kaby Lake media | 5K60 HEVC is not a reliable design assumption. |
| Ports | Thunderbolt 3, up to 40 Gbit/s, DisplayPort output | The cable can carry data between Macs, but the iMac is not a DP sink. |
| Official OS ceiling | macOS Ventura | Receiver code must keep a Ventura-compatible API floor. |

Apple Target Display Mode supports only selected 2009 through mid-2014 iMacs.
Apple's Thunderbolt architecture also distinguishes a computer host controller,
which receives DisplayPort from its own GPU for outbound tunneling, from a
display endpoint controller that emits DisplayPort toward a panel. A kext, EDID
spoof, Alpine Ridge firmware experiment, or different cable cannot create the
missing controller role and board route.

Apple's newer Thunderbolt RDMA is not an escape hatch: it requires Apple silicon,
Thunderbolt 5, and a current macOS release. The 2017 Intel/TB3 iMac is excluded.

## Data-rate and latency budget

At 5120 x 2880 x 60:

| Pixel representation | Payload rate | Result on the measured link |
|---|---:|---|
| 32-bit BGRA or packed 10-bit RGB | 28.31 Gbit/s | Does not fit. |
| 8-bit NV12 4:2:0 | 10.62 Gbit/s | Fits, but loses fine chroma/text fidelity. |
| RGB at a fixed 3:1 display-link ratio | 9.44 Gbit/s | Fits with useful headroom. |

A TargetBridge experiment measured roughly 17 Gbit/s of application throughput
over Thunderbolt Bridge to a 2017 iMac. The nominal 40 Gbit/s port number is not
the payload available to an IP application.

A plausible one-refresh budget is:

| Stage | Target |
|---|---:|
| Capture and classify | 1-3 ms |
| GPU encode | 2-4 ms |
| Wire, overlapped in bands | 3-6 ms |
| 2017 Radeon GPU decode/update | 2-4 ms |
| Present scheduling | deadline-dependent |

Those stages must overlap. A sequential whole-frame pipeline cannot reliably
stay inside 16.67 ms.

## What has already been done

### Apple and commercial approaches

- Target Display Mode never supported this 5K generation.
- Luna Display, AirPlay, and ordinary screen sharing prove that the iMac can be a
  software receiver, but conventional capture/codec/buffering paths add latency.
- No conventional cable or macOS display driver can expose the internal panel as
  a physical sink.

### OpenDisplay

- Open PR #145 creates a genuine Mac-to-Mac extended display receiver.
- A wired M5-to-iMac field test reached 3360 x 1890 at about 30 fps and 18-20 ms,
  but not 5K60 and not on a 2017 iMac.
- Its macOS receiver still uses `AVSampleBufferDisplayLayer`.
- Open PR #249 adds HEVC negotiation, but HEVC does not remove the 2017 decoder
  ceiling.
- Its best transferable idea is an out-of-band cursor position channel so cursor
  traffic cannot wait behind large video packets.
- OpenDisplay is GPLv3 while TargetBridge is MIT. We can reimplement mechanisms,
  but should not copy OpenDisplay source into a permissively licensed branch.

### Moonlight and Sunshine

- On an exact 2017 `iMac18,3` with Radeon Pro 580, 5120 x 2880 HEVC at 30 fps
  works with hardware decoding.
- A 5K60 attempt reports VideoToolbox decode-queue overflow.
- Forcing Moonlight's direct Metal renderer makes the same 5K30 stream feel much
  more responsive than `AVSampleBufferDisplayLayer`.
- This independently identifies presentation copies/buffering as one bottleneck
  and fixed-function decode throughput as another.

### TargetBridge stable path

- It already creates a real virtual extended display and sends it over
  Thunderbolt Bridge.
- Current profiles recommend HEVC 5K48; 5K60 is experimental.
- Encoding is configured for real time, no frame reordering, and zero permitted
  encoder frame delay.
- The shipping receiver nevertheless uploads every decoded 5K NV12 frame through
  `SDL_UpdateNVTexture` and presents with SDL/OpenGL. That is not end-to-end zero
  copy.

### TargetBridge experimental paths

- PR #142 bypasses HEVC and sends raw NV12. Its author reports an M5 to 2017 iMac
  at 5K60 over a roughly 17 Gbit/s link. The result is encouraging but subjective,
  unreviewed, 4:2:0, and the PR was closed pending a rebased measured version.
- PR #174 maps VideoToolbox `CVPixelBuffer` planes directly to Metal textures and
  draws the local cursor in the same pass. It reports 600/600 frames and zero
  renderer drops on a 2017 Intel Retina iMac. This validates the receiver render
  mechanism, not a complete 5K60 HEVC pipeline.
- PR #158 demonstrates a much more interesting path on a 2020 iMac: lossless
  4:4:4 10-bit 5K60, about 13-14 ms pipeline latency, and a custom GPU tile-DPCM
  codec called TBD2. It is an 85-commit integration branch, not a reviewable or
  production-safe change.

## What is working

Evidence strength is deliberately separated.

| Capability | Status | Evidence |
|---|---|---|
| True extended virtual display | Working | TargetBridge and OpenDisplay use `CGVirtualDisplay`. |
| Direct Mac-to-Mac Thunderbolt data path | Working | Thunderbolt Bridge/IP is supported; TargetBridge uses it. |
| Responsive direct Metal rendering on the 2017 | Working | Independent Moonlight result plus TargetBridge PR #174's 2017 test. |
| 5K30 HEVC on Radeon Pro 580 | Working | Exact 2017 Moonlight field result. |
| Raw NV12 5K60 on this 2017 | Working diagnostic; physical-panel output confirmed | 3,600 real captured frames at 59.824 fps and 10.589 Gbit/s with zero receiver/GPU drops; the user then confirmed the corrected pattern on the iMac panel. |
| Lossless 4:4:4 10-bit 5K60 at about one frame | Demonstrated on 2020 only | TargetBridge TBD2 PR #158. |
| TBD2 on Radeon Pro 570/575/580 | Unknown | Must benchmark this exact receiver. |

## What is not working yet

- A literal DisplayPort-input or Target Display Mode path.
- Independently measured capture-to-photon latency on a 2017 iMac.
- Independently measured capture-to-photon latency on the physical panel. The
  corrected diagnostic is visibly working, but a camera/photodiode-style latency
  measurement has not yet been made.
- Stable 5K60 through the 2017 fixed-function HEVC decoder.
- Full-color raw 5K60 within the real Thunderbolt-IP bandwidth.
- A final banded raw path. The new diagnostic now replaces SDL with one bounded
  CPU-plane-to-IOSurface copy and native Metal, but the wire still delivers an
  entire 22 MB frame before presentation can begin.
- A reviewed, sanitizer-clean TBD2 implementation.
- A correct per-frame asynchronous band state machine.
- Reliable multi-region dirty/move updates with recovery after drops.
- Content protection/HDCP. Screen-captured protected video may remain black.

## Why earlier approaches get stuck

1. They model the pixels as a movie and reach first for H.264/HEVC. The 2017's
   fixed video engine is the wrong accelerator for 5K60.
2. Removing the codec entirely creates a 28.3 Gbit/s full-RGB stream, which does
   not fit through the observed host-to-host IP path.
3. NV12 fits by discarding chroma resolution, so a bandwidth success can still
   fail the monitor-quality goal on one-pixel colored text.
4. Generic presentation APIs hide buffering or perform a full-frame CPU upload.
5. Throughput-oriented queues make benchmark FPS look better while old frames
   accumulate and interaction latency ratchets upward.
6. A single dirty bounding box is almost useless: WindowServer changes are
   spatially scattered, and PR #158 measured a one-box result averaging 85% of
   the screen.
7. The most ambitious prototype arrived as one huge integration branch, making
   correctness bugs difficult to isolate and review.

The code audit found two concrete examples of the last problem:

- TBD2's C reference zigzag encoder left-shifts a negative signed integer. That
  is undefined C behavior and UBSan catches it immediately.
- The band presenter uses one global `bands_inflight`, `present_armed`, and
  `present_idx` across overlapping frames even though the wire has a frame ID.
  A later frame can overwrite presentation state for an earlier incomplete one.

Both must be fixed before the 2020 result is treated as a foundation.

## Recursive analogies and their transplants

### 1. VideoToolbox is too slow at 5K60

**Analogue:** legacy accelerator bypass and GPU compute.

Use the general Radeon compute units for a simple intraframe display codec rather
than forcing a 4K-generation fixed video block to decode HEVC above its comfortable
rate. TBD2 is the first proof of this transplant.

### 2. Lossless RGB does not have a safe worst-case rate

**Analogue:** VESA DSC and JPEG XS.

Both were created to move display-quality 4:4:4 pixels over constrained links
with a few lines or a fraction of a frame of latency. A bounded-rate, GPU-parallel
4:4:4 mode is the correct high-entropy fallback. At 3:1 it needs roughly
9.44 Gbit/s.

### 3. Full frames waste bandwidth on desktop work

**Analogue:** DisplayLink, RDP, and RFB/VNC.

Keep an authoritative 5K texture in iMac VRAM. Transmit operations such as
`COPY_RECT`, `SOLID_FILL`, and absolute lossless tile writes. Apple exposes
refreshed, moved, dirty, and reduced-dirty rectangles through `CGDisplayStream`.

### 4. WindowServer dirty metadata is scattered or incomplete

**Analogue:** rsync block matching and GPU change detection.

Use capture metadata as a cheap hint, then validate/coalesce it with GPU tile
hashes. Multiple regions are the feature; collapsing them to one rectangle is
not a viable optimization.

### 5. Delta updates cannot be dropped like video frames

**Analogue:** database replication and write-ahead logs.

Treat the receiver framebuffer as a replicated state machine:

- full checkpoint with an epoch;
- absolute, idempotent tile writes;
- copy operations only against an acknowledged base epoch;
- coalesce all unsent damage into final values;
- periodic hashes and checkpoint recovery.

This preserves freshness without corrupting state.

### 6. Queues improve throughput but create lag

**Analogue:** real-time robotics/DDS lifespan, Moonlight's latest-frame renderer,
and leaky media queues.

Every unit has a deadline. Complete frames are latest-value mailboxes, not FIFOs.
Resource triple buffering supplies reusable surfaces, not three frames of
historical work. Receiver credits report applied epoch, queued bytes, GPU time,
and time to the next presentation deadline.

### 7. Cursor perception is dominated by the video cadence

**Analogue:** hardware cursor planes and VR late latching.

Exclude the cursor from full-frame pixels. Send cursor position on a tiny
priority channel with a sequence number, and draw it in the iMac's last Metal
pass. Cursor shape changes remain reliable; position updates may supersede one
another.

### 8. Looking Glass is nearly zero-copy

**Analogue:** shared-memory VM display relay.

Its exact IVSHMEM/DMA-BUF mechanism cannot cross two independent Mac hosts, but
its ownership model transfers: preallocated surfaces, GPU resource leases until
command-buffer completion, separate frame/cursor generations, and no redundant
CPU pixel copies.

## What to build

### Architecture

```text
MacBook / sender                            2017 iMac / display appliance

CGVirtualDisplay 5K HiDPI
        |
direct IOSurface capture + update metadata
        |
GPU classify/hash/encode
        |        control/cursor priority channel
        +====== Thunderbolt Bridge =======+
                                             epoch-aware band/tile parser
                                                       |
                                             Radeon Metal update/decode
                                                       |
                                             persistent 5K P3 texture
                                                       |
                                             local cursor + CAMetalLayer
                                                       |
                                                built-in 5K panel
```

The wire is a small transaction protocol, not a video-only packet stream:

- `CHECKPOINT(frame_id, epoch, bands...)`
- `COPY_RECT(base_epoch, source, destination)`
- `SOLID_FILL(epoch, rect, color)`
- `LOSSLESS_TILES(epoch, rects, TBD2 payloads)`
- `BOUNDED_444_BANDS(frame_id, payloads)`
- `CURSOR_POSITION(sequence, x, y)`
- `CURSOR_SHAPE(sequence, image, hotspot)`
- `ACK(applied_epoch, queued_bytes, gpu_ms, deadline_slack)`
- `HASH(epoch, tile_hashes)` / `REQUEST_CHECKPOINT`

### Mode selection

| Content | Preferred operation |
|---|---|
| No visual change | Nothing; cursor remains independent. |
| Moved window/scroll region | `COPY_RECT` plus exposed lossless tiles. |
| Sparse text/UI edits | Multiple lossless 4:4:4 TBD2 tile regions. |
| Fast scrolling/large UI change | Full-frame or banded TBD2. |
| High-entropy photo/video | Bounded-rate 4:4:4 display codec. |
| Diagnostic/fallback | Raw NV12 or HEVC, explicitly labeled 4:2:0. |

## Implementation sequence and go/no-go gates

### Phase 0: measurement contract

Add frame IDs and timestamps at capture, encode completion, first/last byte sent,
first/last byte received, GPU submit/complete, presentation request, and
presentation completion. Synchronize clocks over the control channel. Add an
external high-speed-camera or photodiode test because internal timestamps omit
panel scanout.

**Gate:** a 25-50 ms injected stall must clear within two refreshes instead of
replaying a historical FIFO.

### Phase 1: native Metal receiver

Port TargetBridge PR #174 onto the maintained 3.5 branch, opt-in with automatic
fallback to OpenGL.

**Gate on the 2017:** 5120 x 2880 x 60 synthetic surfaces for ten minutes, zero
growing queue, zero renderer drops, and p99 GPU work below 3 ms.

**Current hardware status:** the first slice is running on the target. The two
PR #174 commits are on branch `imac2017-display-appliance`; all receiver checks
pass and the Metal shader/pipeline test passes on the M5 Max. A checksum-verified
standalone probe was copied (not installed) to the iMac. Nothing was installed
or enabled on the MacBook.

A universal arm64/x86_64 benchmark target is also built. As a sender-side
baseline, the M5 Max rendered 600 synthetic 5120 x 2880 NV12 frames at 60 fps
with 600 completions and zero drops. The receiver now records separate submit,
`nextDrawable`, and GPU-completion histograms plus in-flight depth, so the iMac
run reports p50/p95/p99/max rather than hiding stalls in an average.

On the exact target -- `iMac18,3`, Core i5-7600, Radeon Pro 575 4 GB, macOS
13.7.8 -- the ten-second 5K60 IOSurface smoke test submitted and completed all
600 frames with zero drops and a maximum in-flight depth of two. Metal submit
p99 was 0.2 ms, drawable-wait p99 0.1 ms, and GPU p99 1.8 ms. The subsequent
ten-minute soak completed all 36,000 frames in 600.003 seconds with zero drops;
GPU p99 remained 1.8 ms. The benchmark attached to the internal 5120 x 2880
Display P3 drawable, clearing the synthetic renderer gate on the exact hardware.

### Phase 2: raw diagnostic without SDL

Rebase raw NV12 as a bounded diagnostic path. Receive into reusable IOSurface or
Metal-compatible buffers and render with Metal instead of uploading through SDL.
Keep its existing whole-frame wire format for this decisive A/B test; banding
requires frame IDs and completeness barriers and belongs in the later protocol.

**Gate:** if 5K60 raw is stable on the 2017, the fixed HEVC decoder is confirmed
as the dominant remaining codec bottleneck. This is a diagnostic, not the final
quality mode.

**Current local status:** the bounded diagnostic is implemented. RAW packets are
validated by a new pure-C parser; the sender requires exact video-range NV12 and
enforces the 64 MiB protocol cap. Instrumentation showed that one outstanding
22 MB Network.framework send discarded every alternate captured frame. A
hard-bounded two-send overlap fixed that cadence without creating a historical
FIFO; RAW mode remains explicit and diagnostic-only. The receiver copies visible
rows into a four-surface IOSurface pool and uses the same Metal presenter as
VideoToolbox.

This slice is commit `4ef54ee` on `imac2017-display-appliance`; cadence
instrumentation is `c24be82` and the universal-probe build target is `82561b4`.

The test matrix now passes 111 sender tests, 763 receiver checks, a native-Metal
RAW lifetime/pool-pressure exercise, and ASan/UBSan on all 99 RAW parser checks.
On the M5 Max baseline, 600 raw-copy 5K frames at 60 Hz completed with zero drops:
RAW staging p99 1.0 ms, Metal submit p99 0.2 ms, and GPU p99 1.2 ms. The x86_64
slice also runs under Rosetta.

On the Radeon Pro 575 target, the corresponding ten-second raw-copy test also
completed 600/600 frames with zero drops: RAW staging p99 3.3 ms, Metal submit
p99 0.2 ms, drawable-wait p99 0.1 ms, and GPU p99 1.5 ms. This proves that the
2017 iMac can stage and present a complete synthetic 5K60 NV12 stream without
using its video decoder.

The real ScreenCaptureKit path now also clears its software gate. A MacBook-created
5K HiDPI extended desktop was captured and sent with TargetBridge's actual packet
framing across the direct Thunderbolt link. The strongest 3,600-frame run reached
59.824 fps and 10.589 Gbit/s with zero malformed frames, renderer drops, or Metal
command errors; RAW-copy p99 was 3.7 ms and GPU p99 4.7 ms. A 640 x 360 luma
thumbnail sampled inside the iMac receiver visibly contains the MacBook virtual
desktop, proving that recognizable source pixels reached the target rather than
an all-black frame.

After restoring a verified 40 Gbit/s Thunderbolt connection, a second live native
run received and presented all 1,200 real 5120 x 2880 frames at 59.591 fps and
10.553 Gbit/s. It recorded zero malformed frames, receiver drops, or GPU errors;
frame-read p99 was 13.073 ms, RAW-copy p99 3.9 ms, and GPU p99 1.6 ms. The moving
test card ran only on the virtual display, and the iMac receiver used a 5120 x
2880 drawable. This is the strongest bounded end-to-end result on the exact 2017
iMac and current cable.

Physical visibility is now closed. An early animated pattern window accidentally
joined every source-side Space, so it appeared on the MacBook and Dell rather
than proving the iMac path. That behavior was removed, and the pattern helper now
refuses to run unless it finds the TargetBridge virtual display vendor ID. The
iMac diagnostic is a real `.app` launched in the logged-in Aqua session,
completes AppKit launch, joins the iMac's Spaces, pumps pending window events, and
shows a waiting surface before attaching Metal. The user then confirmed seeing
the corrected animated `TARGETBRIDGE LIVE 5K` pattern on the physical iMac panel.

A second bounded visual run used the cable's current USB fallback directly,
without Wi-Fi, the Dell, or an SSH data tunnel. It received and presented all
600 real 5120 x 2880 frames at 22.052 fps and 3.908 Gbit/s, with zero malformed
frames, renderer drops, or GPU errors. Frame-read p99 was 49.4 ms while iMac GPU
work p99 was 6.5 ms. This A/B result localizes that run's limit to transport,
not capture correctness or the iMac Metal presenter.

### Phase 3: sanitize and isolate TBD2

Port only the reference format, tests, GPU encoder, GPU decoder, and band wire
format from PR #158.

Before integration:

- replace signed-shift zigzag with an unsigned/branch-safe formulation;
- run AddressSanitizer and UndefinedBehaviorSanitizer in CI;
- fuzz the parser and all declared lengths/offsets;
- key assembly state by `frame_id` and surface generation;
- permit at most one assembling and one ready frame;
- atomically present only a complete frame;
- add exact 8-bit and 10-bit corpus round trips.

**Gate on each Radeon Pro 570/575/580:** sender encode below 4 ms, receiver decode
below 4 ms, no corruption under injected overlap, and p99 payload small enough to
meet its presentation deadline.

### Phase 4: replicated framebuffer

Add multi-rect/move operations, receiver epochs, absolute tile writes, GPU hashes,
ACK-based credits, checkpoint recovery, and independent cursor transport.

**Gate:** normal development/design work sends under 10% of the surface at p95;
randomly dropped delta transactions recover pixel-exactly without restarting.

### Phase 5: bounded high-entropy codec

If TBD2's worst-case rate misses deadlines, implement or integrate a Metal
DSC/JPEG-XS-like visually lossless 4:4:4 band codec. Keep it intra-frame and
deadline-bounded; do not reintroduce a long video queue.

**Gate:** 5K60 chroma torture patterns and one-pixel colored text remain visually
transparent while payload remains below the real link budget.

## What needs to improve in the current code

1. Receiver presentation: native Metal must become the validated 2017 path.
2. Raw ingest: stream/band into reusable GPU-compatible surfaces; remove full
   frame allocation and SDL upload.
3. Queue semantics: distinguish resource count from latency depth; add deadlines,
   credits, and stale-frame cancellation.
4. TBD2 correctness: sanitizer-clean C oracle, fuzzed parser, frame-local band
   assembly, and complete-frame barriers.
5. Capture: use direct virtual-display IOSurface capture where available and
   preserve all dirty/moved metadata.
6. Fidelity: P3 tagging, 10-bit packed surfaces, pixel-exact corpus tests, and a
   clear distinction between 4:4:4 and 4:2:0 modes.
7. Measurement: stage histograms and external photon verification, not FPS alone.
8. Packaging: a Ventura-compatible receiver app with auto-start/wake, safe
   fallback, and no kernel extension.

## Is a driver required?

No kernel driver can solve the missing physical input path, and one is not needed
for the software appliance.

The sender needs a virtual display endpoint. TargetBridge already supplies this
in user space through `CGVirtualDisplay`, a private CoreGraphics API. The receiver
needs a full-screen Metal application. The new work is a codec, transaction
protocol, scheduler, and renderer—not a kext or DriverKit display sink.

This is safer for the MacBook and more portable to Ventura. The tradeoff is that
private `CGVirtualDisplay` behavior can change in future macOS versions, so the
sender requires compatibility tests.

## Safety boundaries

- No Thunderbolt firmware flashing.
- No kernel extensions, DMA/IOMMU experiments, WindowServer patches, or SIP
  changes.
- No driver, package manager, background service, or startup item was installed
  on the MacBook. The only system addition was Apple's signed Command Line Tools
  after the user clicked Install; the sender itself runs from the workspace.
- Builds stay inside the workspace until explicitly tested.
- The iMac receiver can remain on officially supported Ventura.
- Linux/direct DRM is a later experiment only if macOS presentation is proven to
  be the floor; it does not create a physical display input.

The diagnostics are storage- and memory-bounded. Large 4-16 GiB link tests were
generated in RAM and consumed by `/dev/null`, not stored as frame recordings.
RAW sender backlog is capped at two packets (about 44 MB at 5K), the receiver
rejects packets above 64 MiB, and its IOSurface pool is fixed at four frames.
Disposable screenshots, luma thumbnails, and logs from completed tests were
deleted explicitly (more than 200 MB combined); current build output is about
244 MB on a MacBook with roughly 1.4 TiB free. The iMac probe workspace is 1.1 MB
and the iMac has roughly 850 GiB free.
No unrelated process, VM, daemon, MTU, kext, system extension, SIP setting, or
firmware was changed.

## Confirmed target and next hardware tests

The target has now been inventoried over key-authenticated local SSH:

```text
iMac18,3; Intel Core i5-7600; Radeon Pro 575 4 GB; 40 GB RAM
macOS Ventura 13.7.8; internal 5120 x 2880 30-bit display
```

The current direct Thunderbolt session is attached and negotiated at 40 Gbit/s.
macOS assigned `169.254.35.32` to the MacBook bridge and `169.254.99.244` to the
iMac bridge; route inspection confirmed that traffic between those addresses
used `bridge0`, while Wi-Fi remained available for control.

A fresh bounded, RAM-only single-TCP-stream benchmark with exact receiver
acknowledgement moved 4 GiB MacBook-to-iMac at 17.732 Gbit/s. An earlier pair of
directional runs measured 17.06 Gbit/s MacBook-to-iMac and 15.98 Gbit/s in the
reverse direction. One hundred idle pings had 0% loss and
0.279/0.442/1.121 ms min/avg/max RTT. During
a fully saturated 16 GiB forward run the link sustained 15.73 Gbit/s with 0%
ping loss and 0.200/0.990/5.767 ms RTT. The paced synthetic and real-capture
network-to-IOSurface-to-Metal paths have since sustained essentially 5K60 as
described above. This clears the raw-NV12 software/transport gate but not raw
4:4:4 or the physical capture-to-photon latency gate.

One reconnect temporarily fell back to USB 3.1 Gen 2, where a bounded 256 MiB
test measured 3.934 Gbit/s and the live visual path reached 22 fps. The same
Anker A8859 cable was then tested MacBook-to-Dell and iMac-to-Dell; each endpoint
negotiated 40 Gbit/s with the Dell U3425WE. Reconnecting the awake, unlocked Macs
then restored direct Thunderbolt peer enumeration: the MacBook reports `iMac18,3`
at 40 Gbit/s, the iMac reports `Mac17,7` at up to 40 Gbit/s with link width x2,
and both routes use `bridge0`. No approval prompt or network reset was required.
This A/B result clears the cable and both Thunderbolt controllers; a replacement
cable is not justified. Software should nevertheless detect and reject the USB
fallback before starting raw 5K60.

The universal probe is:

```sh
./benchmark_native_metal_renderer_universal 5120 2880 600 60 iosurface
./benchmark_native_metal_renderer_universal 5120 2880 36000 30 iosurface
./benchmark_native_metal_renderer_universal 5120 2880 57600 48 iosurface
./benchmark_native_metal_renderer_universal 5120 2880 72000 60 iosurface
./benchmark_native_metal_renderer_universal 5120 2880 72000 60 raw-copy
```

The first command is a ten-second smoke test; the four larger frame counts each
run for roughly 20 minutes. The current binary is universal
arm64/x86_64, targets macOS 11 or later, and has SHA-256
`db1dde9d3bc3658d5e9c37b317ac3e3e4eaa3b557b7c741d8a770ba21129309d`.

## Primary sources

- Apple 2017 iMac specifications: https://support.apple.com/en-ca/111969
- Apple Target Display Mode requirements: https://support.apple.com/en-us/105126
- Apple Thunderbolt architecture: https://developer.apple.com/library/archive/documentation/HardwareDrivers/Conceptual/ThunderboltDevGuide/Basics/Basics.html
- Apple Thunderbolt Bridge: https://support.apple.com/en-ca/guide/mac-help/mchld53dd2f5/mac
- Apple low-latency Thunderbolt RDMA limits: https://developer.apple.com/documentation/technotes/tn3205-low-latency-communication-with-rdma-over-thunderbolt
- TargetBridge: https://github.com/swellweb/targetBridge
- TargetBridge raw NV12 PR #142: https://github.com/swellweb/targetBridge/pull/142
- TargetBridge lossless TBD2 PR #158: https://github.com/swellweb/targetBridge/pull/158
- TargetBridge native Metal PR #174: https://github.com/swellweb/targetBridge/pull/174
- OpenDisplay Mac receiver PR #145: https://github.com/peetzweg/opendisplay/pull/145
- OpenDisplay HEVC PR #249: https://github.com/peetzweg/opendisplay/pull/249
- Moonlight exact-2017 result: https://github.com/moonlight-stream/moonlight-qt/issues/1885
- Looking Glass: https://github.com/gnif/LookingGlass
- Apple dirty/moved display updates: https://developer.apple.com/documentation/coregraphics/cgdisplaystreamupdaterecttype
- RFB protocol: https://www.rfc-editor.org/rfc/rfc6143
- DisplayLink EVDI: https://displaylink.github.io/evdi/details/
- VESA DSC: https://vesa.org/vesa-display-compression-codecs/dsc/
- JPEG XS: https://jpeg.org/jpegxs/
