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
python3 - "$root" "$scratch" <<'PY_NATIVE'
from pathlib import Path
import sys
root, scratch = map(Path, sys.argv[1:])
sys.path.insert(0, str(root))
from tool.media_delivery.native_build import build_modules
native = build_modules(scratch / 'native', include_delivery=False)
shared = root / 'packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared'
native.compile_test([shared / 'VideoToolbox/YlTimedVideoEndpoint.swift',
    shared / 'Session/YlPlatformServices.swift', root / 'tool/apple_hdr/lease_tests.swift'],
    scratch / 'lease', imports=['yl_player_media_core'])
PY_NATIVE
"$scratch/lease"
