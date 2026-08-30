#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
sender_dir="${script_dir:h}"
installer="${1:-${sender_dir}/scripts/install_targetbridge_5k_sender_launch_agent.sh}"
uninstaller="${2:-${sender_dir}/scripts/uninstall_targetbridge_5k_sender_launch_agent.sh}"
fake_defaults="${script_dir}/fixtures/fake_defaults.zsh"
fake_launchctl="${script_dir}/fixtures/fake_launchctl.zsh"

for required in "$installer" "$uninstaller" "$fake_defaults" "$fake_launchctl"; do
  [[ -x "$required" ]] || {
    print -u2 -- "sender sleep preference test failed: not executable: $required"
    exit 1
  }
done

test_root="$(mktemp -d)"
cleanup() {
  /bin/rm -rf -- "$test_root"
}
trap cleanup EXIT

export HOME="${test_root}/home"
export TB_FAKE_DEFAULTS_STATE_DIR="${test_root}/defaults"
export TB_DEFAULTS_BIN="$fake_defaults"
export TB_LAUNCHCTL_BIN="$fake_launchctl"

app_path="${HOME}/Applications/TargetBridge 5K Sender.app"
executable_path="${app_path}/Contents/MacOS/TargetBridge"
mkdir -p "${executable_path:h}" "$TB_FAKE_DEFAULTS_STATE_DIR"
touch "$executable_path"
chmod +x "$executable_path"

domain="com.targetbridge.sender"
key="fd.tbdisplaysender.preventDisplaySleep"
backup="${HOME}/Library/Application Support/TargetBridge/Sender/prevent-display-sleep.original"

read_pref() {
  "$fake_defaults" read "$domain" "$key"
}
write_pref() {
  "$fake_defaults" write "$domain" "$key" -bool "$1"
}
delete_pref() {
  "$fake_defaults" delete "$domain" "$key"
}
run_install() {
  "$installer" "$app_path" >/dev/null
}
run_uninstall() {
  "$uninstaller" >/dev/null
}

# An absent original is represented explicitly, survives reinstall, and is
# restored as absence only when the appliance-owned false value is unchanged.
run_install
[[ "$(<"$backup")" == absent && "$(read_pref)" == 0 ]] || exit 1
run_install
[[ "$(<"$backup")" == absent && "$(read_pref)" == 0 ]] || exit 1
run_uninstall
[[ ! -e "$backup" ]] || exit 1
if read_pref >/dev/null 2>&1; then exit 1; fi

# Both explicit Boolean originals are restored exactly.
for original in 0 1; do
  write_pref "$original"
  run_install
  [[ "$(<"$backup")" == "$original" && "$(read_pref)" == 0 ]] || exit 1
  run_uninstall
  [[ "$(read_pref)" == "$original" && ! -e "$backup" ]] || exit 1
done

# A later user override wins over the saved value.
write_pref 0
run_install
write_pref 1
run_uninstall
[[ "$(read_pref)" == 1 && ! -e "$backup" ]] || exit 1

# Deleting the managed preference is also a user override and remains absent.
write_pref 1
run_install
delete_pref
run_uninstall
[[ ! -e "$backup" ]] || exit 1
if read_pref >/dev/null 2>&1; then exit 1; fi

# Corrupt recovery metadata fails closed in both directions.
mkdir -p "${backup:h}"
print -r -- corrupt > "$backup"
write_pref 1
if run_install 2>/dev/null; then exit 1; fi
[[ "$(read_pref)" == 1 && "$(<"$backup")" == corrupt ]] || exit 1
if run_uninstall 2>/dev/null; then exit 1; fi
[[ "$(read_pref)" == 1 && "$(<"$backup")" == corrupt ]] || exit 1

/bin/zsh -n "$installer" "$uninstaller" "$fake_defaults" "$fake_launchctl"
print -- "sender display-sleep preference lifecycle passed"
