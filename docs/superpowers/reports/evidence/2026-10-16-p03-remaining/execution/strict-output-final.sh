#!/bin/sh
set -eu
cd /Users/yy2021_8689/Desktop/Flutter/yl_player/packages/yl_player/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/native-macos-tests CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES 'OTHER_SWIFT_FLAGS=$(inherited) -D YL_BOUND_AV' -parallel-testing-enabled NO -only-testing:RunnerTests/YlEngineAssessmentTests -only-testing:RunnerTests/YlProgramStreamTests -only-testing:RunnerTests/YlAppleSessionTests -only-testing:RunnerTests/YlContainerOutputTests -only-testing:RunnerTests/YlFallbackBufferBudgetTests -resultBundlePath /private/tmp/yl-p03-remaining-20261016/strict-output-final.xcresult > /private/tmp/yl-p03-remaining-20261016/strict-output-final.log 2>&1
