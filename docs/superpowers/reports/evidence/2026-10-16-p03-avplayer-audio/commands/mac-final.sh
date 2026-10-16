#!/bin/sh
set -u
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
for mode in positive controls negative-framework negative-identity; do
  args="--case mp4-avc-aac"
  if [ "$mode" = controls ]; then args=""; fi
  if [ "$mode" = negative-framework ] || [ "$mode" = negative-identity ]; then args="$args --$mode"; fi
  python3 -B tool/run_with_display_awake.py python3 -B tool/media_matrix/run_bound_flutter_apple.py --platform macos --app /private/tmp/yl-p03-avplayer-audio-20261016/build-public/Build/Products/Debug/yl_player_example.app $args --out /private/tmp/yl-p03-avplayer-audio-20261016/macos-final-$mode > /private/tmp/yl-p03-avplayer-audio-20261016/macos-final-$mode-console.log 2>&1
done
