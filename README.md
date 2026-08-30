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

The native display path is working on the owner's MacBook and 2017 iMac: macOS
creates a real arranged extended display at 2560 × 1440 logical points backed by
5120 × 2880 pixels, sends lossless 8-bit 4:4:4 Display P3 frames over
Thunderbolt Bridge, and presents them on the iMac with Metal.

The implementation and component tests are complete. Final release
qualification is still in progress: the immutable installed sender needs its
one-time macOS Screen Recording re-grant, followed by the recorded animated
5K60, reconnect, sleep/wake, and one-hour resource soak. Until those gates pass,
this repository is an engineering appliance build—not a production release or
a claim of literal zero latency.

| Area | Status |
|---|---|
| Native 2× Retina geometry | Implemented and observed on the test setup |
| Lossless 4:4:4 TBD2/DPCM path | Implemented; CPU/GPU suites pass |
| Native Metal 2017-iMac receiver | Implemented; lifecycle fixture passes |
| Native macOS display arrangement | Working alongside the Dell and built-in display |
| Automatic login/reconnect | Implemented; final unplug/sleep acceptance pending |
| Receiver idle experience | Dark native waiting surface, truthful connection states, and idle-only controls |
| RAM, storage, file-descriptor, and thermal soak | Final post-fix one-hour run pending |
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

This derivative focuses tightly on one fidelity and appliance goal:

| Upstream foundation | Work in this derivative |
|---|---|
| H.264/HEVC display streaming | Lossless TBD2/DPCM transport for crisp desktop text |
| General display profiles | Exact 2560 × 1440 points → 5120 × 2880 pixels gate |
| General network discovery | Pinned, fail-closed Thunderbolt Bridge selection |
| Native-Metal receiver prior art | Radeon Pro 575 lifecycle, buffer-reuse, and terminal-failure hardening |
| Interactive sender/receiver apps | Login launch agents, automatic reconnect, and appliance power lifecycle |
| General receiver window | Quiet appliance states and presentation-confirmed reconnect handoff |
| General cursor/input modes | One native cursor for this dedicated lossless receiver |
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
5. Run the documented live and resource gates before enabling unattended login.

The current app bundles retain some `TargetBridge` executable and bundle names
for source compatibility and stable macOS privacy identity while qualification
is underway. The repository, documentation, appliance profile, evidence, and
visible receiver waiting state are distinct. Bundle-identity migration must be
a deliberate versioned step because macOS may require Screen Recording again
when an app's path or code identity changes.

## Evidence, not marketing

The project records what was actually tested, including failures and remaining
gates. It does not reuse upstream screenshots.

![macOS arranging the iMac appliance beside the Dell and built-in display](docs/images/imac2017/native-display-picker.png)

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
