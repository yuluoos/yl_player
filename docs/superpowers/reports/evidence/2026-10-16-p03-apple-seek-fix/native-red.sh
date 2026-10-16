#!/bin/sh
set -eu
cd /Users/yy2021_8689/Desktop/Flutter/yl_player/packages/yl_player/example
/Users/yy2021_8689/flutter/bin/flutter build macos --debug --config-only -t lib/main.dart > /private/tmp/yl-p03-seek-fix-20261016/config-native.log 2>&1
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/native-macos-tests CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES -parallel-testing-enabled NO -only-testing:RunnerTests/YlPlatformServicesTests/testRetiredFallbackCannotClearCandidateTexture -resultBundlePath /private/tmp/yl-p03-seek-fix-20261016/native-red.xcresult > /private/tmp/yl-p03-seek-fix-20261016/native-red.log 2>&1
