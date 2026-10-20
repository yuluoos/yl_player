#!/bin/sh
set -eu
if [ "$#" -ne 3 ]; then
  echo 'usage: test_dolby_vision_decode.sh XCFRAMEWORK MEDIA_PATH REPAIRED_HVCC_PATH' >&2
  exit 2
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
framework_dir="$1/macos-arm64_x86_64"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/yl-dovi-decode.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
xcrun clang -fobjc-arc -F"$framework_dir" -Wl,-rpath,"$framework_dir" \
  "$script_dir/test_dolby_vision_decode.m" \
  -framework YlFFmpegBridge -framework Foundation -framework CoreMedia \
  -framework CoreVideo -framework VideoToolbox -o "$temporary/probe"
"$temporary/probe" "$2" "$3"
