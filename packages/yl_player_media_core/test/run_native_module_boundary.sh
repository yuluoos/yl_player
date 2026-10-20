#!/bin/bash
set -euo pipefail
package="$(cd "$(dirname "$0")/.." && pwd)"
output="$(mktemp -d /tmp/yl-media-core-boundary.XXXXXX)"
trap 'rm -rf "$output"' EXIT
framework="$package/darwin/yl_player_media_core/Frameworks/YlFFmpegBridge.xcframework/macos-arm64_x86_64"
sources=()
while IFS= read -r source; do sources+=("$source"); done < <(find "$package/darwin/yl_player_media_core/Sources" -name '*.swift' | sort)
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" \
  -module-cache-path "$output/cache" -emit-module -emit-library \
  -module-name yl_player_media_core -F "$framework" \
  -o "$output/libyl_player_media_core.dylib" "${sources[@]}"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" \
  -module-cache-path "$output/cache" -I "$output" -L "$output" \
  -F "$framework" -lyl_player_media_core -framework YlFFmpegBridge \
  -Xlinker -rpath -Xlinker "$output" -Xlinker -rpath -Xlinker "$framework" \
  "$package/test/native_module_boundary.swift" -o "$output/boundary"
"$output/boundary"
