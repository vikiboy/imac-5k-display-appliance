# iMac 5K Display Appliance

Turn one specific 2017 27-inch 5K iMac into a native-Retina extended display
for a MacBook, without opening the iMac or replacing its panel controller.

> **Personal project, not a product promise.** I built this for my own hardware.
> I am not committing to support other machines, maintain a public roadmap, or
> develop features on request. If it is useful, you are welcome to study, use,
> fork, and improve it under the repository's MIT license.

This is an independent, hardware-specific derivative of
[TargetBridge](https://github.com/swellweb/targetBridge). It is not an upstream
TargetBridge release, is not maintained or endorsed by TargetBridge's authors,
and is not affiliated with Apple. The complete lineage and third-party credits
are in [NOTICE.md](NOTICE.md).

![Lossless 5K display-appliance pipeline](docs/images/imac2017/pipeline.svg)

## Current status

The experimental path is working on the owner's exact 2017 27-inch Retina 5K
iMac (`iMac18,3`, Radeon Pro 575). The sender creates an arranged virtual
display at **2560 × 1440 HiDPI points backed by 5120 × 2880 pixels at 60 Hz**.
A direct Thunderbolt Bridge TCP test measured **17.06 Gbit/s** on this setup.

The measured fidelity run used the lossless 8-bit TBD2/DPCM path: the sender
captures BGRA and the receiver reconstructs and presents the same full-resolution
RGB raster. This is distinct from the separate raw-NV12 diagnostic, which is
4:2:0. Do not combine the two into one generic raw full-RGB transport claim.

The personal appliance now passes its core use case: one cable reconnects one
native macOS extended display automatically, with no terminal work or repeated
privacy prompt. It is still software transport rather than a passive hardware
input, and it does not claim a mathematically perfect, zero-latency 60
presentations every second. The first controlled serial/two-slot comparison
was:

| Receiver mode | Reported FPS (superseded oracle) | Reported gap p95 | p99 | Maximum | Still-valid integrity counters |
|---|---:|---:|---:|---:|---|
| Serial, one receive slot | 58.718 | 19.6 ms | 34.9 ms | 122 ms | 0 malformed, queue drops, renderer failures, GPU-command errors, or admission drops |
| Bounded overlap, two receive slots | **59.293** | **19.0 ms** | **34.0 ms** | **54.15 ms** | 0 malformed, queue drops, renderer failures, GPU-command errors, or admission drops |

Those early counts are superseded: that tested build counted Metal's zero
presentation timestamp as success, even though Apple defines it as not
presented or dropped. The corrected, synchronized five-minute A/B selected the
bounded two-slot receiver: it physically presented **59.972 FPS** from a
59.983 Hz source, with one drop, 16.8 ms p99, a 33.376 ms maximum gap, and zero
integrity errors. The second fixed slot increases the receive pool from 64 MiB
to 128 MiB; it does not create an accumulating queue. See the
[corrected hardware record](docs/repro/imac-2017-5K/results/2026-08-30-v0.9-corrected-overlap-ab.md).

The recorded sustained resource runs are honest **qualified failures**, not
hidden release evidence. The first baseline measured +6.251 MiB/hour receiver
RSS. The installed v0.5/build 8 run improved that to +4.460 MiB/hour after a
1,200-second warm-up, with zero receiver heap leaks, storage growth, or thermal
warnings. Version 0.6/build 10 then reproduced a +7.363 MiB/hour post-warm-up
staircase and was stopped after 1,201 seconds. Version 0.7 removed a redundant
once-per-minute user-activity declaration and isolated a separate, bounded
ten-minute telemetry page ramp. Version 0.8/build 13 completed 3,600 seconds:
the sender, FDs, threads, disk, and thermal gates were stable, while receiver
RSS still rose +4.819 MiB/hour after 1,200 seconds. Because the securely locked
iMac completed zero presentations while both peers continued full-rate work,
v0.9 adds the explicit display-lifecycle pause/resume handshake. The installed
build-19 candidate also adds a
listener-first, probe-inert Thunderbolt HELLO wake broker, a finite sender
handoff retry shared by manual and automatic Connect, and a common-mode
heartbeat. The owner then physically observed source sleep/wake recovery and a
cable unplug/replug recovery into the same live 5K desktop. These changes
address the observed restart-while-panel-asleep and false-timeout edges without
bypassing macOS's secure login surface. The selected overlap build has a clean
five-minute active resource sample, but its one-hour active-surface RSS
qualification remains a public-release gate rather than hidden evidence.

| Area | Status |
|---|---|
| Native 2× Retina geometry | Observed: 2560 × 1440 HiDPI / 5120 × 2880 pixels at 60 Hz |
| Lossless TBD2/DPCM path | Corrected Radeon Pro 575 A/B passed; bounded two-slot mode presented 59.972 FPS from a 59.983 Hz source with one drop and zero integrity errors |
| Native Metal 2017-iMac receiver | Implemented; lifecycle fixture passes |
| Native macOS display arrangement | Working alongside the Dell and built-in display |
| Launch and privacy identity | Dedicated `com.vikiboy.imac5kdisplay.sender` identity, certificate-backed local signature, byte-verified stable-path installer, and per-user launch agents; post-restart TCC matching, first capture frame, controlled sender restart, and automatic reconnect passed for the installed build |
| Sleep and lock lifecycle | v0.9/build 19 adds an epoch-ordered receiver-surface/source-state barrier, black privacy cover, fresh-frame-before-unblank gate, capture/GPU/audio pause, and HELLO-authorized sleeping-panel wake; live source sleep/wake and physical cable unplug/replug both automatically restored the paired display. An already locked iMac still requires an ordinary unlock |
| Cursor | Foreground-only cursor contract implemented; the owner physically confirmed one cursor during the live Retina session; an already-locked iMac still requires an ordinary physical unlock |
| RAM, storage, file-descriptor, and thermal soak | v0.8 completed 3,600 seconds with flat sender RSS, threads, FDs, and disk use and no thermal warnings, but failed the receiver RSS gate at +4.819 MiB/hour after 1,200 seconds; v0.9 fixed the locked-surface work bug and its clean active five-minute sample held threads, FDs, disk, and thermal warnings flat. A one-hour v0.9 active-surface RSS verdict remains open |
| Public release | None; the GitHub repository remains private |

## What this is

The iMac does not become a passive DisplayPort monitor. It remains booted into
macOS and runs a small receiver. The MacBook creates a virtual Retina display,
captures its pixels, and sends them over IP on the direct Thunderbolt cable.
The receiver presents those pixels fullscreen on the built-in 5K panel.

That means the iMac can still run services such as SSH in the background, but
heavy work on it can compete with display latency. It also means this cannot
show the MacBook's FileVault, Recovery, or pre-login screen.

## What came from upstream, and what changed here

TargetBridge solved the product-shaped foundation: sender and receiver apps,
virtual extended and mirrored displays, Bonjour discovery, Thunderbolt Bridge
transport, encoded 5K streaming, input features, reconnect behavior, and a raw
NV12 diagnostic path.

This derivative focuses tightly on one fidelity and appliance goal. The table
is a provenance boundary, not a claim that the derivative invented inherited
work:

| Upstream foundation | Work in this derivative |
|---|---|
| Sender/receiver apps, virtual displays, H.264/HEVC streaming | Hardware-specific 2017-iMac appliance profile and integration |
| Earlier TBD2/DPCM work in PR #158 | Bounded integration, validation, telemetry, and exact-hardware A/B |
| Native-Metal receiver work in PR #174 | Radeon Pro 575 lifecycle, presentation telemetry, and terminal-failure hardening |
| General display profiles | Exact 2560 × 1440 HiDPI points → 5120 × 2880 pixels at 60 Hz gate |
| General network discovery | Pinned, fail-closed Thunderbolt Bridge selection plus a probe-inert startup listener that wakes only for a validated display HELLO |
| Interactive sender/receiver apps | Stable TCC identity, login launch agents, and appliance power lifecycle |
| General receiver window | Quiet appliance states and presentation-confirmed reconnect handoff |
| General cursor/input modes | Foreground cursor contract and duplicate-local-cursor suppression; physical one-cursor acceptance passed |
| Default macOS idle behavior | Backed-up, reversible screen-saver idle policy plus optional, separately reversible screen-lock change; secure lock remains authoritative |
| Existing reconnect foundation | Six-attempt pre-profile broker handoff shared by manual/automatic Connect, plus a common-mode parked-session heartbeat |
| Broad upstream documentation | Hardware-specific reproduction evidence and resource acceptance gates |

This work also integrates and hardens earlier lossless-codec work by Aykut
Alpgiray Ates and native-Metal receiver work by Betafer. It does not claim those
inventions. Exact pull requests and commits are recorded in
[NOTICE.md](NOTICE.md) and the [engineering account](docs/blog/imac-2017-5k-software-display.md).

## Reproduce the setup

Use the hardware-specific instructions rather than upstream release downloads:

1. Read the [2017 iMac overview](docs/iMac-2017-5K.md).
2. Follow the [build, install, verification, and rollback guide](docs/repro/imac-2017-5K/README.md).
3. Grant Screen Recording only after the sender is installed at its stable path.
4. Verify a true Thunderbolt Bridge path and the exact Retina point/pixel pair.
5. Re-run the same serial/overlap commands and the final-candidate resource soak.
6. Physically unlock an iMac session that was already locked before judging
   foreground cursor behavior; do not count automated cursor tests as human
   acceptance. A black iMac screen with only its local cursor in this state is
   the authoritative macOS secure-login layer covering an otherwise live
   receiver, not proof that the Thunderbolt stream stopped. The app does not
   bypass that security boundary; unlock the iMac once and it will reclaim the
   receiver surface.

The sender keeps the inherited `TargetBridge` executable/product name for
source compatibility, but the personal derivative now has its own stable
`com.vikiboy.imac5kdisplay.sender` bundle identity and visible **iMac 5K
Display Sender** name. That one-time identity migration intentionally happens
before final Screen Recording approval. The installed sender is signed with the
owner's private, dedicated local Code Signing certificate, so rebuilt versions
retain one certificate-backed designated requirement instead of changing to a
new ad-hoc `cdhash`. The private key remains in a dedicated local keychain; this
does not publish, notarize, or distribute the app.

macOS's Screen & System Audio Recording pane currently labels the row
**TargetBridge** because it reads the inherited product name rather than the
visible display name. The project-owned 5K monitor icon and the exact
`~/Applications/TargetBridge 5K Sender.app` path identify the personal build.
An obsolete ad-hoc permission was removed once during the historical migration,
before the current grant existed. That is not a current setup step. Leave every
existing **TargetBridge** row alone now: both inherited and derivative rows can
share that label, and removing the wrong one can erase the working grant. Add
the exact stable app only if a clean first installation does not create a row
after its first request. Approve it once and restart the sender once. Do not
reset TCC or remove a working row. Repeated prompts are a failed identity
migration, not normal operation.

## Evidence, not marketing

The project records what was actually tested, including failures and remaining
gates. It does not reuse upstream screenshots or the inherited Italian UI
screenshots. The visual below was captured on the owner's test hardware and is
listed in the asset-provenance manifest; it is arrangement context, not cadence
or cursor proof.

![macOS arranging the project virtual display beside the Dell and built-in display](docs/blog/assets/macos-display-arrangement.png)

- Plain-language build story: [docs/blog/imac-2017-5k-software-display.md](docs/blog/imac-2017-5k-software-display.md)
- Reproduction guide and result schema: [docs/repro/imac-2017-5K/README.md](docs/repro/imac-2017-5K/README.md)
- Visual ownership and sanitization: [docs/ASSET-PROVENANCE.md](docs/ASSET-PROVENANCE.md)
- Private-to-public release gate: [docs/PUBLICATION-CHECKLIST.md](docs/PUBLICATION-CHECKLIST.md)

Raw logs, system profiles, crash reports, and unredacted screenshots are not
published because they can contain names, paths, hostnames, addresses, device
identifiers, or screen contents.

## Security and operational limits

The experimental TCP display protocol is not authenticated or encrypted. Use
it only on the trusted direct Thunderbolt link; do not expose port 54321 to an
untrusted LAN. See [SECURITY.md](SECURITY.md).

No kernel extension, firmware patch, privileged daemon, or iMac disassembly is
used. Runtime queues are bounded, frames are not written to disk, logs are
bounded, and the final acceptance includes RAM, file-descriptor, storage,
thermal, and battery measurements.

## License and credit

The repository retains the upstream MIT license and Marco Caciotti's original
copyright notice unchanged in [LICENSE](LICENSE). The derivative modifications
are offered under the same MIT terms. When redistributing this repository or a
substantial portion of it, keep the required copyright and permission notices.
See [NOTICE.md](NOTICE.md) for authorship, code provenance, and the no-endorsement
statement. See [CONTRIBUTING.md](CONTRIBUTING.md) for the fork-first,
no-support-SLA contribution posture.

Apple, MacBook Pro, iMac, Retina, and Thunderbolt are trademarks of their
respective owners.
