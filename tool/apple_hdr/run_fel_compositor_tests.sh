#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/yl-fel-compositor.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
SOURCES="$ROOT/packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/VideoToolbox"
xcrun swiftc -module-cache-path "$BUILD/modules" \
  "$SOURCES/YlFELMetadata.swift" "$SOURCES/YlFELCompositor.swift" \
  "$ROOT/tool/apple_hdr/fel_compositor_tests.swift" -o "$BUILD/tests"
"$BUILD/tests"
