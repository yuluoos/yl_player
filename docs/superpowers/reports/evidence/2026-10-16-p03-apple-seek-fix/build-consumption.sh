#!/bin/sh
set -eu
cd /Users/yy2021_8689/Desktop/Flutter/yl_player/packages/yl_player/example
/Users/yy2021_8689/flutter/bin/flutter build macos --debug --config-only -t integration_test/bound_av_test.dart > /private/tmp/yl-p03-seek-fix-20261016/config-public-consumption-final.log 2>&1
xcodebuild build -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/yl-p03-seek-fix-20261016/build-public CODE_SIGNING_ALLOWED=NO 'OTHER_SWIFT_FLAGS=$(inherited) -D YL_BOUND_AV' > /private/tmp/yl-p03-seek-fix-20261016/build-public-consumption-final.log 2>&1
