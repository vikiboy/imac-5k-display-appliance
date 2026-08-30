#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
sender_dir="${script_dir:h}"
installer="${1:-${sender_dir}/scripts/install_targetbridge_5k_sender_app.sh}"
source_file="${script_dir}/fixtures/long_running_process.c"
test_root="$(mktemp -d)"
cleanup() {
  /bin/rm -rf -- "$test_root"
}
trap cleanup EXIT

export HOME="${test_root}/home"
export TB_LSREGISTER_BIN=/usr/bin/true
export TB_LAUNCHCTL_BIN=/usr/bin/false
source_app="${test_root}/source.app"
dest_app="${HOME}/Applications/TargetBridge 5K Sender.app"
mkdir -p "$source_app/Contents/MacOS" "$source_app/Contents/Resources"

clang_path="$(xcrun --find clang)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
"$clang_path" -isysroot "$sdk_path" -arch arm64 -arch x86_64 -Os \
  "$source_file" -o "$source_app/Contents/MacOS/TargetBridge"
plist="$source_app/Contents/Info.plist"
plutil -create xml1 "$plist"
plutil -insert CFBundleIdentifier -string com.vikiboy.imac5kdisplay.sender "$plist"
plutil -insert CFBundleExecutable -string TargetBridge "$plist"
plutil -insert CFBundlePackageType -string APPL "$plist"
print -r -- first > "$source_app/Contents/Resources/generation"
/usr/bin/codesign --force --deep --sign - "$source_app"
/usr/bin/xattr -w com.apple.quarantine '0081;personal-test;Codex;' "$source_app"

if "$installer" "$source_app" "$dest_app" >/dev/null 2>&1; then
  print -u2 -- "local sender installer accepted an ad-hoc sender by default"
  exit 1
fi
export TB_REQUIRE_STABLE_CODESIGN=0
"$installer" "$source_app" "$dest_app" >/dev/null
/usr/bin/codesign --verify --deep --strict "$dest_app"
/usr/bin/lipo "$dest_app/Contents/MacOS/TargetBridge" -verify_arch arm64 x86_64
[[ "$(<"$dest_app/Contents/Resources/generation")" == first ]] || exit 1
if /usr/bin/xattr -lr "$dest_app" 2>/dev/null | /usr/bin/grep -q 'com\.apple\.quarantine'; then
  print -u2 -- "local sender installer retained quarantine metadata"
  exit 1
fi

print -r -- second > "$source_app/Contents/Resources/generation"
/usr/bin/codesign --force --deep --sign - "$source_app"
"$installer" "$source_app" "$dest_app" >/dev/null
[[ "$(<"$dest_app/Contents/Resources/generation")" == second ]] || exit 1

plutil -replace CFBundleIdentifier -string invalid.sender "$source_app/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$source_app"
before_hash="$(/usr/bin/shasum -a 256 "$dest_app/Contents/MacOS/TargetBridge")"
if "$installer" "$source_app" "$dest_app" >/dev/null 2>&1; then
  print -u2 -- "local sender installer accepted an invalid source identity"
  exit 1
fi
after_hash="$(/usr/bin/shasum -a 256 "$dest_app/Contents/MacOS/TargetBridge")"
[[ "$before_hash" == "$after_hash" ]] || exit 1
if find "$HOME/Applications" -maxdepth 1 -name '.imac5k-sender-install.*' | /usr/bin/grep -q .; then
  print -u2 -- "local sender installer left a staging directory"
  exit 1
fi

/bin/zsh -n "$installer"
print -- "local personal sender app installer passed"
