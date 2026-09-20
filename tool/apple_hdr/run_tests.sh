#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
native="$root/packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/yl-hdr-tests.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
xcrun swiftc -module-cache-path "$scratch/cache" \
  "$native/Shared/VideoToolbox/YlHDRVideoPolicy.swift" \
  "$root/tool/apple_hdr/policy_tests.swift" -o "$scratch/policy"
"$scratch/policy"
xcrun swiftc -module-cache-path "$scratch/cache" \
  "$native/Shared/VideoToolbox/YlVideoSurfaceMailbox.swift" \
  "$root/tool/apple_hdr/mailbox_tests.swift" -o "$scratch/mailbox"
"$scratch/mailbox"
xcrun swiftc -module-cache-path "$scratch/cache" \
  "$native/Shared/VideoToolbox/YlVideoSurfaceMailbox.swift" \
  "$native/Shared/VideoToolbox/YlSampleBufferVideoRenderer.swift" \
  "$root/tool/apple_hdr/sample_tests.swift" -o "$scratch/sample"
"$scratch/sample"
xcrun swiftc -module-cache-path "$scratch/cache" \
  "$native/Shared/Session/YlPlatformServices.swift" \
  "$root/tool/apple_hdr/lease_tests.swift" -o "$scratch/lease"
"$scratch/lease"
