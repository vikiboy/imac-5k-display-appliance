# Turning a 2017 5K iMac into a software display appliance

> **Status:** personal hardware experiment on one exact 2017 27-inch 5K iMac.
> Native Retina geometry, a direct 17.06 Gbit/s Thunderbolt Bridge test, and a
> serial/two-slot DPCM cadence A/B are recorded below. Its presentation oracle
> was later found to count Metal's zero/dropped outcome as success. Version 0.5
> corrected the counter and defaulted to display synchronization; version 0.6
> closed the drain-deadline race and failed closed on accounting invariants.
> Version 0.6 then failed a short RSS gate; version 0.7 separated a redundant
> power call from a bounded telemetry page ramp; version 0.8 replaces that ramp
> with a 600-frame ring and is in an unperturbed one-hour qualification. The
> original directional result is not perfect 60 Hz. This is not a production
> release, support promise, or zero-latency claim.

Apple's [technical specifications](https://support.apple.com/111969) list a
5120 × 2880 P3 Retina panel and Thunderbolt 3 video **output** for the 27-inch
2017 iMac. It is not among the iMacs that support Apple's
[Target Display Mode](https://support.apple.com/105126), which stops at mid-2014.
Its Thunderbolt ports are therefore computer ports, not passive monitor inputs.
The practical question was not “which display driver do we install?” It was:

1. How do we make macOS render a real Retina extended desktop?
2. How do we move those pixels across the cable quickly enough?
3. How do we put them on the iMac panel without softening text?
4. How do we make the result recover automatically and remain safe when it is
   left running all day?

The answer is a two-computer display appliance. The MacBook creates and captures
a virtual display. The iMac remains booted into macOS, receives the frame stream,
and presents it fullscreen. No iMac is opened and no panel cable is changed.

The tested cable is the owner's [Anker A8859 0.7 m Thunderbolt 4
cable](https://www.anker.com/au/products/a8859), the same model as Amazon ASIN
`B095KSL2B9`. It is already rated for 40 Gbit/s. A Thunderbolt 5 cable would
still negotiate to the 2017 iMac's Thunderbolt 3 endpoint, so buying another
cable was not the missing fix.

The direct application-level TCP benchmark reached **17.06 Gbit/s** on
Thunderbolt Bridge. That is the measured payload result for this setup, not the
cable's 40 Gbit/s physical headline rate.

For physical acceptance, the receiver now uses `displaySyncEnabled == YES`.
Only the exact `TB_DISPLAY_SYNC=0` override disables synchronization, and that
override is diagnostic-only; it cannot supply the product-default cadence result.

![The experimental lossless pipeline](../images/imac2017/pipeline.svg)

## What TargetBridge had already solved

This work starts with [TargetBridge](https://github.com/swellweb/targetBridge),
not from a blank repository. Upstream already supplied the product-shaped half
of the answer:

- Sender and Receiver applications;
- mirrored and extended virtual displays;
- Bonjour discovery;
- Thunderbolt Bridge networking;
- H.264/HEVC streaming up to 5K, including an experimental 5K/60 FPS target
  profile;
- input, audio, brightness, clipboard, and reconnect-related features;
- a raw NV12 diagnostic path.

The ownership boundary is straightforward:

| Inherited from TargetBridge and contributors | Work in this personal derivative |
|---|---|
| Sender/Receiver apps, virtual displays, discovery, encoded streaming, input and reconnect foundations | Exact `iMac18,3` appliance profile, fail-closed Thunderbolt selection, stable-path launch agents, and hardware evidence |
| TBD1/TBD2 and GPU codec work from Aykut Alpgiray Ates's PR #158 | Conservative integration, malformed-input/lifecycle hardening, bounded telemetry, and this hardware A/B |
| Native-Metal receiver work from Betafer's PR #174 | Radeon Pro 575 presentation/lifecycle hardening and appliance surface |
| Upstream docs, identity, and screenshots | Independent project name, private repository, owner-captured screenshots, reproducible test notes, and no-support posture |

That is already enough to make an iMac useful as a software display. The gap for
this experiment was narrower: the normal 5K path is a video path. HEVC is a good
portable default, but encoding, decoding, chroma subsampling, and buffering can
make desktop text look unlike a direct Retina display. Upstream itself labels
the 5K/60 FPS target experimental and recommends the 5K/48 FPS target for
reliable daily use. In the current
Sender, the `Work 5K` display profile selects the 48 FPS `native5k` preset; it is
not the separate 60 FPS-target experimental preset used for this DPCM
acceptance work.

Several pieces on our branch also come from newer TargetBridge maintenance work,
not from us. In particular, the direct native-Metal receiver path was developed
by Betafer in [PR #174](https://github.com/swellweb/targetBridge/pull/174). The
acknowledgements section records the exact provenance.

## The earlier lossless experiment we built upon

Aykut Alpgiray Ates's closed draft [PR #158](https://github.com/swellweb/targetBridge/pull/158)
asked almost exactly the fidelity question. It developed TBD1/TBD2, a tiled
differential-pulse-code-modulation format designed for a GPU encoder and GPU
decoder. The PR reported a locked lossless 5K60 result on an M4 Pro MacBook and
a **2020 iMac with Radeon Pro 5300**.

That result is important prior art, but it is not proof for this machine. The
2017 iMac uses a Radeon Pro 575, the PR was never merged, and its final result
used a broader stack that included slicing, 10-bit presentation, keep-warm
behavior, and asynchronous presentation.

We therefore did not copy its headline number. We extracted its tested codec
mathematics and GPU design, then integrated the smallest conservative path into
the maintained receiver architecture and tested the gates again.

## What this branch changes

The current milestone deliberately uses one complete 8-bit DPCM frame at a time:

- ScreenCaptureKit BGRA with full-resolution red, green, and blue channels;
- lossless TBD2 tile-DPCM compression;
- one packet type (`0x25`) negotiated only when the receiver actually compiles
  both its GPU decoder and packed-pixel presentation pipeline;
- three bounded sender jobs and three bounded receiver upload slots;
- no raw-BGRA fallback, no unbounded queue, and no frame files on disk (the
  separate raw diagnostic is NV12/4:2:0);
- explicit SDR Display P3 capture and Display P3 Metal-layer labeling;
- a receiver guard that rejects TBD2 unless source and drawable dimensions
  match exactly; accepted frames use nearest-neighbour sampling without
  enlargement or sharpening.

This branch also adds hardening that was not present in that form in the draft:

- undefined signed-left-shift behavior removed from the C and Metal zig-zag
  residual encoders;
- framing length, integer overflow, geometry, stride, IOSurface-span, and
  malformed-payload validation before untrusted bytes reach the shader;
- explicit sample-buffer and pixel-buffer lifetime ownership until GPU
  completion;
- safe rejection cleanup and encoder draining;
- all-band Metal command construction before commit plus a two-second bounded
  teardown quarantine, so a rare resource failure cannot partially submit a
  frame, hang the sender forever, or free memory still reachable by the GPU;
- a true-Retina activation gate: capture does not begin until macOS reports
  2560 × 1440 logical points backed by 5120 × 2880 pixels;
- a dedicated 2017-iMac appliance Receiver with Bonjour advertisement,
  reconnect waiting, idle-system/display-session power assertions, and a
  fullscreen shielding window locked to the active built-in 5120 × 2880 panel;
- a quiet native waiting surface with distinct detected, starting, interrupted,
  and rejected states plus idle-only About/Quit controls; it has no animation,
  polling timer, or idle Metal workload;
- startup sequencing that acquires the system-sleep assertion first, declares
  remote user activity once, and waits briefly for an asleep built-in panel before
  enforcing the native-5K gate; a slow wake retries in-process with bounded
  backoff and unified diagnostics instead of entering a launchd restart loop;
- a presentation-epoch gate that keeps the waiting surface over a drawable
  Metal layer until macOS confirms a frame from the current connection was
  actually presented, preventing a stale desktop flash during reconnect;
- a bridge-only receiver gate that rejects sessions unless the accepted
  socket's local address is the current link-local address on `bridge0`;
- transport-specific Bonjour endpoint selection on the sender, so simultaneous
  Thunderbolt and USB-NCM link-local addresses cannot be cross-wired;
- a serial transport worker with one reusable packet buffer while AppKit owns
  the main run loop; partial packets and static desktops therefore cannot
  freeze the receiver window, and the handoff cannot grow into a frame queue;
- transient geometry, malformed-frame, and reconnect failures that close only
  the current session, while genuine Metal/GPU failures exit for throttled
  launchd restart instead of silently downgrading fidelity;
- a persistent decoded 5K Metal texture plus three geometrically grown upload
  buffers, with allocation counters proving the hot path does not create a new
  texture view or retire a slightly larger buffer on every frame;
- permission preflight that requests Screen Recording once and suspends
  automatic retries when permission is absent;
- Release builds, bounded debug logs, size-managed unified receiver diagnostics,
  and launchd restart throttling.

The appliance lifecycle also uses stable installed sender and receiver paths,
per-user launch agents, a backed-up/reversible screen-saver idle preference,
and a separately opt-in reversible screen-lock change. It does not terminate
`ScreenSaverEngine` or fight macOS security UI. Screen Recording consent remains
tied to the stable sender TCC identity. Those controls cannot unlock a session
that is already locked.

The intended cursor path is deliberately the standard macOS cursor captured by
ScreenCaptureKit. The receiver hides the iMac's local cursor only for the live
session and balances that hide on disconnect before releasing its display-awake
assertion. TargetBridge's separate custom **Large Cursor** option remains off in
this appliance build; packet-only overlay redraw on a static DPCM texture is a
documented follow-up, not part of the result below.

Cursor contract tests pass, but that is not human acceptance. Because the
current iMac session was already locked, it still needs one physical unlock
before movement, shapes, clicks, drags, and disconnect restoration can be judged.

This is integration and reliability hardening, not invention of TargetBridge,
native Metal, or TBD2.

## Why the analogies mattered

The useful leap was to stop treating the iMac like a missing HDMI input.
The result could eventually have been reached by exhaustive profiling, but the
analogies were load-bearing because they changed which system we tried to
build. They turned one apparently impossible “display driver” problem into four
familiar problems—virtual display geometry, thin-client transport, framebuffer
compression, and bounded real-time scheduling—and supplied a proven design
constraint for each. They did not substitute for measurement; they told us
which measurements would eliminate whole classes of wrong solutions.

### A headless display, not a mirrored screenshot

Virtual-camera and headless-display systems separate logical layout from backing
pixels. That analogy made “5K” two different numbers: 2560 × 1440 **points** and
5120 × 2880 **pixels**. A 5120-pixel packet can still contain a scaled low-resolution
desktop, so packet dimensions alone are not proof of Retina rendering.

![Retina points versus backing pixels](../images/imac2017/retina-geometry.svg)

### A thin client, not a passive monitor

The iMac remains a computer. Thin-client and game-streaming systems suggested
the capture → transport → presentation decomposition, but desktop text changed
the optimization target: fidelity and deterministic latency matter more than
very low video bitrates.

### A framebuffer codec, not a movie codec

Remote-framebuffer systems exploit spatial repetition and changed regions.
TBD2 makes 8 × 8 tiles independent and uses a cheap left-neighbour predictor.
The jagged leap from “DPCM is serial” to “a row prefix sum is parallel” is what
makes GPU decoding plausible.

### A bounded real-time queue, not a file transfer

Audio engines and camera pipelines routinely drop stale work instead of allowing
latency to grow. The Sender caps the combined encode/send work at three frames.
The Receiver permits at most three GPU submissions and has three upload slots;
serial receive has one fixed 64 MiB packet slot, and the provisional overlap
mode adds exactly one more. A late frame is less useful than the next current
one, and no mode may grow an unbounded queue.

## What the tests currently prove

The current commands and sanitized component-result summaries live under
[`docs/repro/imac-2017-5K`](../repro/imac-2017-5K/README.md).

| Gate | Current result | What it proves |
|---|---:|---|
| Sender unit suite | 133/133 | Protocol framing, automation parsing, profile and discovery behavior |
| Receiver network parser | 73 checks | Bounded packet framing and malformed lengths |
| TBD2 codec | 290 checks | Exact CPU round-trip and malformed-blob rejection at 8 and 10 bits |
| DPCM GPU lifecycle | 43 checks | Pre-commit failure cleanup and bounded teardown quarantine |
| Receiver input queue | 562 checks | Bounded input-event behavior |
| Receiver profile | 13 checks | Panel/logical/backing profile selection |
| Renderer policy | 22 checks | Deterministic native-Metal fallback policy |
| Raw NV12 parser | 99 checks | Strict raw diagnostic parsing |
| Receiver shutdown fixture | Passed | Idle listener, active peer, descriptor reuse, and closed post-shutdown admission |
| Receiver installer-order fixture | Passed | A disabled launchd override is cleared before bootstrap |
| AppKit launch lifecycle | Passed | One launch completion; borderless idle controls can become key without reconnect focus stealing |
| Native Metal fixture | 192 frames passed | Real GPU pipelines, stable 3/1/1 DPCM reuse, and presentation-epoch handoff |
| 2017 iMac idle baseline | 7/7 stable samples | 0.0% CPU, 16,336 KiB RSS, 11 FDs, and no app-log/support growth over 60 seconds |
| Receiver start with panel asleep | Passed | One restart woke the panel, reaccepted native 5K, restored the on-screen appliance window, and listened without an AppKit exception |
| Receiver graceful reinstall | Passed | SIGTERM closed admission, restored the cursor, released power/Metal state, and one verified process/listener returned |
| Retina display geometry | **passed on current setup** | 2560 × 1440 HiDPI points → 5120 × 2880 pixels at 60 Hz |
| Direct Thunderbolt Bridge | **17.06 Gbit/s** | Application-level TCP throughput on the tested cable/setup |
| Serial DPCM receiver | **58.718 reported FPS; superseded oracle** | p95 19.6 ms, p99 34.9 ms, maximum 122 ms; zero packet/parser/queue/GPU-command failures |
| Two-slot DPCM receiver | **59.293 reported FPS; provisional candidate** | p95 19.0 ms, p99 34.0 ms, maximum 54.15 ms; zero packet/parser/queue/GPU-command failures; one added fixed 64 MiB slot |
| Initial one-hour whole-frame resource baseline | **qualified failure** | No process, FD, thread, storage, heap-leak, or thermal-warning failure; receiver RSS rose 6.251 MiB/hour after warm-up, above the strict 2 MiB/hour gate |
| Installed v0.5/build 8 one-hour run | **qualified failure** | Same bounded-resource gates passed and receiver heap leaks remained zero; RSS improved to +4.460 MiB/hour but still failed the 2 MiB/hour gate; dirty-worktree identity prevents release use |
| Installed v0.6/build 10 run | **qualified early failure** | At 1,201 seconds the post-600-second receiver slope was +7.363 MiB/hour; the exact once-per-minute staircase matched a redundant user-activity renewal |
| Installed v0.7/build 12 diagnostic | **not acceptance evidence** | Confirmed the wake token was not renewed, then isolated lazy page commitment in two first-ten-minute telemetry arrays; `heap`/`vmmap` deliberately perturbed the 540-second run |
| Installed v0.8/build 13 one-hour run | **qualified failure, completed** | Sender RSS was essentially flat, threads/FDs/disk stayed flat, and no thermal warning appeared; receiver RSS rose +4.819 MiB/hour after 1,200 seconds. The securely locked iMac accepted 215,747 DPCM packets but completed zero presentations, proving that v0.8 kept doing expensive work behind an unavailable surface |
| v0.9 lifecycle candidate | **component and live control-plane pass; paired stream pending** | Adds explicit receiver-surface/source-display epochs, an ordered acknowledgement barrier, fail-closed capture/GPU/audio pause, lock-aware startup, balanced cursor/power ownership, and fresh-current-generation presentation before unblank. The installed iMac receiver advertised 5120 × 2880, 2560 × 1440 HiDPI, 60 Hz, DPCM, and lifecycle support, then returned to 0% CPU / 12 MiB after the probe |
| Cursor | **automated contract passed; human pass pending** | An already-locked iMac still requires one physical unlock before cursor acceptance |
| Final qualification | **pending** | Stable sender installation/TCC approval plus paired lock/unlock, sleep/wake, cable reconnect, Dell coexistence, corrected cadence, active-surface RSS, and duplicate-cursor acceptance remain open |

The cadence numbers above came from the actual Radeon Pro 575, but their success
counter incorrectly substituted callback time for a zero hardware presentation
timestamp. They are directional only; the 34.0 ms overlap p99 also missed the
project's 25 ms locked-60 gate. Numbers measured on the 2020
iMac in PR #158 remain prior work, not our result. The full sanitized A/B and
commands are in the [2026-08-30 result](../repro/imac-2017-5K/results/2026-08-30-serial-overlap-ab.md).

## Screenshots and physical evidence

The native macOS Displays pane now lists the Dell, the MacBook panel, and the
TargetBridge iMac together. This is important: the iMac stream is backed by a
real extended virtual display, so macOS—not a remote-control window—owns its
arrangement and logical coordinate space.

![macOS lists the project virtual display beside the Dell and built-in display](assets/macos-display-arrangement.png)

This privacy-cropped, project-owned System Settings capture proves that `TB
Extend`, the Dell, and the MacBook's built-in display coexist in one native
arrangement. It does not prove receiver presentation cadence.

![Project-owned 5120×2880 Retina motion source on the MacBook](assets/native-retina-motion-source.png)

The second project-owned image documents the controlled 2560 × 1440-point /
5120 × 2880-pixel motion source: fine grid, colors, text, and changing tick.
It is a **MacBook source capture, not an iMac output screenshot**. macOS remote
screen capture omits the receiver's shielding/Metal surface and shows the
underlying iMac desktop, so such a capture cannot honestly document receiver
output. The owner previously observed the physical output directly, but cursor
acceptance is still pending the physical unlock described above.

Additional sanitized evidence may be added only when it is owner-captured and
its provenance is certain:

1. The physical 2017 iMac Thunderbolt port and the exact cable.
2. Network settings showing Thunderbolt Bridge on both Macs.
3. System Information showing a 40 Gb/s physical Thunderbolt link, with serials
   and device identifiers removed.
4. An on-device photograph of the text/color/grid target on the iMac panel,
   clearly distinguished from the MacBook source capture above.
5. The final overlap-candidate resource and reconnect results.

Screenshots are added only after redaction. Raw `system_profiler`, `.xcresult`,
dSYM, and log files are not published because they contain user paths, device
identifiers, hostnames, IP addresses, or process metadata.

## Reproduce it

The short version is:

1. Use a 2017 27-inch 5K iMac (`iMac18,3`) and an Apple Silicon sender Mac.
2. Connect them with a certified Thunderbolt 3-or-newer cable and enable
   Thunderbolt Bridge on both Macs.
3. Build the sender and dedicated receiver from one immutable commit.
4. Install each app at its final stable path before granting privacy permission.
5. Grant Screen Recording to the sender once.
6. Start the receiver, then the separate experimental 5K/60 FPS-target preset
   with DPCM enabled. Do not report either requested target as physical cadence.
7. Verify the direct interface, Retina point/pixel pair, DPCM negotiation,
   source/drawable 5120 × 2880 match, and Display P3 label.
8. Run both receiver modes with the identical ten-minute motion target and
   compare `presentedTime` gaps and integrity counters.
9. Run the overlap-candidate soak, unplug/replug, and sleep/wake recipes.
10. Physically unlock an already-locked iMac once before the human cursor gate.

The detailed build, verification, rollback, and evidence commands are in the
reproduction guide. Do not expose port 54321 on an untrusted LAN: the current
experimental protocol is not authenticated or encrypted and carries screen
contents in plaintext. Prefer the isolated direct Thunderbolt link.

## What “done” means

For this project, done is experiential, not rhetorical:

- plug in the cable and get an extended display without manual terminal work;
- native 2× Retina geometry and lossless DPCM reconstruction of the captured
  full-resolution RGB raster;
- usable cursor, clicking, dragging, Spaces, and normal MacBook input;
- coexistence with the Dell display and power connection;
- recovery after unplug/replug and sleep/wake;
- stable frame cadence without an accumulating queue;
- flat memory/file-descriptor/log-size trends during a sustained run;
- acceptable measured CPU, GPU, temperature, and battery impact.

Until all of those pass on the exact hardware, the honest label is “promising
experimental appliance,” not “production-grade monitor replacement.”

## Where AI could help—and where it should not

AI should not invent pixels, sharpen text, or sit in the critical display path.
That would add latency and violate the native-fidelity goal.

A phase-two experiment could classify frame entropy or change structure and
choose between already-correct transport strategies before congestion occurs.
It ships only if it beats a deterministic heuristic on predeclared metrics:
p99 latency, missed 16.7 ms deadlines, bandwidth, CPU/GPU energy, and false
switches. If it does not produce a measurable improvement, it remains a research
note rather than a dependency. The concrete fail-closed protocol and test plan
are in the [changed-tile research note](../research/lossless-changed-tiles.md).

## Acknowledgements and provenance

- [TargetBridge](https://github.com/swellweb/targetBridge) and Marco Caciotti
  provided the MIT-licensed Sender/Receiver foundation.
- Aykut Alpgiray Ates developed the earlier TBD1/TBD2 and GPU experiment in
  [PR #158](https://github.com/swellweb/targetBridge/pull/158), especially the
  [TBD1 codec](https://github.com/swellweb/targetBridge/pull/158/commits/740c2babbd01ab3eb360c187c7cb26dc6b936076),
  [GPU decoder](https://github.com/swellweb/targetBridge/pull/158/commits/43abe4e45f80a66695d7c27d41c7cd05b2608ae3),
  [TBD2 format](https://github.com/swellweb/targetBridge/pull/158/commits/29f557602bf74d080c3fcdc5f6b4dff94ed70b9e),
  and [GPU encoder](https://github.com/swellweb/targetBridge/pull/158/commits/08bf28f6b2cf0b7f2e1f58e8b32f95e17d2850d2)
  commits.
- Betafer developed the native-Metal receiver in
  [PR #174](https://github.com/swellweb/targetBridge/pull/174), specifically its
  [zero-copy path](https://github.com/swellweb/targetBridge/pull/174/commits/32bcf3dc15b56e42e84b35eebe2fe3478dc38e2b)
  and [validation/Display P3 work](https://github.com/swellweb/targetBridge/pull/174/commits/1d2d62cdbda3b6eccf24adfa9336a8bb53b07b77).
- Additional TargetBridge contributors are credited in the upstream history.

The repository retains the upstream MIT license and copyright notice. This is
an independent experimental branch, not an official Apple or TargetBridge
release. It is maintained for one owner's personal setup, with no support SLA,
compatibility promise, feature-request commitment, or public roadmap. That
posture does not narrow the MIT license. Apple, MacBook Pro, iMac, Retina, and
Thunderbolt are trademarks of their respective owners.
