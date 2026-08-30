# Documentation map

This repository preserves TargetBridge's broader documentation as part of the
MIT-licensed source lineage, but the 2017-iMac appliance has a deliberately
narrower contract.

## Authoritative for this appliance

- [`iMac-2017-5K.md`](iMac-2017-5K.md) — what the setup is and is not;
- [`repro/imac-2017-5K/README.md`](repro/imac-2017-5K/README.md) — exact build,
  installation, rollback, and acceptance procedure;
- [`blog/imac-2017-5k-software-display.md`](blog/imac-2017-5k-software-display.md)
  — plain-language engineering account and analogical reasoning;
- [`ASSET-PROVENANCE.md`](ASSET-PROVENANCE.md) — ownership and sanitization of
  project visuals;
- [`PUBLICATION-CHECKLIST.md`](PUBLICATION-CHECKLIST.md) — gates before any
  deliberate change from private to public.
- [`research/lossless-changed-tiles.md`](research/lossless-changed-tiles.md) —
  concise phase-two decision and release gates for improving cadence without
  synthesizing pixels.
- [`research/changed-region-protocol.md`](research/changed-region-protocol.md) —
  detailed retained-framebuffer protocol, failure recovery, resource bounds,
  and analogical evidence behind that phase-two decision.
- [`research/5k60-cadence.md`](research/5k60-cadence.md) — primary-source
  analogies, the two-slot experiment, honest 5K60 terminology, and measurable
  release gates.
- [`repro/imac-2017-5K/results/2026-08-30-serial-overlap-ab.md`](repro/imac-2017-5K/results/2026-08-30-serial-overlap-ab.md)
  — exact-hardware cadence A/B, direct-link result, limitations, and commands.
- [`repro/imac-2017-5K/results/2026-08-30-v0.5-resource-soak.md`](repro/imac-2017-5K/results/2026-08-30-v0.5-resource-soak.md)
  — completed one-hour resource run, its strict RSS qualification failure,
  and why it is not release proof.
- [`repro/imac-2017-5K/results/2026-08-30-v0.6-resource-soak.md`](repro/imac-2017-5K/results/2026-08-30-v0.6-resource-soak.md)
  — early qualified failure that isolated the redundant one-minute power-call
  cadence now removed from version 0.7.
- [`repro/imac-2017-5K/results/2026-08-30-v0.7-resource-soak.md`](repro/imac-2017-5K/results/2026-08-30-v0.7-resource-soak.md)
  — perturbed diagnostic run that separated the power-call fix from bounded
  lazy telemetry-page commitment; it is not release evidence.
- [`repro/imac-2017-5K/results/2026-08-30-v0.8-resource-soak.md`](repro/imac-2017-5K/results/2026-08-30-v0.8-resource-soak.md)
  — completed one-hour qualified failure: flat disk/thread/FD behavior, strict
  receiver RSS failure, and the locked-surface finding that motivated v0.9's
  explicit display lifecycle.
- [`repro/imac-2017-5K/results/2026-08-30-v0.9-lifecycle-candidate.md`](repro/imac-2017-5K/results/2026-08-30-v0.9-lifecycle-candidate.md)
  — exact staged/installed hashes, lifecycle hardening, complete component
  results, live frame-free receiver handshake, and the remaining paired
  physical acceptance matrix.

## Inherited upstream reference

Files such as `Features.md`, `Hardware.md`, `Testing.md`, `Automation.md`, the
translated Quick Starts, and translation guidance describe general
TargetBridge behavior. They are retained for provenance and can still be useful
for the inherited application, but they do not override the appliance-specific
fidelity, Thunderbolt-only, security, or hardware acceptance gates above.

For the original project and its current documentation, use
[swellweb/targetBridge](https://github.com/swellweb/targetBridge). This
repository is an independent personal derivative, not an upstream release.
