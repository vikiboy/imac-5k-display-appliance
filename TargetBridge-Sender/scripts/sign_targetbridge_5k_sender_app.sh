#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_PATH="${1:-${REPO_ROOT}/build/TargetBridge.app}"
STABLE_APP="${HOME}/Applications/TargetBridge 5K Sender.app"
SIGNING_ROOT="${TB_LOCAL_SIGNING_ROOT:-${HOME}/Library/Application Support/iMac 5K Display/Signing}"
KEYCHAIN="${TB_CODESIGN_KEYCHAIN:-${SIGNING_ROOT}/iMac5KDisplaySigning.keychain-db}"
PASSWORD_FILE="${TB_CODESIGN_PASSWORD_FILE:-${SIGNING_ROOT}/keychain-password}"
CERTIFICATE_NAME="${TB_CODESIGN_CERTIFICATE_NAME:-iMac 5K Display Local Code Signing}"
SECURITY_BIN="${TB_SECURITY_BIN:-/usr/bin/security}"
CODESIGN_BIN="${TB_CODESIGN_BIN:-/usr/bin/codesign}"
PLIST_BUDDY_BIN="${TB_PLIST_BUDDY_BIN:-/usr/libexec/PlistBuddy}"
SHASUM_BIN="${TB_SHASUM_BIN:-/usr/bin/shasum}"

fail() {
  print -u2 -- "$1"
  exit "${2:-1}"
}

[[ -d "$APP_PATH" ]] || fail "Sender app not found: $APP_PATH" 66
[[ "$APP_PATH" != "$STABLE_APP" ]] ||
  fail "Refusing to re-sign the installed sender in place; sign a staged build, then install it transactionally" 64
[[ -f "$KEYCHAIN" ]] || fail "Local signing keychain not found: $KEYCHAIN" 66
[[ -f "$PASSWORD_FILE" ]] || fail "Local signing keychain password file not found: $PASSWORD_FILE" 66
[[ "$(/usr/bin/stat -f %Lp "$PASSWORD_FILE")" == 600 ]] ||
  fail "Local signing keychain password file must have mode 0600" 65

identifier="$("$PLIST_BUDDY_BIN" -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
[[ "$identifier" == com.vikiboy.imac5kdisplay.sender ]] ||
  fail "Unexpected sender bundle identifier: $identifier" 65

certificate_sha1="$(
  "$SECURITY_BIN" find-certificate -a -Z -c "$CERTIFICATE_NAME" "$KEYCHAIN" 2>/dev/null |
    /usr/bin/awk '/^SHA-1 hash: / { print $3; exit }'
)"
[[ "$certificate_sha1" =~ '^[0-9A-F]{40}$' ]] ||
  fail "Code-signing certificate not found in the dedicated keychain" 66

typeset -a original_keychains
original_keychains=("${(@f)$("$SECURITY_BIN" list-keychains -d user | /usr/bin/tr -d '"')}")
KEYCHAIN_UNLOCKED_BY_SCRIPT=0
restore_signing_keychain_state() {
  if (( KEYCHAIN_UNLOCKED_BY_SCRIPT == 1 )); then
    "$SECURITY_BIN" lock-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  fi
  "$SECURITY_BIN" list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
}
trap restore_signing_keychain_state EXIT

if (( ${original_keychains[(I)$KEYCHAIN]} == 0 )); then
  "$SECURITY_BIN" list-keychains -d user -s "$KEYCHAIN" "${original_keychains[@]}"
fi
keychain_password="$(<"$PASSWORD_FILE")"
"$SECURITY_BIN" unlock-keychain -p "$keychain_password" "$KEYCHAIN"
KEYCHAIN_UNLOCKED_BY_SCRIPT=1
"$SECURITY_BIN" set-key-partition-list \
  -S apple-tool:,apple: -s -k "$keychain_password" "$KEYCHAIN" >/dev/null

"$CODESIGN_BIN" --force --sign "$certificate_sha1" --timestamp=none "$APP_PATH"
"$CODESIGN_BIN" --verify --deep --strict --verbose=4 "$APP_PATH"
signature_info="$("$CODESIGN_BIN" -d --verbose=4 "$APP_PATH" 2>&1)"
requirement="$("$CODESIGN_BIN" -d -r- "$APP_PATH" 2>&1)"
[[ "$signature_info" != *"Signature=adhoc"* ]] ||
  fail "Local signing unexpectedly produced an ad-hoc signature" 65
[[ "$requirement" == *'identifier "com.vikiboy.imac5kdisplay.sender"'* &&
   "$requirement" == *"certificate root ="* ]] ||
  fail "Local signing did not produce a certificate-backed designated requirement" 65

restore_signing_keychain_state
KEYCHAIN_UNLOCKED_BY_SCRIPT=0
trap - EXIT

print -- "Signed private iMac 5K Display Sender: $APP_PATH"
print -- "$requirement"
print -- "Executable SHA-256: $("$SHASUM_BIN" -a 256 "$APP_PATH/Contents/MacOS/TargetBridge" | /usr/bin/awk '{print $1}')"
