#!/bin/zsh
set -euo pipefail

SOURCE_PATH="${1:?usage: test_appkit_launch_contract.zsh receiver-source}"

if /usr/bin/grep -Fq '[NSApp finishLaunching]' "$SOURCE_PATH"; then
  print -u2 'FAIL appkit_launch_contract explicit finishLaunching is forbidden when NSApp run owns the event loop'
  exit 1
fi

if ! /usr/bin/grep -Fq '[NSApp run]' "$SOURCE_PATH"; then
  print -u2 'FAIL appkit_launch_contract NSApp run event loop is missing'
  exit 1
fi

if ! /usr/bin/grep -Fq '[[TBApplianceWindow alloc]' "$SOURCE_PATH"; then
  print -u2 'FAIL appkit_launch_contract receiver must use the key-capable appliance window'
  exit 1
fi

if /usr/bin/grep -Fq '[window makeKeyAndOrderFront:nil]' "$SOURCE_PATH"; then
  print -u2 'FAIL appkit_launch_contract idle transitions must not race activation or steal focus'
  exit 1
fi

if /usr/bin/grep -Fq 'NSApplicationActivationPolicyAccessory' "$SOURCE_PATH"; then
  print -u2 'FAIL appkit_launch_contract receiver must not fall back to UIElement/accessory policy'
  exit 1
fi

if ! /usr/bin/grep -Fq 'NSApplicationActivationPolicyRegular' "$SOURCE_PATH"; then
  print -u2 'FAIL appkit_launch_contract regular foreground policy is missing'
  exit 1
fi

if ! /usr/bin/grep -Fq 'appkit=launch-contract-failed' "$SOURCE_PATH"; then
  print -u2 'FAIL appkit_launch_contract foreground policy failure must fail closed'
  exit 1
fi

if ! /usr/bin/grep -Fq 'appkit=activation-deferred reason=gui-session-unavailable' "$SOURCE_PATH"; then
  print -u2 'FAIL appkit_launch_contract launch while locked must not steal the secure surface'
  exit 1
fi

print 'PASS appkit_launch_contract single launch owner'
