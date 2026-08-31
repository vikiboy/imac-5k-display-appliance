# Visual asset provenance

This manifest prevents upstream branding, private device data, and ambiguous
image ownership from quietly entering project-facing documentation or builds.

| Asset | Source and ownership | Processing | Intended use |
|---|---|---|---|
| `docs/blog/assets/software-display-hero-handdrawn.png` | Original explanatory illustration generated for this derivative with OpenAI ImageGen on 2026-08-31; commissioned by Vikram Mohanty's project | Generated from the recorded project prompt; SHA-256 `5c480c6ac4a9d1f5e6773629584ec5a482568cd8bc9aadd177ce9989b2ed6751`; no upstream visual or test capture used | Blog hero only; **not test evidence** |
| `docs/blog/assets/software-display-hero-handdrawn.prompt.md` | Project-authored generation record for the hero above | Stores the exact prompt, tool, date, and output hash | Reproducibility and generated-asset disclosure |
| `docs/blog/assets/problem-to-system-handdrawn.svg` | Original deterministic diagram authored for this derivative | Vector primitives and system font stack only; no embedded image, remote font, URL, or metadata | Explains the implemented four-stage pipeline with exact dimensions and measured link throughput |
| `docs/blog/assets/bounded-overlap-handdrawn.svg` | Original deterministic diagram authored for this derivative | Vector primitives and system font stack only; no embedded image, remote font, URL, or metadata | Explains the measured serial-versus-two-slot cadence change |
| `docs/blog/assets/analogy-transfer-handdrawn.svg` | Original deterministic diagram authored for this derivative | Vector primitives and system font stack only; no embedded image, remote font, URL, or metadata | Maps thin-client, bounded-real-time, and control-plane analogies to implemented decisions |
| `docs/blog/assets/frontier-map-handdrawn.svg` | Original deterministic diagram authored for this derivative | Vector primitives and system font stack only; no embedded image, remote font, URL, or metadata | Separates upstream foundation, the remaining 2017-specific gap, analogical transfer, derivative changes, measured results, and open limits |
| `docs/images/imac2017/pipeline.svg` | Original diagram authored for this derivative by Vikram Mohanty's project | Vector primitives only; no embedded image, font, URL, or metadata | Architecture documentation |
| `docs/images/imac2017/retina-geometry.svg` | Original diagram authored for this derivative by Vikram Mohanty's project | Vector primitives only; no embedded image, font, URL, or metadata | Retina point/pixel explanation |
| `docs/images/imac2017/native-display-picker.png` | Captured on project-owned test hardware for this derivative | Cropped and sanitized; no name, avatar, hostname, IP address, serial number, or synthetic display pixels; metadata limited to ordinary image dimensions/screenshot markers | Superseded arrangement context retained for provenance; no current Markdown reference |
| `docs/blog/assets/macos-display-arrangement.png` | Privacy-cropped copy of the owner's System Settings capture on project hardware | No user name, hostname, address, serial number, or upstream branding; PNG metadata inspected locally | Shows `TB Extend`, Dell, and built-in display coexist in native macOS arrangement; not cadence or output-fidelity proof |
| `docs/blog/assets/native-retina-motion-source.png` | Owner-captured MacBook view of this project's motion target on its 5120 × 2880 virtual display | PNG metadata inspected locally; contains only the project test target and ordinary macOS/app chrome | Documents source raster, grid, colors, text, and changing tick only; **not an iMac receiver-output screenshot** |
| `assets/imac5k-display-appliance-icon.svg` | Original vector master authored for this derivative | Exported mechanically by `scripts/export_app_icon.sh` to the Sender and Receiver AppIcon catalogs at required macOS sizes | Application identity |
| `TargetBridge-Sender/TargetBridgeSupport/Assets.xcassets/AppIcon.appiconset/icon_{16,32,64,128,256,512,1024}.png` | Generated from the original SVG master above | Exact deterministic output of `scripts/export_app_icon.sh`; filenames and dimensions match the macOS asset catalog | Packaged Sender icon |
| `TargetBridge-Receiver/TargetBridgeAssets/Assets.xcassets/AppIcon.appiconset/icon_{16,32,64,128,256,512,1024}.png` | Generated from the original SVG master above | Exact deterministic output of `scripts/export_app_icon.sh`; filenames and dimensions match the macOS asset catalog | Packaged Receiver icon |

## Excluded upstream visuals

The derivative's current tree does not use the upstream TargetBridge connection
diagram, dashboards, Italian display screenshots, layout screenshots, Sponsor
badge, or app icon. Those files remain visible only in inherited Git history so
the development lineage stays intact. A future clean-root public export may
squash history if the release policy requires that no historical upstream
visual bytes be distributed.

## Publication checklist

Before adding or replacing a visual:

1. Record who created or captured it and on what class of hardware.
2. Use project-owned material or material with an explicit compatible license.
3. Remove names, avatars, paths, addresses, identifiers, unrelated apps, and
   hidden image metadata.
4. Do not synthesize or sharpen screenshots presented as test evidence.
5. Record any crop, redaction, recomposition, or generated element here.
6. Check that every Markdown image reference resolves and every tracked visual
   appears in this manifest.

Remote macOS screenshot tools do not capture the receiver's shielding/Metal
surface. Never label a remote capture of the underlying iMac desktop as receiver
output. Use an owner-made on-device photograph for physical-output evidence,
record its provenance here, and keep cursor acceptance separate.
