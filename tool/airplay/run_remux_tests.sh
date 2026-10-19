#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
root="$PWD"
build="$(mktemp -d /tmp/yl-airplay-remux.XXXXXX)"
trap 'rm -rf "$build"' EXIT
framework="$root/packages/yl_player_apple/darwin/yl_player_apple/Frameworks/YlFFmpegBridge.xcframework/macos-arm64_x86_64"
shared="$root/packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared"
xcrun swiftc -module-cache-path /tmp/yl-airplay-remux-module-cache -swift-version 5 -target arm64-apple-macos12.0 -F "$framework" -framework YlFFmpegBridge -Xlinker -rpath -Xlinker "$framework" -o "$build/remux-tests" \
  tool/airplay/remux_test_support.swift "$shared/Dependencies/YlOpenCancellationToken.swift" \
  "$shared/AirPlay/YlAirPlayRemux.swift" "$shared/AirPlay/YlAirPlayHTTPServer.swift" tool/airplay/remux_test.swift
"$build/remux-tests" "$root/tool/consumer_fixtures/apple_flutter/Resources"
