# Visual asset provenance

This manifest prevents upstream branding, private device data, and ambiguous
image ownership from quietly entering project-facing documentation or builds.

| Asset | Source and ownership | Processing | Intended use |
|---|---|---|---|
| `docs/images/imac2017/pipeline.svg` | Original diagram authored for this derivative by Vikram Mohanty's project | Vector primitives only; no embedded image, font, URL, or metadata | Architecture documentation |
| `docs/images/imac2017/retina-geometry.svg` | Original diagram authored for this derivative by Vikram Mohanty's project | Vector primitives only; no embedded image, font, URL, or metadata | Retina point/pixel explanation |
| `docs/images/imac2017/native-display-picker.png` | Captured on project-owned test hardware for this derivative | Cropped and sanitized; no name, avatar, hostname, IP address, serial number, or synthetic display pixels; metadata limited to ordinary image dimensions/screenshot markers | Current native macOS arrangement evidence |
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
