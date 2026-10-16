#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/yl-fel-pairing.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -module-cache-path "$scratch/cache" \
  "$root/packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/VideoToolbox/YlFELPairing.swift" \
  "$root/tool/apple_fel/pairing_tests.swift" -o "$scratch/pairing"
"$scratch/pairing"
xcrun swiftc -module-cache-path "$scratch/cache" \
  "$root/packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/VideoToolbox/YlFELMetadata.swift" \
  "$root/tool/apple_fel/metadata_fixture.swift" \
  "$root/tool/apple_fel/metadata_tests.swift" -o "$scratch/metadata"
"$scratch/metadata"
