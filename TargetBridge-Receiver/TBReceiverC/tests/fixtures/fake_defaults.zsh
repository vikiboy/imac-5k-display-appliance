#!/bin/zsh
set -euo pipefail

state_dir="${TB_FAKE_DEFAULTS_STATE_DIR:?TB_FAKE_DEFAULTS_STATE_DIR is required}"
mkdir -p "$state_dir"
INTEGER_PATTERN='^-?[0-9]+$'

scope=standard
if [[ "${1:-}" == "-currentHost" ]]; then
  scope=current-host
  shift
fi

operation="${1:?defaults operation is required}"
domain="${2:?defaults domain is required}"
key="${3:?defaults key is required}"
state_path="${state_dir}/${scope}__${domain}__${key}"

case "$operation" in
  read)
    [[ -f "$state_path" ]] || exit 1
    IFS= read -r value < "$state_path"
    print -r -- "$value"
    ;;
  write)
    type="${4:?defaults value type is required}"
    value="${5:?defaults value is required}"
    case "$type" in
      -int)
        [[ "$value" =~ $INTEGER_PATTERN ]] || exit 64
        ;;
      -bool)
        case "$value" in
          true|TRUE|1) value=1 ;;
          false|FALSE|0) value=0 ;;
          *) exit 64 ;;
        esac
        ;;
      -string)
        ;;
      *) exit 64 ;;
    esac
    print -r -- "$value" > "$state_path"
    ;;
  delete)
    [[ -f "$state_path" ]] || exit 1
    rm "$state_path"
    ;;
  *)
    exit 64
    ;;
esac
