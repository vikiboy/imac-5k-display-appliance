#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_APP="${1:-${REPO_ROOT}/build/TargetBridge.app}"
DEST_APP="${2:-${HOME}/Applications/TargetBridge 5K Sender.app}"
DEST_PARENT="${DEST_APP:h}"
EXPECTED_EXECUTABLE="${DEST_APP}/Contents/MacOS/TargetBridge"
CODESIGN_BIN="${TB_CODESIGN_BIN:-/usr/bin/codesign}"
DITTO_BIN="${TB_DITTO_BIN:-/usr/bin/ditto}"
XATTR_BIN="${TB_XATTR_BIN:-/usr/bin/xattr}"
LIPO_BIN="${TB_LIPO_BIN:-/usr/bin/lipo}"
PLIST_BUDDY_BIN="${TB_PLIST_BUDDY_BIN:-/usr/libexec/PlistBuddy}"
SHASUM_BIN="${TB_SHASUM_BIN:-/usr/bin/shasum}"
LSREGISTER_BIN="${TB_LSREGISTER_BIN:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
LAUNCHCTL_BIN="${TB_LAUNCHCTL_BIN:-/bin/launchctl}"
LABEL="com.vikiboy.imac5kdisplay.sender"
ENABLED_PATH="${HOME}/Library/Application Support/TargetBridge/Sender/enabled"
REQUIRE_STABLE_CODESIGN="${TB_REQUIRE_STABLE_CODESIGN:-1}"
ALLOW_SIGNING_IDENTITY_MIGRATION="${TB_ALLOW_SIGNING_IDENTITY_MIGRATION:-0}"

fail() {
  print -u2 -- "$1"
  exit "${2:-1}"
}

stable_designated_requirement() {
  local app="$1"
  "$CODESIGN_BIN" -d -r- "$app" 2>&1 |
    /usr/bin/awk '/^designated => / { sub(/^designated => /, ""); print; exit }'
}

verify_identity() {
  local app="$1"
  local identifier executable signature_info requirement
  "$CODESIGN_BIN" --verify --deep --strict "$app"
  identifier="$("$PLIST_BUDDY_BIN" -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
  executable="$("$PLIST_BUDDY_BIN" -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$identifier" == com.vikiboy.imac5kdisplay.sender && "$executable" == TargetBridge ]] ||
    fail "Sender identity mismatch: $app" 65
  [[ -x "$app/Contents/MacOS/TargetBridge" ]] ||
    fail "Sender executable is missing: $app" 65
  "$LIPO_BIN" "$app/Contents/MacOS/TargetBridge" -verify_arch arm64 x86_64
  if [[ "$REQUIRE_STABLE_CODESIGN" == 1 ]]; then
    signature_info="$("$CODESIGN_BIN" -d --verbose=4 "$app" 2>&1)"
    requirement="$("$CODESIGN_BIN" -d -r- "$app" 2>&1)"
    [[ "$signature_info" != *"Signature=adhoc"* ]] ||
      fail "Sender is ad-hoc signed; this would invalidate Screen Recording permission after a rebuild" 65
    [[ "$requirement" == *'identifier "com.vikiboy.imac5kdisplay.sender"'* &&
       "$requirement" == *"certificate root ="* ]] ||
      fail "Sender lacks a stable certificate-backed designated requirement" 65
  fi
}

matching_sender_pids() {
  /bin/ps -ww -axo pid=,command= 2>/dev/null | /usr/bin/awk \
    -v expected="$EXPECTED_EXECUTABLE" '
      match($0, /^[[:space:]]*[0-9]+[[:space:]]+/) {
        prefix = substr($0, 1, RLENGTH)
        pid = prefix
        gsub(/[[:space:]]/, "", pid)
        command = substr($0, RLENGTH + 1)
        if (command == expected || index(command, expected " ") == 1) print pid
      }
    '
}

clear_quarantine() {
  local app="$1"
  "$XATTR_BIN" -dr com.apple.quarantine "$app" 2>/dev/null || true
}

for tool in "$CODESIGN_BIN" "$DITTO_BIN" "$XATTR_BIN" "$LIPO_BIN" "$PLIST_BUDDY_BIN" "$SHASUM_BIN" "$LSREGISTER_BIN" "$LAUNCHCTL_BIN"; do
  [[ -x "$tool" ]] || fail "Required installation tool is unavailable: $tool"
done
[[ "$ALLOW_SIGNING_IDENTITY_MIGRATION" == 0 || "$ALLOW_SIGNING_IDENTITY_MIGRATION" == 1 ]] ||
  fail "TB_ALLOW_SIGNING_IDENTITY_MIGRATION must be 0 or 1" 64
[[ -d "$SOURCE_APP" ]] || fail "Built sender app not found: $SOURCE_APP"
[[ "$DEST_APP" == "${HOME}/Applications/"*.app ]] ||
  fail "Personal install destination must be an app inside ~/Applications" 64
