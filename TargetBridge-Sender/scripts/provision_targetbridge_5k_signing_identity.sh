#!/bin/zsh
set -euo pipefail

SIGNING_ROOT="${TB_LOCAL_SIGNING_ROOT:-${HOME}/Library/Application Support/iMac 5K Display/Signing}"
KEYCHAIN="${TB_CODESIGN_KEYCHAIN:-${SIGNING_ROOT}/iMac5KDisplaySigning.keychain-db}"
PASSWORD_FILE="${TB_CODESIGN_PASSWORD_FILE:-${SIGNING_ROOT}/keychain-password}"
CERTIFICATE_NAME="${TB_CODESIGN_CERTIFICATE_NAME:-iMac 5K Display Local Code Signing}"
SECURITY_BIN="${TB_SECURITY_BIN:-/usr/bin/security}"
OPENSSL_BIN="${TB_OPENSSL_BIN:-/usr/bin/openssl}"

fail() {
  print -u2 -- "$1"
  exit "${2:-1}"
}

for tool in "$SECURITY_BIN" "$OPENSSL_BIN"; do
  [[ -x "$tool" ]] || fail "Required signing-provisioning tool is unavailable: $tool" 66
done
[[ ! -e "$KEYCHAIN" && ! -e "$PASSWORD_FILE" ]] ||
  fail "A signing identity already exists; refusing to replace the Screen Recording identity" 73

/bin/mkdir -p "$SIGNING_ROOT"
/bin/chmod 0700 "$SIGNING_ROOT"
WORK_DIR="$(/usr/bin/mktemp -d "${SIGNING_ROOT}/.provision.XXXXXX")"
CONFIG="${WORK_DIR}/openssl.cnf"
PRIVATE_KEY="${WORK_DIR}/private-key.pem"
CERTIFICATE="${WORK_DIR}/certificate.pem"
PKCS12="${WORK_DIR}/identity.p12"
PKCS12_PASSWORD_FILE="${WORK_DIR}/pkcs12-password"
CREATED_KEYCHAIN=0
cleanup() {
  local exit_status=$?
  set +e
  trap - EXIT
  "$SECURITY_BIN" lock-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  if (( exit_status != 0 && CREATED_KEYCHAIN == 1 )); then
    "$SECURITY_BIN" delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    [[ ! -e "$PASSWORD_FILE" ]] || /bin/unlink "$PASSWORD_FILE"
  fi
  [[ ! -e "$WORK_DIR" ]] || /bin/rm -rf -- "$WORK_DIR"
  return "$exit_status"
}
trap cleanup EXIT

# Keep the private key and packaging password only inside this 0700 temporary
# directory. Neither value is printed, committed, or added to the login keychain.
"$OPENSSL_BIN" rand -hex 32 > "$PASSWORD_FILE"
/bin/chmod 0600 "$PASSWORD_FILE"
"$OPENSSL_BIN" rand -hex 32 > "$PKCS12_PASSWORD_FILE"
/bin/chmod 0600 "$PKCS12_PASSWORD_FILE"

print -r -- '[req]
distinguished_name = subject
x509_extensions = code_signing
prompt = no

[subject]
CN = iMac 5K Display Local Code Signing
O = Personal Local Development

[code_signing]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash' > "$CONFIG"

"$OPENSSL_BIN" req -new -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
  -config "$CONFIG" -keyout "$PRIVATE_KEY" -out "$CERTIFICATE"
"$OPENSSL_BIN" pkcs12 -export -name "$CERTIFICATE_NAME" \
  -inkey "$PRIVATE_KEY" -in "$CERTIFICATE" -out "$PKCS12" \
  -passout "file:${PKCS12_PASSWORD_FILE}"

keychain_password="$(<"$PASSWORD_FILE")"
pkcs12_password="$(<"$PKCS12_PASSWORD_FILE")"
"$SECURITY_BIN" create-keychain -p "$keychain_password" "$KEYCHAIN"
CREATED_KEYCHAIN=1
"$SECURITY_BIN" import "$PKCS12" -k "$KEYCHAIN" -P "$pkcs12_password" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
"$SECURITY_BIN" set-key-partition-list -S apple-tool:,apple: -s \
  -k "$keychain_password" "$KEYCHAIN" >/dev/null
"$SECURITY_BIN" lock-keychain "$KEYCHAIN"

print -- "Created private local signing identity in: $KEYCHAIN"
print -- "The password file is mode 0600 and was not printed. Back up the entire signing directory securely; replacing it requires a new Screen Recording grant."
