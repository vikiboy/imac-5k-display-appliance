#!/bin/zsh
set -euo pipefail

state_dir="${TB_FAKE_SYSADMINCTL_STATE_DIR:?TB_FAKE_SYSADMINCTL_STATE_DIR is required}"
state_path="${state_dir}/screen-lock"
expected_password="${TB_FAKE_SYSADMINCTL_EXPECTED_PASSWORD-}"
INTEGER_PATTERN='^[0-9]+$'
mkdir -p "$state_dir"

[[ "${1:-}" == "-screenLock" ]] || exit 64
operation="${2:?screenLock operation is required}"

if [[ "$operation" == "status" ]]; then
  [[ -f "$state_path" ]] || exit 1
  IFS= read -r current < "$state_path"
  case "$current" in
    off)
      print -u2 -- "screenLock is off"
      ;;
    immediate)
      print -u2 -- "screenLock delay is immediate"
      ;;
    *)
      [[ "$current" =~ $INTEGER_PATTERN ]] || exit 65
      print -u2 -- "screenLock delay is ${current} seconds"
      ;;
  esac
  exit 0
fi

[[ "$operation" == "off" || "$operation" == "immediate" ||
   "$operation" =~ $INTEGER_PATTERN ]] || exit 64
[[ "$#" == "4" && "${3:-}" == "-password" ]] || exit 64
[[ "${4-}" == "$expected_password" ]] || exit 77
print -r -- "$operation" > "$state_path"
