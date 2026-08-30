# Attribution and derivative-work notice

## Project identity

**iMac 5K Display Appliance** is an independent, hardware-specific derivative
project maintained for Vikram Mohanty's personal 2017 27-inch 5K iMac setup.
It is not an official TargetBridge release, is not maintained or endorsed by
TargetBridge's authors, and is not affiliated with or endorsed by Apple.

The repository intentionally keeps the inherited Git history so authorship and
lineage remain inspectable. The project-facing documentation and visual assets
are separate from upstream branding. Some internal executable, protocol, and
bundle identifiers still contain `TargetBridge` for source compatibility and
stable macOS privacy behavior during qualification; that does not imply an
official upstream release.

## Upstream foundation

This work is derived from:

- **Project:** [TargetBridge](https://github.com/swellweb/targetBridge)
- **Original author and copyright holder named in the license:** Marco Caciotti
- **License:** MIT; the original notice is preserved unchanged in
  [LICENSE](LICENSE)

Upstream supplied the Sender/Receiver architecture, virtual-display modes,
Bonjour discovery, Thunderbolt Bridge and network transport, H.264/HEVC paths,
input and receiver-control features, reconnect behavior, raw NV12 diagnostics,
and the broader application structure.

## Important prior work integrated here

- Aykut Alpgiray Ates (`@aalpgiray`) developed the earlier TBD1/TBD2 lossless
  codec and GPU experiment in
  [TargetBridge PR #158](https://github.com/swellweb/targetBridge/pull/158),
  including the
  [TBD1 codec](https://github.com/swellweb/targetBridge/pull/158/commits/740c2babbd01ab3eb360c187c7cb26dc6b936076),
  [GPU decoder](https://github.com/swellweb/targetBridge/pull/158/commits/43abe4e45f80a66695d7c27d41c7cd05b2608ae3),
  [TBD2 format](https://github.com/swellweb/targetBridge/pull/158/commits/29f557602bf74d080c3fcdc5f6b4dff94ed70b9e),
  and [GPU encoder](https://github.com/swellweb/targetBridge/pull/158/commits/08bf28f6b2cf0b7f2e1f58e8b32f95e17d2850d2).
- Betafer (`@Betafer`) developed the native-Metal receiver path in
  [TargetBridge PR #174](https://github.com/swellweb/targetBridge/pull/174),
  including its
  [zero-copy path](https://github.com/swellweb/targetBridge/pull/174/commits/32bcf3dc15b56e42e84b35eebe2fe3478dc38e2b)
  and
  [validation and Display P3 work](https://github.com/swellweb/targetBridge/pull/174/commits/1d2d62cdbda3b6eccf24adfa9336a8bb53b07b77).
- Other TargetBridge contributors retain credit in the inherited Git history
  and the upstream
  [contributors list](https://github.com/swellweb/targetBridge/graphs/contributors).

## Derivative modifications

Vikram Mohanty's 2026 modifications add the 2017-iMac-specific native Retina
profile; lossless 8-bit 4:4:4 TBD2/DPCM negotiation and integration; exact
point/pixel activation checks; direct-interface selection; GPU, parser,
lifecycle, and bounded-resource hardening; appliance receiver and launch
automation; test fixtures; reproducible hardware evidence; and this independent
documentation and visual identity.

Copyright in upstream work remains with its respective holders. Copyright in
new contributions remains with their respective contributors. The derivative
modifications in this repository are offered under the same MIT terms as the
upstream foundation.

## Redistribution

The MIT license permits use, copying, modification, merging, publication,
distribution, sublicensing, and sale subject to its notice-preservation
condition and warranty disclaimer. Keep [LICENSE](LICENSE) with copies or
substantial portions of this software and preserve relevant attribution.

The project name and presentation do not grant permission to imply that a fork
or binary is an official TargetBridge or Apple release. Fork maintainers should
use their own identity, support policy, screenshots, credentials, and release
signing.
