#!/bin/sh
set -eu
package_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=$(mktemp -d "${TMPDIR:-/tmp}/yl-script-native.XXXXXX")
trap 'rm -rf "$output_dir"' EXIT HUP INT TERM
set -- -std=gnu11 -O1 -g -fwrapv -funsigned-char -D_GNU_SOURCE '-DCONFIG_VERSION="2026-06-04"'
if [ "${SANITIZE:-0}" = 1 ]; then
  set -- "$@" -fsanitize=address,undefined -fno-omit-frame-pointer
fi
clang "$@" -I "$package_dir/src/quickjs" \
  "$package_dir/test/native_runtime_harness.c" \
  "$package_dir/src/yl_script_runtime.c" \
  "$package_dir/src/quickjs/quickjs.c" \
  "$package_dir/src/quickjs/cutils.c" \
  "$package_dir/src/quickjs/dtoa.c" \
  "$package_dir/src/quickjs/libregexp.c" \
  "$package_dir/src/quickjs/libunicode.c" \
  -o "$output_dir/harness"
UBSAN_OPTIONS=halt_on_error=1 "$output_dir/harness"

# This harness includes the runtime through test-only QuickJS observers.
clang "$@" -I "$package_dir/src/quickjs" \
  "$package_dir/test/native_cleanup_harness.c" \
  "$package_dir/src/quickjs/quickjs.c" \
  "$package_dir/src/quickjs/cutils.c" \
  "$package_dir/src/quickjs/dtoa.c" \
  "$package_dir/src/quickjs/libregexp.c" \
  "$package_dir/src/quickjs/libunicode.c" \
  -o "$output_dir/cleanup-harness"
UBSAN_OPTIONS=halt_on_error=1 "$output_dir/cleanup-harness"
