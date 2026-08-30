#!/bin/zsh
set -euo pipefail

# This lifecycle fixture is intentionally ad-hoc signed. Production appliance
# installers default to requiring a certificate-backed designated requirement.
export TB_REQUIRE_STABLE_CODESIGN=0

script_dir="${0:A:h}"
sender_dir="${script_dir:h}"
installer="${1:-${sender_dir}/scripts/install_targetbridge_5k_sender_launch_agent.sh}"
uninstaller="${2:-${sender_dir}/scripts/uninstall_targetbridge_5k_sender_launch_agent.sh}"
fake_defaults="${script_dir}/fixtures/fake_defaults.zsh"
fake_launchctl="${script_dir}/fixtures/fake_launchctl.zsh"
long_running_source="${script_dir}/fixtures/long_running_process.c"

for required in "$installer" "$uninstaller" "$fake_defaults" "$fake_launchctl"; do
  [[ -x "$required" ]] || {
    print -u2 -- "sender sleep preference test failed: not executable: $required"
    exit 1
  }
done
[[ -r "$long_running_source" ]] || {
  print -u2 -- "sender sleep preference test failed: not readable: $long_running_source"
  exit 1
}

test_root="$(mktemp -d)"
cleanup() {
  /bin/rm -rf -- "$test_root"
}
trap cleanup EXIT

export HOME="${test_root}/home"
export TB_FAKE_DEFAULTS_STATE_DIR="${test_root}/defaults"
export TB_DEFAULTS_BIN="$fake_defaults"
export TB_LAUNCHCTL_BIN="$fake_launchctl"
export TB_CODESIGN_BIN="/usr/bin/true"

app_path="${HOME}/Applications/TargetBridge 5K Sender.app"
executable_path="${app_path}/Contents/MacOS/TargetBridge"
mkdir -p "${executable_path:h}" "$TB_FAKE_DEFAULTS_STATE_DIR"
# Never copy and rename a signed macOS system executable as a test fixture.
# Modern macOS launch constraints correctly kill that binary and CrashReporter
# misleadingly presents it as a TargetBridge crash. Build our own inert helper
# in the temporary test home instead.
clang_path="$(xcrun --find clang)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
"$clang_path" -isysroot "$sdk_path" -Os "$long_running_source" -o "$executable_path"
/usr/bin/codesign --force --sign - "$executable_path"
info_plist="${app_path}/Contents/Info.plist"
plutil -create xml1 "$info_plist"
plutil -insert CFBundleIdentifier -string com.vikiboy.imac5kdisplay.sender "$info_plist"
plutil -insert CFBundleExecutable -string TargetBridge "$info_plist"

domain="com.vikiboy.imac5kdisplay.sender"
key="fd.tbdisplaysender.preventDisplaySleep"
backup="${HOME}/Library/Application Support/TargetBridge/Sender/prevent-display-sleep.original"
plist_path="${HOME}/Library/LaunchAgents/com.vikiboy.imac5kdisplay.sender.plist"
enabled_path="${HOME}/Library/Application Support/TargetBridge/Sender/enabled"
legacy_plist_path="${HOME}/Library/LaunchAgents/com.targetbridge.sender5k.plist"

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
  "$uninstaller" "$app_path" >/dev/null
}

# An absent original is represented explicitly, survives reinstall, and is
# restored as absence only when the appliance-owned false value is unchanged.
mkdir -p "${legacy_plist_path:h}"
print -r -- legacy > "$legacy_plist_path"
run_install
[[ ! -e "$legacy_plist_path" ]] || {
  print -u2 -- "sender installer retained the build-18 launch agent"
  exit 1
}
[[ "$(<"$backup")" == absent && "$(read_pref)" == 0 ]] || exit 1
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist_path")" == /bin/zsh ]] || exit 1
wrapper_guard="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$plist_path")"
[[ "$wrapper_guard" == '[[ -e "$1" ]] || exit 0; shift; exec "$@"' ]] || exit 1
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:3' "$plist_path")" == imac5k-monitor-launch ]] || exit 1
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:4' "$plist_path")" == "$enabled_path" ]] || exit 1
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:5' "$plist_path")" == /usr/bin/open ]] || exit 1
guard_fixture="${test_root}/guard-enabled"
if ! /bin/zsh -c "$wrapper_guard" imac5k-test "$guard_fixture" /usr/bin/false; then
  print -u2 -- "absent marker did not suppress speculative launch"
  exit 1
fi
touch "$guard_fixture"
if /bin/zsh -c "$wrapper_guard" imac5k-test "$guard_fixture" /usr/bin/false; then
  print -u2 -- "present marker did not execute wrapped command"
  exit 1
fi
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

# Disabling monitor mode must terminate the exact installed sender process,
# not merely launchd's waiting `open -W` parent. A backup/checkout is outside
# this exact-path contract and is left alone.
/bin/unlink "$backup"
write_pref 0
run_install
"$executable_path" &
sender_pid=$!
for _ in {1..20}; do
  /bin/kill -0 "$sender_pid" 2>/dev/null && break
  /bin/sleep 0.05
done
/bin/kill -0 "$sender_pid"
run_uninstall
if /bin/kill -0 "$sender_pid" 2>/dev/null; then
  print -u2 -- "sender uninstaller left exact installed app running"
  exit 1
fi
wait "$sender_pid" 2>/dev/null || true

# An ambiguous bootstrap failure must stop the exact app, restore the
# pre-install preference, and remove
# every fresh appliance artifact instead of leaving a half-enabled setup.
write_pref 1
export TB_FAKE_LAUNCHCTL_FAIL_OPERATION=bootstrap
export TB_FAKE_LAUNCHCTL_START_PATH_ON_FAILURE="$executable_path"
export TB_FAKE_LAUNCHCTL_PID_PATH="${test_root}/ambiguous-bootstrap.pid"
print -r -- legacy > "$legacy_plist_path"
if run_install 2>/dev/null; then
  print -u2 -- "sender installer unexpectedly succeeded during injected bootstrap failure"
  exit 1
fi
ambiguous_pid="$(<"$TB_FAKE_LAUNCHCTL_PID_PATH")"
unset TB_FAKE_LAUNCHCTL_FAIL_OPERATION
unset TB_FAKE_LAUNCHCTL_START_PATH_ON_FAILURE
unset TB_FAKE_LAUNCHCTL_PID_PATH
[[ "$(read_pref)" == 1 ]] || exit 1
[[ ! -e "$plist_path" && ! -e "$enabled_path" && ! -e "$backup" ]] || exit 1
[[ -e "$legacy_plist_path" && "$(<"$legacy_plist_path")" == legacy ]] || {
  print -u2 -- "failed install rollback did not restore the build-18 launch agent"
  exit 1
}
if /bin/kill -0 "$ambiguous_pid" 2>/dev/null; then
  print -u2 -- "failed install rollback left an ambiguously launched sender running"
  exit 1
fi
wait "$ambiguous_pid" 2>/dev/null || true

/bin/zsh -n "$installer" "$uninstaller" "$fake_defaults" "$fake_launchctl"
print -- "sender display-sleep preference lifecycle passed"
