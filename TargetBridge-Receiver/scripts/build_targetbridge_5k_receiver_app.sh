#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
APP_DIR="${BUILD_DIR}/TargetBridge 5K Receiver.app"
EXECUTABLE_NAME="TargetBridge5KReceiver"
SOURCE_BINARY="${ROOT}/TBReceiverC/benchmark_targetbridge_raw_receiver_universal"
ICON_SOURCE="${ROOT}/TargetBridgeAssets/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
ICON_WORK="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK"' EXIT

make -C "${ROOT}/TBReceiverC" benchmark_targetbridge_raw_receiver_universal

mkdir -p "$BUILD_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$SOURCE_BINARY" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
chmod 0755 "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
mkdir -p "$APP_DIR/Contents/Resources/Legal"
cp "$REPO_ROOT/LICENSE" "$APP_DIR/Contents/Resources/Legal/LICENSE.txt"
cp "$REPO_ROOT/LICENSE" "$APP_DIR/Contents/Resources/Legal/LICENSE"
cp "$REPO_ROOT/NOTICE.md" "$APP_DIR/Contents/Resources/Legal/NOTICE.md"

mkdir -p "$ICON_WORK/TargetBridge5KReceiver.iconset"
sips -z 16 16 "$ICON_SOURCE" --out "$ICON_WORK/TargetBridge5KReceiver.iconset/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICON_WORK/TargetBridge5KReceiver.iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICON_WORK/TargetBridge5KReceiver.iconset/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SOURCE" --out "$ICON_WORK/TargetBridge5KReceiver.iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SOURCE" --out "$ICON_WORK/TargetBridge5KReceiver.iconset/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICON_WORK/TargetBridge5KReceiver.iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICON_WORK/TargetBridge5KReceiver.iconset/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICON_WORK/TargetBridge5KReceiver.iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICON_WORK/TargetBridge5KReceiver.iconset/icon_512x512.png" >/dev/null
cp "$ICON_SOURCE" "$ICON_WORK/TargetBridge5KReceiver.iconset/icon_512x512@2x.png"
iconutil -c icns "$ICON_WORK/TargetBridge5KReceiver.iconset" \
  -o "$APP_DIR/Contents/Resources/TargetBridge5KReceiver.icns"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>iMac 5K Display Appliance</string>
    <key>CFBundleExecutable</key>
    <string>TargetBridge5KReceiver</string>
    <key>CFBundleIdentifier</key>
    <string>com.targetbridge.receiver5k</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>TargetBridge5KReceiver</string>
    <key>CFBundleName</key>
    <string>iMac 5K Display Appliance</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.9</string>
    <key>CFBundleVersion</key>
    <string>16</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSBackgroundOnly</key>
    <false/>
    <key>LSMultipleInstancesProhibited</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
plutil -lint "$APP_DIR/Contents/Info.plist"
# Strip inherited quarantine/resource-fork metadata before signing so the
# verified bundle is exactly the bundle that is distributed.
xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "iMac 5K Display Appliance built: $APP_DIR"
