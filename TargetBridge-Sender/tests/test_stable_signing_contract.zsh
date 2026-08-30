#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
sender_dir="${script_dir:h}"
build_script="${1:-${sender_dir}/scripts/build_targetbridge_sender_app.sh}"
sign_script="${2:-${sender_dir}/scripts/sign_targetbridge_5k_sender_app.sh}"
app_installer="${3:-${sender_dir}/scripts/install_targetbridge_5k_sender_app.sh}"
agent_installer="${4:-${sender_dir}/scripts/install_targetbridge_5k_sender_launch_agent.sh}"
provision_script="${5:-${sender_dir}/scripts/provision_targetbridge_5k_signing_identity.sh}"

for required in "$build_script" "$sign_script" "$app_installer" "$agent_installer" "$provision_script"; do
  [[ -f "$required" ]] || {
    print -u2 -- "stable signing contract file missing: $required"
    exit 2
  }
  /bin/zsh -n "$required"
done

require_literal() {
  local file="$1"
  local expected="$2"
  /usr/bin/grep -Fq -- "$expected" "$file" || {
    print -u2 -- "missing stable signing contract in ${file:t}: $expected"
    exit 1
  }
}

require_literal "$build_script" 'TB_CODESIGN_IDENTITY'
require_literal "$build_script" 'TB_REQUIRE_STABLE_CODESIGN'
require_literal "$build_script" 'certificate-backed designated requirement'
require_literal "$sign_script" 'Refusing to re-sign the installed sender in place'
require_literal "$sign_script" 'set-key-partition-list'
require_literal "$sign_script" 'lock-keychain "$KEYCHAIN"'
require_literal "$provision_script" 'refusing to replace the Screen Recording identity'
require_literal "$provision_script" 'openssl.cnf'
require_literal "$provision_script" 'extendedKeyUsage = codeSigning'
require_literal "$provision_script" 'lock-keychain "$KEYCHAIN"'
require_literal "$provision_script" 'delete-keychain "$KEYCHAIN"'
require_literal "$provision_script" '/bin/chmod 0600 "$PASSWORD_FILE"'
require_literal "$sign_script" 'certificate root ='
require_literal "$app_installer" 'REQUIRE_STABLE_CODESIGN="${TB_REQUIRE_STABLE_CODESIGN:-1}"'
require_literal "$app_installer" 'LAUNCHCTL_BIN="${TB_LAUNCHCTL_BIN:-/bin/launchctl}"'
require_literal "$app_installer" '"$LAUNCHCTL_BIN" print'
require_literal "$app_installer" 'ALLOW_SIGNING_IDENTITY_MIGRATION="${TB_ALLOW_SIGNING_IDENTITY_MIGRATION:-0}"'
require_literal "$app_installer" 'source_requirement="$(stable_designated_requirement "$SOURCE_APP")"'
require_literal "$app_installer" '"$source_requirement" != "$existing_requirement"'
require_literal "$app_installer" 'refusing to invalidate the working Screen Recording grant'
require_literal "$app_installer" 'Sender is ad-hoc signed'
require_literal "$agent_installer" 'REQUIRE_STABLE_CODESIGN="${TB_REQUIRE_STABLE_CODESIGN:-1}"'
require_literal "$agent_installer" 'refusing monitor mode because Screen Recording permission would be unstable'

print -- "stable sender signing contract passed"
