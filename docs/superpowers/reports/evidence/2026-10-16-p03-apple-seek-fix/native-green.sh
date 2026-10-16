#!/bin/sh
set -eu
cd /Users/yy2021_8689/Desktop/Flutter/yl_player/packages/yl_player/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/native-macos-tests CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES -parallel-testing-enabled NO -only-testing:RunnerTests/YlPlatformServicesTests -resultBundlePath /private/tmp/yl-p03-seek-fix-20261016/native-green.xcresult > /private/tmp/yl-p03-seek-fix-20261016/native-green.log 2>&1
