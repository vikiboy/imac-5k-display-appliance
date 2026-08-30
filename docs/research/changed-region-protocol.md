# Changed-region transport for deterministic native 5K cadence

## Recommendation

Prototype a capability-negotiated changed-region protocol for the **BGRA/TBD2
path first**. Keep one complete receiver framebuffer, establish it with a
sequenced full keyframe, and then send independently decodable, lossless TBD2
rectangles sampled from the newest complete source image. Accumulate damage in
a fixed 8 x 8 tile bitmap across every frame rejected by pacing or
backpressure. Never infer motion, pixels, or a base state.

This is the highest-confidence next performance experiment for ordinary desktop
work. It attacks the repository's measured byte-proportional socket, upload,
and decode costs. It is not a general solution for full-screen video, and it
cannot repair information already discarded by an NV12 capture.

Version 0.5 fixed the measurement oracle before making any new cadence claim;
version 0.6 closes its final drain-deadline race and fails closed on impossible
presentation accounting.
Apple defines `MTLDrawable.presentedTime == 0` to mean that the drawable has not
been presented or was dropped. The current receiver counts zero, negative, and
non-finite presentation times as drops; it never substitutes callback time. The
earlier serial/overlap A/B used that substitution and is historical directional
evidence only. See
[`recordDrawablePresentedForEpoch`](../../TargetBridge-Receiver/TBReceiverC/src/tb_native_metal_renderer.m#L833)
and Apple's [`presentedTime` contract](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime).

## What the current formats actually preserve

TargetBridge currently has two different unencoded 5K contracts:

- Whole-frame `0x25` TBD2 is sourced from 32-bit BGRA, codes B/G/R exactly,
  reconstructs opaque alpha, and presents as 8-bit SDR Display P3. The sender
  explicitly selects BGRA for DPCM in the
  [ScreenCaptureKit configuration](../../TargetBridge-Sender/TBDisplaySender/TBDisplaySenderService.swift#L3162),
  and the codec documents its lossless modular residuals in
  [`tb_dpcm.h`](../../TargetBridge-Shared/codec/tb_dpcm.h).
- Diagnostic `0x22` is whole-frame, 8-bit video-range NV12. Its 4:2:0 chroma
  was already subsampled before transport, and v1 transmits no color metadata.
  A byte-exact NV12 patch would preserve those Y and CbCr samples exactly, not
  recreate 4:4:4 RGB detail. See
  [`proto.h`](../../TargetBridge-Receiver/TBReceiverC/src/proto.h) and
  [`sendRawFrame`](../../TargetBridge-Sender/TBDisplaySender/TBDisplaySenderService.swift#L1034).

Therefore, "lossless" must always be qualified as lossless relative to the
negotiated canonical source raster. For BGRA v1, that is active B/G/R bytes with
alpha declared opaque. For a later NV12 variant, it is active Y and interleaved
CbCr samples, excluding stride padding, with range, matrix, primaries, and
transfer function declared by the keyframe.

## What the analogues teach

| System | Mechanism worth borrowing | Boundary for TargetBridge |
| --- | --- | --- |
| RFB/VNC | A rectangle update moves the client from one valid framebuffer state to another; the client retains the framebuffer and asks for a non-incremental refresh after losing it. CopyRect is allowed only when the client already has the source pixels. | Retain one authoritative base and make full refresh explicit. Do not add CopyRect without an authoritative source coordinate. [RFC 6143](https://www.rfc-editor.org/rfc/rfc6143) |
| RDP graphics pipeline | Logical start/end-frame IDs, client frame acknowledgement, reported queue depth, retained surfaces, and bounded bitmap caches separate state correctness from codec choice. | Borrow frame IDs, ACK/resync, and a hard cache budget. Do not borrow progressive RemoteFX: it uses quantization and persistent codec state and is not this project's byte-exact contract. [frame ACK](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/0241e258-77ef-4a58-b426-5039ed6296ce), [progressive quantization](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/975d22c6-ff68-4ab1-a207-f51ec4af23c6), [cache cap](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/d1c1540f-9bc7-4344-81e0-3cce6b845f86) |
| Wayland | Damage is unioned as double-buffered state and becomes current at an atomic `wl_surface.commit`. `damage_buffer` uses unambiguous buffer coordinates. | Build one validated logical update, apply all its rectangles, and only then present it. [Wayland protocol](https://wayland.freedesktop.org/docs/html/apa.html#protocol-spec-wl_surface-request-damage_buffer) |
| Waypipe | It keeps a mirror of what the remote side possesses and diffs only damaged regions; its source bounds pathological damage-processing work and falls back to a simpler, larger interval. It also acknowledges that large animation updates still cause latency spikes. | Keep damage work bounded and prefer a conservative full update over an expensive optimal cover. A retained remote-state model is useful; an unbounded cache is not. [Waypipe README](https://gitlab.freedesktop.org/mstoeckl/waypipe/-/blob/a1ffdd8d0f44cbdb25a3edd1c6adc0a30cfcf754/README.md#latency), [damage implementation](https://gitlab.freedesktop.org/mstoeckl/waypipe/-/blob/a1ffdd8d0f44cbdb25a3edd1c6adc0a30cfcf754/src/damage.rs) |
| DXGI desktop duplication | A complete current GPU surface accompanies non-overlapping dirty rects and screen-to-screen move rects. If metadata storage is pressured, Windows conservatively coalesces regions and may include unchanged pixels. Moves must be applied before dirty pixels. | Over-reporting damage is safe; under-reporting is not. Keep the complete latest source available and treat region simplification as a cost decision, never a fidelity decision. [Desktop Duplication API](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/desktop-dup-api) |
| ScreenCaptureKit | Frames wrap IOSurface-backed pixel buffers; `dirtyRects` is the union of redrawn and moved regions. Apple explicitly recommends transmitting those regions and copying them over the receiver's previous frame. Surfaces must return to the pool promptly or capture stalls. | This is the direct enabling API, but retaining capture surfaces as a backlog is unsafe. Stage damage into app-owned GPU state and release ScreenCaptureKit buffers promptly. [WWDC22](https://developer.apple.com/videos/play/wwdc2022/10155/?time=572), [`dirtyRects`](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/dirtyrects), [capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) |

Two additional negative lessons matter:

- RFB's ZRLE uses one zlib stream for a connection and therefore requires
  strict ordered decoding. TargetBridge should not add cross-packet entropy
  state: each full or patch payload should remain independently decodable so a
  reset is cheap. [RFC 6143, ZRLE](https://www.rfc-editor.org/rfc/rfc6143#section-7.7.6)
- RDP ClearCodec has stream sequence and cache-reset controls, and RDP's bitmap
  cache uses keyed slots. Those mechanisms are appropriate for a general remote
  application protocol, but a single full-screen appliance needs only its one
  persistent framebuffer at first. A content-addressed tile cache adds hashing,
  eviction, and mismatch states without improving the basic dirty-region case.
  [ClearCodec stream](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/f6c8a114-eaba-489f-9626-f41ad27a19b1)

## The dropped-frame trap

Apple describes ScreenCaptureKit dirty rectangles as changes from the previous
frame. If captured states are `F0, F1, ... Fn` and `Di` covers every sample
that can differ between `F(i-1)` and `Fi`, then a receiver still holding `Fk`
needs pixels from the newest `Fn` over:

```text
D(k+1) union D(k+2) union ... union Dn
```

Sending only `Dn` after pacing or backpressure drops an intermediate frame can
leave stale pixels indefinitely. It is safe to coalesce transient states, as
RFB does, but only if the accumulated union is sampled from the newest complete
state.

Core Graphics' older display-stream API makes this rule unusually explicit:
[`CGDisplayStreamUpdateCreateMergedUpdate`](https://developer.apple.com/documentation/coregraphics/cgdisplaystreamupdatecreatemergedupdate)
merges two ordered updates specifically when the client drops frames. The
current direct fallback already receives a `CGDisplayStreamUpdate` but discards
it. Its deprecated merge function and dirty/move metadata are useful as an
oracle for that fallback, not a reason to prefer deprecated capture over
ScreenCaptureKit. [update rectangles](https://developer.apple.com/documentation/coregraphics/cgdisplaystreamupdategetrects),
[dropped-frame counter](https://developer.apple.com/documentation/coregraphics/cgdisplaystreamupdategetdropcount)

A tile bitmap alone is not enough to deliver a final static change. If the only
capture surface containing that change is released after an encode slot is
unavailable, there may be no later complete frame from which to sample it.
Holding that ScreenCaptureKit surface indefinitely can starve the surface pool.
The robust design is:

1. Allocate one app-owned, persistent **latest-source** GPU image in the
   negotiated pixel format (56.25 MiB for tight 5120 x 2880 BGRA; 21.09 MiB for
   tight NV12).
2. On every valid capture callback, validate metadata, union tile-aligned damage,
   copy those source regions into `latest-source`, and release the capture
   surface as soon as that bounded GPU copy completes.
3. On pacing or encode pressure, skip the expensive encode/send, never the
   stage-and-union operation.
4. When a slot opens, encode the accumulated region from `latest-source` even if
   no new capture callback arrives. Use one ordered GPU command stream or
   equivalent fences so the encoded generation cannot race a newer staged
   update.

If the stage copy itself cannot be admitted, mark the accumulator **full** and
force a fresh complete capture/keyframe when admission recovers. Never clear
damage merely because work was attempted; clear it only after an immutable work
generation owns it, and merge it back or force full on submission failure.

At 5K, an 8 x 8 bitmap is only 640 x 360 bits, or 28,800 bytes. Two generations
(`pending` and `frozen-for-send`) remain negligible and avoid a growing list of
rectangles.

## Proposed `changedRegionsV1` contract

Negotiate the feature in the receiver profile. A peer that does not advertise
it continues using the current whole-frame packet. Within the new capability,
use a new envelope for both keyframes and patches; a bare legacy `0x25` packet
does not carry enough base identity to establish safe patch state.

The exact binary layout can be chosen during implementation, but the semantic
fields are required:

```text
kind = FULL | PATCH | ACK | RESYNC
version, header_length, flags
epoch[16]                 random per state-reset session
format_id                 immutable width/height/pixel/color contract
base_sequence             state required before applying this packet
frame_sequence            state produced by this packet
capture_sequence/time     diagnostics; never a cross-Mac presentation clock
rectangle_count, body_length, body_crc32c
rectangles[] = {x, y, width, height, codec, payload_length, payload_crc32c}
payloads[]
```

The full format descriptor is carried by `FULL`, and `format_id` identifies it
within the epoch. All integers have declared byte order. CRC protects framing
and compressed payloads from accidental corruption; correctness must not rely
on a probabilistic framebuffer hash.

For BGRA/TBD2 v1:

- Convert and clip capture damage to buffer pixels, then expand it to 8 x 8
  tiles. The conversion from ScreenCaptureKit rectangles through `contentRect`,
  `contentScale`, and `scaleFactor` must first pass the pixel-diff oracle below;
  Apple's short property documentation is not sufficient reason to guess units.
- Convert the tile bitmap into sorted, disjoint rectangles. Merge only when the
  added encoded area is cheaper than another header. Cap the result (for
  example, 512 rectangles); over-cap means `FULL`.
- Each rectangle contains an ordinary, independently decodable TBD2 blob for
  that rectangular raster. It depends on no neighboring rectangle and no
  earlier compressed packet.
- Use `PATCH` only when its measured/estimated total bytes are below the full
  TBD2 choice. Full-screen or high-entropy damage naturally chooses `FULL`.

For a later NV12 variant, expand luma damage outward to even x/y boundaries and
send both the active Y rectangle and its corresponding half-resolution
interleaved CbCr rectangle. Rectangle alignment must never split a chroma sample.
First add explicit color metadata to the format descriptor; otherwise a
byte-exact NV12 transport can still be colorimetrically ambiguous.

### Sender state machine

- A new connection, capture restart, wake, display-mode change, geometry or
  pixel/color-format change, cursor-composition policy change, RESYNC, or any
  uncertainty creates a new random epoch and requires `FULL`.
- `frame_sequence` is monotonic and never reused within an epoch. A patch names
  the exact prior scheduled state as `base_sequence`.
- TCP delivers bytes in order, but an RDP-style ACK is still valuable: ACK only
  after receiver GPU application succeeds, and report last applied/presented
  sequence plus bounded queued bytes/commands. Use it to limit the existing
  one-to-three-work-item window, not to build a latency-growing queue.
- Pacing and backpressure accumulate damage into the next unscheduled state.
  They may collapse transient frames but cannot break the base chain.
- A periodic full keyframe is a bounded repair/checkpoint, not a substitute for
  sequence validation. Its interval is a measured tradeoff; do not hard-code a
  high full-frame rate that erases the sparse-update win.

### Receiver state machine

- Keep exactly one persistent canonical framebuffer plus fixed-size upload and
  decode workspaces. There is no disk cache and no content-keyed tile LRU.
- Parse the entire packet before Metal submission. Check epoch, format, exact
  packet length, rectangle cap, sorted non-overlap, coordinates, tile/chroma
  alignment, multiplication/offset overflow, payload lengths, checksums, and
  codec headers.
- Accept `PATCH` only when `base_sequence` equals the last state already
  enqueued on the ordered Metal command queue. Decode every rectangle and render
  the resulting canonical framebuffer to one drawable in the same logical GPU
  update. Present no intermediate rectangle state.
- ACK application only from successful command-buffer completion. A GPU failure
  quarantines the epoch and renderer, as the current full-frame path already
  does. A presentation callback separately records whether that state actually
  reached scanout.
- On a stale/unknown epoch, base mismatch, sequence gap, checksum/parser error,
  timeout, or uncertain GPU contents, apply nothing, discard the base, send
  RESYNC, and accept no patch until a new `FULL` succeeds.

On today's TCP transport, ordinary packet loss is recovered below the
application. A missing application packet therefore means a broken connection,
framing failure, or implementation bug; the safe recovery is reconnect/new
epoch/full. If a future datagram transport exposes loss, the receiver must
discard dependent patches after a gap until a new full epoch arrives. It must
never skip a missing patch and continue.

## CopyRect and cursor policy

RFB and DXGI show that authenticated move rectangles are valuable, especially
for scrolling. DXGI requires moves before dirty pixels because overlap and
subsequent redraw order matter. ScreenCaptureKit's public `dirtyRects` value is
only the union of redrawn and moved destinations; it does not provide the move
source. Therefore `changedRegionsV1` should send pixels for all dirty regions
and omit CopyRect.

The older CGDisplayStream fallback does expose moved rectangles and a source
delta, but that API is deprecated. It can motivate a later, separately tested
operation; it should not be generalized to ScreenCaptureKit by pixel matching
or a learned guess. [moved rectangles](https://developer.apple.com/documentation/coregraphics/cgdisplaystreamupdaterecttype),
[source delta](https://developer.apple.com/documentation/coregraphics/cgdisplaystreamupdategetmovedrectsdelta)

When ScreenCaptureKit pre-renders the native cursor, the damage-coverage test
must prove that every old and new cursor footprint and every custom cursor-shape
change is covered. For the existing explicit large-cursor overlay, cursor
packets remain separate and must not mutate the framebuffer base. Any uncovered
cursor pixel forces full fallback and blocks release.

## Expected cadence and thermal effect

For a static IDE, typing, pointer movement, window motion, and many scrolls,
small patches should reduce:

- sender DPCM pixels analyzed and packed;
- wire bytes and receiver TCP/parser copies;
- receiver upload bytes and DPCM threadgroups; and
- GPU/CPU memory bandwidth, which may reduce package power and thermal pressure.

Those are hypotheses, not guarantees. Staging the latest source adds a GPU copy,
rectangle processing adds fixed work, and many small rectangles can cost more
than one full frame. The deterministic byte/area threshold and full fallback
make those costs measurable and containable.

This protocol cannot reduce ScreenCaptureKit/WindowServer's cost of producing a
native 5K IOSurface. It cannot restore NV12 chroma, range, or color information.
It cannot improve a full-screen high-entropy workload whose dirty region is the
whole display. It also cannot solve drawable starvation or scanout scheduling
by itself.

For Metal, keep the drawable pool and work window small. Apple advises
requesting `nextDrawable` only when needed and releasing drawables promptly;
increasing the pool can turn missed deadlines into latency. The receiver already
uses three drawables and three in-flight permits. Acquire a drawable as late as
the implementation allows and measure wait time rather than increasing those
limits. [`CAMetalLayer` drawable guidance](https://developer.apple.com/documentation/quartzcore/cametallayer)

`present(at:)` may be tested only after changed regions create deadline
headroom. Apple specifies that a late drawable presents as soon as possible, so
scheduling cannot rescue work that already exceeds 16.67 ms. Use a receiver-
local clock derived from recent presentation times; the sender's Mach host time
is from a different Mac. [`present(at:)`](https://developer.apple.com/documentation/metal/mtldrawable/present(at:)),
[`addPresentedHandler`](https://developer.apple.com/documentation/metal/mtldrawable/addpresentedhandler(_:))

The current receiver sets `displaySyncEnabled` to `YES` by default for
tear-free scanout. The exact diagnostic override `TB_DISPLAY_SYNC=0` disables
synchronization only for controlled latency/tearing A/B runs; a missing,
empty, or any other value retains the synchronized default. Record this setting
with every presentation result and compare the override independently of the
transport so a throughput change is not confused with scanout artifacts. An
unsynchronized diagnostic result is not evidence for the product-default
physical acceptance gate. [`displaySyncEnabled`](https://developer.apple.com/documentation/quartzcore/cametallayer/displaysyncenabled)

## Phased benchmark gates

### Gate 0: trustworthy baseline

- Treat every nonpositive or non-finite `presentedTime` as a dropped/not-
  presented drawable; never replace it with callback time for an acceptance
  metric.
- Instrument capture `displayTime`, callback, stage copy, encode submit/complete,
  packet bytes, send completion, receiver parse, Metal submit/complete,
  drawable wait, and actual presented time. Use clock synchronization or a
  visual/event marker for cross-Mac latency; do not subtract unrelated host
  clocks.
- Record p50/p95/p99 and gaps over 33.3 ms, unique sequences presented, queue
  depths, RSS, allocation counts, CPU/GPU time, package energy, thermal state,
  and ScreenCaptureKit/CGDisplayStream drops.

### Gate 1: metadata containment oracle

- In a test-only memory pipeline, compare consecutive canonical full rasters
  byte-for-byte and prove that the accumulated, transformed, aligned dirty
  tiles cover every changed active sample. Over-coverage passes; one changed
  sample outside damage fails.
- Cover static text, typing, all native/custom cursors, window drag/resize,
  Mission Control, fast bidirectional scroll, video, transparency, display
  sleep/wake, mode changes, and forced pacing/backpressure drops.
- For the direct fallback, compare manual union with ordered
  `CGDisplayStreamUpdateCreateMergedUpdate`. Missing/malformed metadata and any
  reported capture drop force full damage.

Do not proceed until there are zero under-coverage events over at least 100,000
generated transitions and a one-hour real desktop trace on each supported
capture path.

### Gate 2: protocol and reconstruction

- CPU and GPU reference tests must reconstruct byte-identical canonical rasters
  after random full/patch sequences, overlapping source damage, alignment
  expansion, and arbitrary pacing drops.
- Fuzz counts, lengths, coordinates, ordering, CRCs, integer overflow, stale
  epochs, wrong bases, repeats, gaps, reconnects, and disconnect at every byte
  boundary. No invalid packet may reach Metal; no partial logical update may be
  presented.
- Verify automatic new-epoch/full recovery after reconnect, restart, wake,
  geometry/format change, GPU failure, and RESYNC.
- Assert fixed upper bounds for capture surfaces retained, tile maps, patch
  workspaces, packets, in-flight jobs, file descriptors, threads, and logs;
  after warmup, no hot-path allocation should scale with session duration.

### Gate 3: 2017 iMac hardware A/B

Run paired, randomized-order full-frame versus changed-region trials. Report
sparse desktop and full-screen high-entropy workloads separately.

Required sparse-workload ship gate:

- zero pixel mismatches and zero protocol/GPU errors;
- at least 50% lower median wire bytes and no worse p99 bytes than the
  deterministic full-fallback decision predicts;
- at least 58.5 unique hardware presentations/s for ten minutes under a
  continuously changing controlled 5K workload;
- present-gap p95 <= 20 ms, p99 <= 25 ms, and no more than 0.1% above 33.3 ms;
- materially better p99 capture-to-present latency or missed-deadline rate
  across five paired runs, with 95% confidence, not merely a higher mean FPS;
- no thermal-pressure warning, no post-warmup RSS growth above 2 MiB/hour, no
  additional retained ScreenCaptureKit backlog, and no greater package energy
  than the full-frame baseline. A repeatable 10% energy reduction on sparse
  work is a useful success target, not a correctness requirement.

Required full-screen fallback gate: zero fidelity/cadence regression greater
than measurement noise (use 2% as the investigation threshold), bounded memory,
and clean interruption recovery. Changed regions do not justify a universal
5K60 claim unless this full-frame workload independently meets that claim.

### Gate 4: presentation experiments

Only after Gate 3 passes, A/B receiver-local `present(at:)`, late drawable
acquisition, and the exact diagnostic `TB_DISPLAY_SYNC=0` override one change at
a time. Keep display synchronization enabled for the product-default acceptance
run. Reject any option that improves mean cadence by adding a frame of latency,
increases p99, tears under the synchronized default, or increases zero-time/
dropped drawables.

## Is a small AI classifier justified?

Not now. ScreenCaptureKit supplies ground-truth damage, and the safe decision
space is small: a deterministic policy can choose disjoint rectangles, one
bounding rectangle, or full frame using exact area, header cost, recent
compression ratio, and queue state. A model cannot improve pixel correctness.

Consider an optional classifier only after Gates 0-3 leave a repeatable gap
between the deterministic choice and an offline oracle. It may consume only
non-semantic scalar features already computed for the deterministic policy and
choose among already validated encodings. It may not choose coordinates, skip
required damage, synthesize pixels, modify epochs/sequences, or participate in
decode.

Require all of the following on held-out traces and real 2017 hardware:

- at least 10% or 1 ms (whichever is larger) lower p99 capture-to-present, or
  at least 20% fewer missed 16.67 ms deadlines, than the tuned deterministic
  policy across five paired runs;
- no pixel, recovery, memory, energy, or thermal regression and runtime
  inference below measurement noise;
- a versioned model, reproducible feature normalization, and complete telemetry
  of model versus deterministic choices; and
- fail-closed sanitization: missing model, NaN/out-of-range output, unsupported
  class, low confidence, or inference timeout selects the deterministic full
  fallback. The model is removable without changing the wire protocol.

If it cannot clear that bar, it is extra heat and state on a machine where both
are scarce; do not ship it.
