#!/bin/sh
set -u
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
python3 -B tool/media_matrix/run_bound_flutter_apple.py --platform macos --app /private/tmp/yl-p03-remaining-20261016/build-public-final/Build/Products/Debug/yl_player_example.app --case mp4-avc-aac --transport http --negative-framework --out /private/tmp/yl-p03-remaining-20261016/macos-negative-framework-final > /private/tmp/yl-p03-remaining-20261016/macos-negative-framework-final.log 2>&1
p03_rc=$?
[ "$p03_rc" -eq 1 ] || exit 99
python3 -B tool/media_matrix/run_bound_flutter_apple.py --platform macos --app /private/tmp/yl-p03-remaining-20261016/build-public-final/Build/Products/Debug/yl_player_example.app --case mp4-avc-aac --transport http --negative-identity --out /private/tmp/yl-p03-remaining-20261016/macos-negative-identity-final > /private/tmp/yl-p03-remaining-20261016/macos-negative-identity-final.log 2>&1
p03_rc=$?
[ "$p03_rc" -eq 1 ] || exit 99
