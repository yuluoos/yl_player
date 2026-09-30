#!/bin/sh
set -eu
if [ "$#" -ne 1 ] || [ -e "$1" ]; then
  echo 'Usage: build_apple_resources.sh NEW_OUTPUT_DYLIB' >&2
  exit 2
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
xcrun clang -O2 -fobjc-arc -dynamiclib -mmacosx-version-min=12.0 \
  "$script_dir/apple_resources.m" -framework Foundation -framework IOKit -o "$1"
