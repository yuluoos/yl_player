#!/bin/sh
set -u
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
scratch=/private/tmp/yl-p03-full-public-20261016
app="$scratch/build-public-final/Build/Products/Debug/yl_player_example.app"
python3 -B tool/run_with_display_awake.py python3 -B tool/media_matrix/run_bound_flutter_matrix.py --platform macos --app "$app" --out "$scratch/macos-matrix-final" > "$scratch/macos-matrix-final.log" 2>&1
printf '%s\n' "$?" > "$scratch/macos-matrix-final.exit"
python3 -B tool/run_with_display_awake.py python3 -B tool/media_matrix/run_bound_flutter_apple.py --platform macos --app "$app" --negative-framework --out "$scratch/macos-negative-framework-final" > "$scratch/macos-negative-framework-final.log" 2>&1
printf '%s\n' "$?" > "$scratch/macos-negative-framework-final.exit"
python3 -B tool/run_with_display_awake.py python3 -B tool/media_matrix/run_bound_flutter_apple.py --platform macos --app "$app" --negative-identity --out "$scratch/macos-negative-identity-final" > "$scratch/macos-negative-identity-final.log" 2>&1
printf '%s\n' "$?" > "$scratch/macos-negative-identity-final.exit"
