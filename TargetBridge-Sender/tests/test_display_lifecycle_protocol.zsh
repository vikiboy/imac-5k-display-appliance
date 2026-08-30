#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
sender_dir="${script_dir:h}"
protocol="${sender_dir}/TBDisplayShared/TBMonitorProtocol.swift"
test_source="${script_dir}/test_display_lifecycle_protocol.swift"
build_dir="$(mktemp -d)"
trap '/bin/rm -rf -- "$build_dir"' EXIT

xcrun swiftc "$protocol" "$test_source" \
  -o "$build_dir/test_display_lifecycle_protocol"
"$build_dir/test_display_lifecycle_protocol"
