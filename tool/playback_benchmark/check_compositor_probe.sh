#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ "$(uname -s)" = Darwin ] || { echo 'Compositor probe requires macOS/Xcode.' >&2; exit 2; }
owned_tmp=$(mktemp -d "${TMPDIR:-/tmp}/yl-compositor-check.XXXXXX")
trap 'rm -rf "$owned_tmp"' EXIT HUP INT TERM
xcrun swiftc "$here/capture_marker.swift" "$here/capture_marker_test.swift" -o "$owned_tmp/marker"
"$owned_tmp/marker"
xcrun swiftc -swift-version 5 -O -emit-library -target "$(uname -m)-apple-macos14.0" \
  "$here/capture_marker.swift" "$here/compositor_capture.swift" -o "$owned_tmp/capture.dylib"
echo 'Owned compositor probe compiled; no capture or permission request performed.'
