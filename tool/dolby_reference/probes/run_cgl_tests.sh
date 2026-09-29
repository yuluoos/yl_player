#!/usr/bin/env bash
# Research only. Requires the unchanged, pinned Task1B1 macOS build.
set -euo pipefail
probe_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$probe_dir/../../.." && pwd)
probe_root=${1:-"$repo_dir/.superpowers/sdd/2026-09-26-remaining-07-dolby/build-probes"}
source_dir="$probe_root/libplacebo-c42968d8616a1d1c8ad5f4f1a8d6f5a9cb396e56"
build_dir="$probe_root/placebo-macos"
run_dir="$probe_root/cgl-native"
if [[ $(uname -s) != Darwin || ! -f "$build_dir/src/libplacebo.372.dylib" || ! -f "$source_dir/src/tests/gpu_tests.c" ]]; then
  echo 'Missing macOS or pinned Task1B1 build prerequisites' >&2
  exit 2
fi
mkdir -p "$run_dir"
compile_flags=(-std=c11 -O2 -g -D_GNU_SOURCE -DPL_STATIC -DPL_HAVE_PTHREAD
  -mmacosx-version-min=12.0 -Wno-unused-function
  -I"$build_dir/src/include" -I"$source_dir/src/include"
  -I"$build_dir/src" -I"$source_dir/src" -I"$source_dir/src/tests")
xcrun clang "${compile_flags[@]}" -c "$probe_dir/placebo_cgl_tests.c" -o "$run_dir/context.o"
xcrun clang "${compile_flags[@]}" -c "$source_dir/src/tests/gpu_tests.c" -o "$run_dir/gpu_tests.o"
xcrun clang++ -mmacosx-version-min=12.0 -o "$run_dir/placebo-cgl-tests" \
  "$run_dir/context.o" "$run_dir/gpu_tests.o" "$build_dir/src/libplacebo.372.dylib.p/"*.o \
  -framework OpenGL -lm -ldl
# 0: upstream assertions returned; 77: no native context (not a pass);
# other nonzero: build, library creation, or assertion failed. Do not mask it.
exec "$run_dir/placebo-cgl-tests"
