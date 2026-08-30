#!/bin/zsh
set -euo pipefail

state_dir="${TB_FAKE_DEFAULTS_STATE_DIR:?TB_FAKE_DEFAULTS_STATE_DIR is required}"
mkdir -p "$state_dir"

operation="${1:?defaults operation is required}"
domain="${2:?defaults domain is required}"
key="${3:?defaults key is required}"
state_path="${state_dir}/${domain}__${key}"

case "$operation" in
  read)
    [[ -f "$state_path" ]] || exit 1
    IFS= read -r value < "$state_path"
    print -r -- "$value"
    ;;
  write)
    [[ "${4:-}" == "-bool" ]] || exit 64
    case "${5:-}" in
      true|TRUE|1) value=1 ;;
      false|FALSE|0) value=0 ;;
      *) exit 64 ;;
    esac
    print -r -- "$value" > "$state_path"
    ;;
  delete)
    [[ -f "$state_path" ]] || exit 1
    /bin/unlink "$state_path"
    ;;
  *) exit 64 ;;
esac
