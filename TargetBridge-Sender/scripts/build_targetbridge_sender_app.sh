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
CODESIGN_IDENTITY="${TB_CODESIGN_IDENTITY:--}"
CODESIGN_KEYCHAIN="${TB_CODESIGN_KEYCHAIN:-}"
REQUIRE_STABLE_CODESIGN="${TB_REQUIRE_STABLE_CODESIGN:-0}"

fail() {
  print -u2 -- "$1"
  exit "${2:-1}"
}

verify_packaged_signature() {
  local app="$1"
  local signature_info requirement
  codesign --verify --deep --strict --verbose=2 "$app"
  if [[ "$REQUIRE_STABLE_CODESIGN" == 1 ]]; then
    signature_info="$(codesign -d --verbose=4 "$app" 2>&1)"
    requirement="$(codesign -d -r- "$app" 2>&1)"
    [[ "$signature_info" != *"Signature=adhoc"* ]] ||
      fail "Stable sender build was ad-hoc signed; refusing a TCC-unstable package" 65
    [[ "$requirement" == *'identifier "com.vikiboy.imac5kdisplay.sender"'* &&
       "$requirement" == *"certificate root ="* ]] ||
      fail "Stable sender build has no certificate-backed designated requirement" 65
  fi
}

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
cp "$REPO_ROOT/LICENSE" "$DEST_APP/Contents/Resources/Legal/LICENSE"
cp "$REPO_ROOT/NOTICE.md" "$DEST_APP/Contents/Resources/Legal/NOTICE.md"
echo "Cleaning extended attributes..."
xattr -cr "$DEST_APP" || true
echo "Signing sender application..."
typeset -a sign_arguments
sign_arguments=(--force --timestamp=none --sign "$CODESIGN_IDENTITY")
if [[ -n "$CODESIGN_KEYCHAIN" ]]; then
  [[ -f "$CODESIGN_KEYCHAIN" ]] || fail "Signing keychain not found: $CODESIGN_KEYCHAIN" 66
  sign_arguments+=(--keychain "$CODESIGN_KEYCHAIN")
fi
if [[ "$REQUIRE_STABLE_CODESIGN" == 1 && "$CODESIGN_IDENTITY" == - ]]; then
  fail "TB_REQUIRE_STABLE_CODESIGN=1 requires TB_CODESIGN_IDENTITY" 64
fi
codesign "${sign_arguments[@]}" "$DEST_APP"
verify_packaged_signature "$DEST_APP"
touch "$DEST_APP"

echo "iMac 5K Display Sender built: $DEST_APP"
echo "Local DerivedData: $DERIVED_DATA_DIR"
echo "Code-signing identity: $CODESIGN_IDENTITY"
