#!/bin/sh
set -eu
cd /Users/yy2021_8689/Desktop/Flutter/yl_player/packages/yl_player/example
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
ORG_GRADLE_PROJECT_ylBoundAV=true /Users/yy2021_8689/flutter/bin/flutter build apk --debug --target integration_test/bound_av_test.dart --target-platform android-arm64 --no-pub > /private/tmp/yl-p03-full-public-20261016/build-android-final.log 2>&1
cp build/app/outputs/flutter-apk/app-debug.apk /private/tmp/yl-p03-full-public-20261016/public-final.apk
