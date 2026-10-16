#!/bin/sh
set -eu
cd /Users/yy2021_8689/Desktop/Flutter/yl_player/packages/yl_player/example
/Users/yy2021_8689/flutter/bin/dart format integration_test/p03_policy_test.dart integration_test/opus_policy_test.dart integration_test/vorbis_policy_test.dart integration_test/vp9_policy_test.dart integration_test/support/apple_strict_support.dart > /private/tmp/yl-p03-remaining-20261016/format.log 2>&1
/Users/yy2021_8689/flutter/bin/flutter analyze --no-pub integration_test/p03_policy_test.dart integration_test/opus_policy_test.dart integration_test/vorbis_policy_test.dart integration_test/vp9_policy_test.dart integration_test/support/apple_strict_support.dart > /private/tmp/yl-p03-remaining-20261016/analyze-final.log 2>&1
/Users/yy2021_8689/flutter/bin/flutter test test --no-pub --concurrency=2 > /private/tmp/yl-p03-remaining-20261016/example-tests.log 2>&1
