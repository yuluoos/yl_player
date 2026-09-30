#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/yl-vp9-headers.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
xcrun swiftc -module-cache-path "$temporary/cache" \
 "$repo_root/packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/VideoToolbox/YlVP9FrameHeader.swift" \
 "$repo_root/tool/media_matrix/vp9_header_test.swift" -o "$temporary/test"
"$temporary/test" "$repo_root/tool/media_matrix/fixtures/vp9-profile0.ivf"
