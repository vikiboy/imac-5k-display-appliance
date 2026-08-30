#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
sender_dir="${script_dir:h}"
installer="${1:-${sender_dir}/scripts/install_targetbridge_5k_sender_app.sh}"
fake_codesign="${script_dir}/fixtures/fake_codesign_requirement.zsh"
source_file="${script_dir}/fixtures/long_running_process.c"
test_root="$(mktemp -d)"
cleanup() {
  /bin/rm -rf -- "$test_root"
}
trap cleanup EXIT

export HOME="${test_root}/home"
export TB_CODESIGN_BIN="$fake_codesign"
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

root_a=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
root_b=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
print -r -- "$root_a" > "$source_app/Contents/Resources/signing-root"
print -r -- first > "$source_app/Contents/Resources/generation"
"$installer" "$source_app" "$dest_app" >/dev/null

print -r -- second > "$source_app/Contents/Resources/generation"
"$installer" "$source_app" "$dest_app" >/dev/null
[[ "$(<"$dest_app/Contents/Resources/generation")" == second ]] || exit 1

print -r -- "$root_b" > "$source_app/Contents/Resources/signing-root"
print -r -- rejected > "$source_app/Contents/Resources/generation"
if "$installer" "$source_app" "$dest_app" >/dev/null 2>&1; then
  print -u2 -- "sender installer accepted a different signing identity"
  exit 1
fi
[[ "$(<"$dest_app/Contents/Resources/generation")" == second ]] || {
  print -u2 -- "rejected signing migration changed the installed app"
  exit 1
}

export TB_ALLOW_SIGNING_IDENTITY_MIGRATION=1
print -r -- migrated > "$source_app/Contents/Resources/generation"
"$installer" "$source_app" "$dest_app" >/dev/null
[[ "$(<"$dest_app/Contents/Resources/generation")" == migrated ]] || exit 1
[[ "$(<"$dest_app/Contents/Resources/signing-root")" == "$root_b" ]] || exit 1

/bin/zsh -n "$installer" "$fake_codesign"
print -- "sender signing-identity continuity passed"
