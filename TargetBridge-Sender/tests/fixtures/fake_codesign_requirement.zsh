#!/bin/zsh
set -euo pipefail

app="${@[-1]}"
root_file="${app}/Contents/Resources/signing-root"

if [[ " $* " == *" --verify "* ]]; then
  exit 0
fi

[[ -r "$root_file" ]] || exit 1
root="$(<"$root_file")"
if [[ " $* " == *" --verbose=4 "* ]]; then
  print -u2 -- "Authority=Fixture ${root}"
  print -u2 -- "Identifier=com.vikiboy.imac5kdisplay.sender"
  exit 0
fi
if [[ " $* " == *" -r- "* ]]; then
  print -u2 -- "Executable=${app}/Contents/MacOS/TargetBridge"
  print -u2 -- "designated => identifier \"com.vikiboy.imac5kdisplay.sender\" and certificate root = H\"${root}\""
  exit 0
fi

exit 2