[[ ! -L "$DEST_APP" ]] || fail "Refusing to replace a symbolic-link destination" 64
[[ -z "$(matching_sender_pids)" ]] ||
  fail "Quit the installed iMac 5K Display Sender before replacing it" 73
[[ ! -e "$ENABLED_PATH" ]] ||
  fail "Disable automatic monitor mode before replacing the sender app" 73
if "$LAUNCHCTL_BIN" print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then
  fail "Unload the sender launch agent before replacing the app" 73
fi

verify_identity "$SOURCE_APP"
if [[ "$REQUIRE_STABLE_CODESIGN" == 1 && -e "$DEST_APP" ]]; then
  [[ -d "$DEST_APP" ]] || fail "Existing sender destination is not an app bundle" 65
  existing_identifier="$("$PLIST_BUDDY_BIN" -c 'Print :CFBundleIdentifier' "$DEST_APP/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$existing_identifier" == com.vikiboy.imac5kdisplay.sender ]] ||
    fail "Existing sender destination has a different bundle identity" 65
  source_requirement="$(stable_designated_requirement "$SOURCE_APP")"
  existing_requirement="$(stable_designated_requirement "$DEST_APP" || true)"
  if [[ -z "$source_requirement" || "$source_requirement" != "$existing_requirement" ]]; then
    [[ "$ALLOW_SIGNING_IDENTITY_MIGRATION" == 1 ]] ||
      fail "Sender signing identity changed; refusing to invalidate the working Screen Recording grant. Set TB_ALLOW_SIGNING_IDENTITY_MIGRATION=1 only for an intentional one-time migration." 65
  fi
fi
SOURCE_EXECUTABLE_HASH="$("$SHASUM_BIN" -a 256 "$SOURCE_APP/Contents/MacOS/TargetBridge" | /usr/bin/awk '{print $1}')"
/bin/mkdir -p "$DEST_PARENT"
WORK_DIR="$(/usr/bin/mktemp -d "${DEST_PARENT}/.imac5k-sender-install.XXXXXX")"
STAGED_APP="${WORK_DIR}/TargetBridge 5K Sender.app"
BACKUP_APP="${WORK_DIR}/previous.app"
HAD_PREVIOUS=0
DESTINATION_MUTATED=0
COMMITTED=0

cleanup() {
  local exit_status=$?
  set +e
  trap - EXIT
  if (( COMMITTED == 0 && DESTINATION_MUTATED == 1 )); then
    [[ ! -e "$DEST_APP" ]] || /bin/rm -rf -- "$DEST_APP"
    if (( HAD_PREVIOUS == 1 )) && [[ -e "$BACKUP_APP" ]]; then
      /bin/mv "$BACKUP_APP" "$DEST_APP"
    fi
    print -u2 -- "Sender app installation failed; the previous app was restored."
  fi
  [[ ! -e "$WORK_DIR" ]] || /bin/rm -rf -- "$WORK_DIR"
  return "$exit_status"
}
trap cleanup EXIT

# The source is only a build artifact. Never ask LaunchServices to open this
# staged copy. Screen Recording permission must be established once against the
# stable per-user destination, not against disposable test/build paths.
"$DITTO_BIN" "$SOURCE_APP" "$STAGED_APP"
clear_quarantine "$STAGED_APP"
verify_identity "$STAGED_APP"
STAGED_EXECUTABLE_HASH="$("$SHASUM_BIN" -a 256 "$STAGED_APP/Contents/MacOS/TargetBridge" | /usr/bin/awk '{print $1}')"
[[ "$STAGED_EXECUTABLE_HASH" == "$SOURCE_EXECUTABLE_HASH" ]] ||
  fail "Staged sender bytes differ from the verified build" 74

if [[ -e "$DEST_APP" ]]; then
  /bin/mv "$DEST_APP" "$BACKUP_APP"
  HAD_PREVIOUS=1
fi
DESTINATION_MUTATED=1
/bin/mv "$STAGED_APP" "$DEST_APP"

# Register only the verified stable copy. `com.apple.provenance` is legitimate
# macOS metadata and is deliberately preserved; it did not cause the overnight
# launch-constraint reports.
verify_identity "$DEST_APP"
INSTALLED_EXECUTABLE_HASH="$("$SHASUM_BIN" -a 256 "$DEST_APP/Contents/MacOS/TargetBridge" | /usr/bin/awk '{print $1}')"
[[ "$INSTALLED_EXECUTABLE_HASH" == "$SOURCE_EXECUTABLE_HASH" ]] ||
  fail "Installed sender bytes differ from the verified build" 74
"$LSREGISTER_BIN" -f "$DEST_APP"
verify_identity "$DEST_APP"
COMMITTED=1

print -- "Installed personal iMac 5K Display Sender: $DEST_APP"
print -- "Executable SHA-256: $INSTALLED_EXECUTABLE_HASH"
print -- "The app was not launched. Open this stable copy once to grant Screen Recording, then enable automatic monitor mode."
