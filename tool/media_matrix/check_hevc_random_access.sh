#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/yl-hevc-random-access.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
xcrun swiftc -module-cache-path "$temporary/module-cache" \
  "$repo_root/packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/VideoToolbox/YlHEVCRandomAccessGate.swift" \
  "$repo_root/tool/media_matrix/hevc_random_access_test.swift" \
  -o "$temporary/hevc-random-access"
"$temporary/hevc-random-access"
