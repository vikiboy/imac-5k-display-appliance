#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
receiver_dir="${script_dir:h:h}"
installer="${1:-${receiver_dir}/scripts/install_targetbridge_5k_receiver_launch_agent.sh}"
uninstaller="${2:-${receiver_dir}/scripts/uninstall_targetbridge_5k_receiver_launch_agent.sh}"
fake_defaults="${script_dir}/fixtures/fake_defaults.zsh"
fake_launchctl="${script_dir}/fixtures/fake_launchctl.zsh"
fake_sysadminctl="${script_dir}/fixtures/fake_sysadminctl.zsh"

for required in "$installer" "$uninstaller" "$fake_defaults" "$fake_launchctl" "$fake_sysadminctl"; do
  [[ -x "$required" ]] || {
    print -u2 "receiver screen saver preference test failed: not executable: $required"
    exit 1
  }
done

test_root="$(mktemp -d)"
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

test_home="${test_root}/home"
state_dir="${test_root}/defaults"
sysadmin_state_dir="${test_root}/sysadminctl"
app_path="${test_home}/Applications/TargetBridge 5K Receiver.app"
receiver_executable="${app_path}/Contents/MacOS/TargetBridge5KReceiver"
mkdir -p "${receiver_executable:h}" "$state_dir" "$sysadmin_state_dir"
touch "$receiver_executable"
chmod +x "$receiver_executable"

export HOME="$test_home"
export TB_DEFAULTS_BIN="$fake_defaults"
export TB_LAUNCHCTL_BIN="$fake_launchctl"
export TB_FAKE_DEFAULTS_STATE_DIR="$state_dir"
export TB_SYSADMINCTL_BIN="$fake_sysadminctl"
export TB_FAKE_SYSADMINCTL_STATE_DIR="$sysadmin_state_dir"

pref() {
  "$fake_defaults" "$@"
}

managed_value() {
  pref read com.vikiboy.imac5k-display-appliance ManagesScreenSaverIdleTime
}

original_value() {
  pref read com.vikiboy.imac5k-display-appliance OriginalScreenSaverIdleTime
}

current_idle_value() {
  pref -currentHost read com.apple.screensaver idleTime
}

lock_managed_value() {
  pref read com.vikiboy.imac5k-display-appliance ManagesScreenLockDelay
}

lock_original_value() {
  pref read com.vikiboy.imac5k-display-appliance OriginalScreenLockDelay
}

current_lock_value() {
  IFS= read -r lock_value < "${sysadmin_state_dir}/screen-lock"
  print -r -- "$lock_value"
}

set_fake_lock_value() {
  local value="$1"
  local password="${2-${TB_FAKE_SYSADMINCTL_EXPECTED_PASSWORD-}}"
  "$fake_sysadminctl" -screenLock "$value" -password "$password"
}

# Ordinary install backs up 300 once and disables the local screen saver.
set_fake_lock_value immediate
pref -currentHost write com.apple.screensaver idleTime -int 300
"$installer" "$app_path" >/dev/null
[[ "$(managed_value)" == "1" && "$(original_value)" == "300" &&
   "$(current_idle_value)" == "0" ]] || {
  print -u2 "receiver screen saver preference test failed: initial backup/disable"
  exit 1
}
[[ "$(current_lock_value)" == "immediate" ]] || {
  print -u2 "receiver screen lock preference test failed: default install changed policy"
  exit 1
}
if lock_managed_value >/dev/null 2>&1 || lock_original_value >/dev/null 2>&1; then
  print -u2 "receiver screen lock preference test failed: default install claimed lock management"
  exit 1
fi

# Reinstall is idempotent: the managed 0 must not replace the original 300.
"$installer" "$app_path" >/dev/null
[[ "$(original_value)" == "300" && "$(current_idle_value)" == "0" ]] || {
  print -u2 "receiver screen saver preference test failed: reinstall replaced backup"
  exit 1
}

# Uninstall restores the backup when the installer-owned 0 is untouched.
"$uninstaller" >/dev/null
[[ "$(current_idle_value)" == "300" ]] || {
  print -u2 "receiver screen saver preference test failed: original value not restored"
  exit 1
}
if managed_value >/dev/null 2>&1 || original_value >/dev/null 2>&1; then
  print -u2 "receiver screen saver preference test failed: management metadata retained"
  exit 1
fi

# A post-install user change must win over the install-time backup.
"$installer" "$app_path" >/dev/null
pref -currentHost write com.apple.screensaver idleTime -int 900
"$uninstaller" >/dev/null
[[ "$(current_idle_value)" == "900" ]] || {
  print -u2 "receiver screen saver preference test failed: user override was overwritten"
  exit 1
}
if managed_value >/dev/null 2>&1 || original_value >/dev/null 2>&1; then
  print -u2 "receiver screen saver preference test failed: override metadata retained"
  exit 1
