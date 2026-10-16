#!/bin/sh
set -u
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
for mode in positive negative-framework negative-identity; do
  flag=""
  if [ "$mode" != positive ]; then flag="--$mode"; fi
  python3 -B tool/run_with_display_awake.py python3 -B tool/media_matrix/run_bound_flutter_apple.py --platform ios --simulator A65DC0EE-B634-43E9-BBA5-AC3F35C1F7F6 --app /private/tmp/yl-p03-avplayer-audio-20261016/build-ios/Build/Products/Debug-iphonesimulator/Runner.app --case mp4-avc-aac $flag --out /private/tmp/yl-p03-avplayer-audio-20261016/ios-final-$mode > /private/tmp/yl-p03-avplayer-audio-20261016/ios-final-$mode-console.log 2>&1
done
