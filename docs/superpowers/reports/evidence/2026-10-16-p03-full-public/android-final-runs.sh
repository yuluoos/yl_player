#!/bin/sh
set -u
cd /Users/yy2021_8689/Desktop/Flutter/yl_player
scratch=/private/tmp/yl-p03-full-public-20261016
python3 -B tool/media_matrix/run_bound_flutter_matrix.py --platform android --apk "$scratch/public-final.apk" --serial emulator-5588 --out "$scratch/android-matrix-final" > "$scratch/android-matrix-final.log" 2>&1
printf '%s\n' "$?" > "$scratch/android-matrix-final.exit"
python3 -B tool/media_matrix/run_bound_flutter_android.py --apk "$scratch/public-final.apk" --serial emulator-5588 --negative-framework --out "$scratch/android-negative-framework-final" > "$scratch/android-negative-framework-final.log" 2>&1
printf '%s\n' "$?" > "$scratch/android-negative-framework-final.exit"
python3 -B tool/media_matrix/run_bound_flutter_android.py --apk "$scratch/public-final.apk" --serial emulator-5588 --negative-identity --out "$scratch/android-negative-identity-final" > "$scratch/android-negative-identity-final.log" 2>&1
printf '%s\n' "$?" > "$scratch/android-negative-identity-final.exit"
