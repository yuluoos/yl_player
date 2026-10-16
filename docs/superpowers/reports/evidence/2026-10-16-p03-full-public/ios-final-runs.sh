#!/bin/sh
set -u
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
scratch=/private/tmp/yl-p03-full-public-20261016
app="$scratch/build-ios/Build/Products/Debug-iphonesimulator/Runner.app"
python3 -B tool/media_matrix/run_bound_flutter_matrix.py --platform ios --app "$app" --simulator A65DC0EE-B634-43E9-BBA5-AC3F35C1F7F6 --out "$scratch/ios-matrix-final" > "$scratch/ios-matrix-final.log" 2>&1
printf '%s\n' "$?" > "$scratch/ios-matrix-final.exit"
python3 -B tool/media_matrix/run_bound_flutter_apple.py --platform ios --app "$app" --simulator A65DC0EE-B634-43E9-BBA5-AC3F35C1F7F6 --negative-identity --out "$scratch/ios-negative-identity-final" > "$scratch/ios-negative-identity-final.log" 2>&1
printf '%s\n' "$?" > "$scratch/ios-negative-identity-final.exit"
