#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
DERIVED_DATA_DIR="${ROOT}/.build/DerivedData"
BUILD_DIR="${DERIVED_DATA_DIR}/Build/Products/Release"
SOURCE_APP="${BUILD_DIR}/TargetBridge.app"
DEST_DIR="${REPO_ROOT}/build"
DEST_APP="${DEST_DIR}/TargetBridge.app"

cd "$ROOT"

# The checked-in project is the reproducible build input. Do not silently
# regenerate it based on whether a developer happens to have xcodegen in PATH;
# project regeneration is a separate, deliberate maintenance step.
echo "Using the checked-in TargetBridge.xcodeproj"

xcodebuild \
  -scheme TBDisplaySender \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p "$DEST_DIR"
rm -rf "$DEST_APP"
ditto "$SOURCE_APP" "$DEST_APP"
mkdir -p "$DEST_APP/Contents/Resources/Legal"
cp "$REPO_ROOT/LICENSE" "$DEST_APP/Contents/Resources/Legal/LICENSE.txt"
cp "$REPO_ROOT/NOTICE.md" "$DEST_APP/Contents/Resources/Legal/NOTICE.md"
echo "Cleaning extended attributes..."
xattr -cr "$DEST_APP" || true
echo "Signing sender application..."
codesign --force --deep --sign - "$DEST_APP"
codesign --verify --deep --strict --verbose=2 "$DEST_APP"
touch "$DEST_APP"

echo "iMac 5K Display Sender built: $DEST_APP"
echo "Local DerivedData: $DERIVED_DATA_DIR"