fi

# Absence is also a restorable original state, represented internally by -1.
pref -currentHost delete com.apple.screensaver idleTime
"$installer" "$app_path" >/dev/null
[[ "$(original_value)" == "-1" && "$(current_idle_value)" == "0" ]] || {
  print -u2 "receiver screen saver preference test failed: absent value not backed up"
  exit 1
}
"$uninstaller" >/dev/null
if current_idle_value >/dev/null 2>&1; then
  print -u2 "receiver screen saver preference test failed: absent value not restored"
  exit 1
fi

# Removing the managed setting is also a user override and must remain absent.
pref -currentHost write com.apple.screensaver idleTime -int 300
"$installer" "$app_path" >/dev/null
pref -currentHost delete com.apple.screensaver idleTime
"$uninstaller" >/dev/null
if current_idle_value >/dev/null 2>&1; then
  print -u2 "receiver screen saver preference test failed: deleted user override was overwritten"
  exit 1
fi

# An inconsistent management marker must fail closed instead of inventing a
# restore value, and must retain the marker so a later repair can retry.
pref -currentHost write com.apple.screensaver idleTime -int 0
pref write com.vikiboy.imac5k-display-appliance ManagesScreenSaverIdleTime -bool true
if "$uninstaller" >/dev/null 2>&1; then
  print -u2 "receiver screen saver preference test failed: missing backup was accepted"
  exit 1
fi
[[ "$(managed_value)" == "1" && "$(current_idle_value)" == "0" ]] || {
  print -u2 "receiver screen saver preference test failed: unsafe restore did not fail closed"
  exit 1
}

# Remove the intentionally inconsistent screen-saver fixture before exercising
# screen-lock management as an independent reversible setting.
pref delete com.vikiboy.imac5k-display-appliance ManagesScreenSaverIdleTime
pref -currentHost delete com.apple.screensaver idleTime

# Opt-in must be explicit and the account-password variable must be present.
export TB_APPLIANCE_DISABLE_SCREEN_LOCK=1
unset TB_APPLIANCE_ACCOUNT_PASSWORD
set_fake_lock_value immediate
if "$installer" "$app_path" >/dev/null 2>&1; then
  print -u2 "receiver screen lock preference test failed: missing password variable was accepted"
  exit 1
fi
[[ "$(current_lock_value)" == "immediate" ]] || {
  print -u2 "receiver screen lock preference test failed: missing-password install changed policy"
  exit 1
}
if lock_managed_value >/dev/null 2>&1 || lock_original_value >/dev/null 2>&1; then
  print -u2 "receiver screen lock preference test failed: missing-password install wrote metadata"
  exit 1
fi

# An explicitly empty password is valid. Immediate is backed up once, then
# restored after an idempotent reinstall.
export TB_FAKE_SYSADMINCTL_EXPECTED_PASSWORD=''
export TB_APPLIANCE_ACCOUNT_PASSWORD=''
pref -currentHost write com.apple.screensaver idleTime -int 300
"$installer" "$app_path" >/dev/null
[[ "$(lock_managed_value)" == "1" && "$(lock_original_value)" == "immediate" &&
   "$(current_lock_value)" == "off" ]] || {
  print -u2 "receiver screen lock preference test failed: immediate backup/disable"
  exit 1
}
"$installer" "$app_path" >/dev/null
[[ "$(lock_original_value)" == "immediate" && "$(current_lock_value)" == "off" ]] || {
  print -u2 "receiver screen lock preference test failed: reinstall replaced immediate backup"
  exit 1
}
"$uninstaller" >/dev/null
[[ "$(current_lock_value)" == "immediate" ]] || {
  print -u2 "receiver screen lock preference test failed: immediate was not restored"
  exit 1
}
if lock_managed_value >/dev/null 2>&1 || lock_original_value >/dev/null 2>&1; then
  print -u2 "receiver screen lock preference test failed: restored metadata retained"
  exit 1
fi

# Restoring a managed non-off value also requires the password variable. A
# failed attempt must retain both the managed state and its recovery metadata.
secret_password='screen-lock-test-secret'
export TB_FAKE_SYSADMINCTL_EXPECTED_PASSWORD="$secret_password"
export TB_APPLIANCE_ACCOUNT_PASSWORD="$secret_password"
set_fake_lock_value immediate "$secret_password"
pref -currentHost write com.apple.screensaver idleTime -int 300
"$installer" "$app_path" >/dev/null
unset TB_APPLIANCE_ACCOUNT_PASSWORD
if "$uninstaller" >/dev/null 2>&1; then
  print -u2 "receiver screen lock preference test failed: passwordless restore was accepted"
  exit 1
