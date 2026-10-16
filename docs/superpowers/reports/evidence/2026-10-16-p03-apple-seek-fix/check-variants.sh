#!/bin/sh
set -eu
cd /Users/yy2021_8689/Desktop/Flutter/yl_player/packages/yl_player/example
/Users/yy2021_8689/flutter/bin/flutter build macos --debug --config-only -t lib/main.dart > /private/tmp/yl-p03-seek-fix-20261016/config-ordinary.log 2>&1
xcodebuild build -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/native-macos-tests CODE_SIGNING_ALLOWED=NO 'OTHER_SWIFT_FLAGS=$(inherited)' > /private/tmp/yl-p03-seek-fix-20261016/build-ordinary.log 2>&1
/Users/yy2021_8689/flutter/bin/flutter build macos --release --config-only -t lib/main.dart > /private/tmp/yl-p03-seek-fix-20261016/config-release.log 2>&1
xcodebuild build -workspace macos/Runner.xcworkspace -scheme Runner -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/yl-p03-seek-fix-20261016/build-release CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES 'OTHER_SWIFT_FLAGS=$(inherited) -D YL_BOUND_AV' > /private/tmp/yl-p03-seek-fix-20261016/build-release.log 2>&1
