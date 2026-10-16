#!/bin/sh
set -eu
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
python3 -B tool/run_with_display_awake.py sh /private/tmp/yl-p03-full-public-20261016/native-final.sh > /private/tmp/yl-p03-full-public-20261016/native-final-command.log 2>&1
sh /private/tmp/yl-p03-full-public-20261016/macos-final-runs.sh