fi
[[ "$(lock_managed_value)" == "1" && "$(lock_original_value)" == "immediate" &&
   "$(current_lock_value)" == "off" ]] || {
  print -u2 "receiver screen lock preference test failed: passwordless restore lost recovery state"
  exit 1
}
export TB_APPLIANCE_ACCOUNT_PASSWORD="$secret_password"
"$uninstaller" >/dev/null

# Integer-second status is parsed and restored, and no command output may
# contain the non-empty account password.
set_fake_lock_value 300 "$secret_password"
pref -currentHost write com.apple.screensaver idleTime -int 300
# Run the production scripts with tracing enabled here: their password-bearing
# sysadminctl call must explicitly suppress xtrace as well as ordinary output.
install_output="$(/bin/zsh -x "$installer" "$app_path" 2>&1)"
[[ "$(lock_original_value)" == "300" && "$(current_lock_value)" == "off" ]] || {
  print -u2 "receiver screen lock preference test failed: seconds backup/disable"
  exit 1
}
[[ "$install_output" != *"$secret_password"* ]] || {
  print -u2 "receiver screen lock preference test failed: installer logged password"
  exit 1
}
uninstall_output="$(/bin/zsh -x "$uninstaller" 2>&1)"
[[ "$(current_lock_value)" == "300" ]] || {
  print -u2 "receiver screen lock preference test failed: seconds value was not restored"
  exit 1
}
[[ "$uninstall_output" != *"$secret_password"* ]] || {
  print -u2 "receiver screen lock preference test failed: uninstaller logged password"
  exit 1
}

# An originally-off policy is a valid normalized backup and requires no change
# when metadata is removed during uninstall.
set_fake_lock_value off "$secret_password"
pref -currentHost write com.apple.screensaver idleTime -int 300
"$installer" "$app_path" >/dev/null
[[ "$(lock_original_value)" == "off" && "$(current_lock_value)" == "off" ]] || {
  print -u2 "receiver screen lock preference test failed: off status was not parsed"
  exit 1
}
unset TB_APPLIANCE_ACCOUNT_PASSWORD
"$uninstaller" >/dev/null
[[ "$(current_lock_value)" == "off" ]] || {
  print -u2 "receiver screen lock preference test failed: original off policy changed"
  exit 1
}

# A post-install user choice wins and can be preserved without supplying the
# old account password to uninstall.
export TB_APPLIANCE_ACCOUNT_PASSWORD="$secret_password"
set_fake_lock_value immediate "$secret_password"
pref -currentHost write com.apple.screensaver idleTime -int 300
"$installer" "$app_path" >/dev/null
set_fake_lock_value 900 "$secret_password"
unset TB_APPLIANCE_ACCOUNT_PASSWORD
"$uninstaller" >/dev/null
[[ "$(current_lock_value)" == "900" ]] || {
  print -u2 "receiver screen lock preference test failed: user override was overwritten"
  exit 1
}
if lock_managed_value >/dev/null 2>&1 || lock_original_value >/dev/null 2>&1; then
  print -u2 "receiver screen lock preference test failed: override metadata retained"
  exit 1
fi

# Missing restore metadata fails closed with the managed off state and marker
# untouched, allowing a later manual repair/retry.
set_fake_lock_value immediate "$secret_password"
pref write com.vikiboy.imac5k-display-appliance ManagesScreenLockDelay -bool true
export TB_APPLIANCE_ACCOUNT_PASSWORD="$secret_password"
if "$installer" "$app_path" >/dev/null 2>&1; then
  print -u2 "receiver screen lock preference test failed: installer accepted missing backup"
  exit 1
fi
[[ "$(lock_managed_value)" == "1" && "$(current_lock_value)" == "immediate" ]] || {
  print -u2 "receiver screen lock preference test failed: inconsistent install did not fail closed"
  exit 1
}

set_fake_lock_value off "$secret_password"
unset TB_APPLIANCE_ACCOUNT_PASSWORD
if "$uninstaller" >/dev/null 2>&1; then
  print -u2 "receiver screen lock preference test failed: missing backup was accepted"
  exit 1
fi
[[ "$(lock_managed_value)" == "1" && "$(current_lock_value)" == "off" ]] || {
  print -u2 "receiver screen lock preference test failed: inconsistent state did not fail closed"
  exit 1
}

zsh -n "$installer" "$uninstaller" "$fake_defaults" "$fake_launchctl" "$fake_sysadminctl"
print "receiver idle lifecycle preferences passed (screen saver + opt-in screen lock are reversible and fail closed)"
