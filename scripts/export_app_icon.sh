#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MASTER="$REPO_ROOT/assets/imac5k-display-appliance-icon.svg"
SENDER_CATALOG="$REPO_ROOT/TargetBridge-Sender/TargetBridgeSupport/Assets.xcassets/AppIcon.appiconset"
RECEIVER_CATALOG="$REPO_ROOT/TargetBridge-Receiver/TargetBridgeAssets/Assets.xcassets/AppIcon.appiconset"
ICON_WORK_DIR="$(mktemp -d /tmp/imac5k-app-icon.XXXXXX)"

cleanup() {
  rm -rf "$ICON_WORK_DIR"
}
trap cleanup EXIT

test -f "$MASTER"
command -v qlmanage >/dev/null
command -v sips >/dev/null

qlmanage -t -s 1024 -o "$ICON_WORK_DIR" "$MASTER" >/dev/null 2>&1
RENDERED_MASTER="$ICON_WORK_DIR/$(basename "$MASTER").png"
test -f "$RENDERED_MASTER"

for catalog in "$SENDER_CATALOG" "$RECEIVER_CATALOG"; do
  test -f "$catalog/Contents.json"
  for size in 16 32 64 128 256 512 1024; do
    sips -z "$size" "$size" "$RENDERED_MASTER" \
      --out "$catalog/icon_${size}.png" >/dev/null
  done
done

echo "Exported the original appliance icon to both macOS asset catalogs."
