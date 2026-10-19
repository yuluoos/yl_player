#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
build="$(mktemp -d /tmp/yl-airplay-live-store.XXXXXX)"
trap 'rm -rf "$build"' EXIT
shared="$PWD/packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared"
xcrun swiftc -module-cache-path /tmp/yl-airplay-live-store-module-cache -swift-version 5 -target arm64-apple-macos12.0 -o "$build/live-store-tests" \
  tool/airplay/live_store_test_support.swift "$shared/AirPlay/YlAirPlayLiveStore.swift" \
  "$shared/AirPlay/YlAirPlayHTTPServer.swift" tool/airplay/live_store_tests.swift
"$build/live-store-tests"
