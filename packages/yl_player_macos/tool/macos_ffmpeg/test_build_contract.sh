#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_script="$script_dir/build_xcframework.sh"
package_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
repo_root=$(CDPATH= cd -- "$package_root/../.." && pwd)
framework_root="$package_root/macos/yl_player_macos/Frameworks/YlFFmpegBridge.xcframework"
framework="$framework_root/macos-arm64_x86_64/YlFFmpegBridge.framework"
binary="$framework/YlFFmpegBridge"
contract=$(bash "$build_script" --print-contract)

require_line() {
  expected=$1
  if ! printf '%s\n' "$contract" | grep -Fqx -- "$expected"; then
    echo "missing build contract line: $expected" >&2
    exit 1
  fi
}

reject_text() {
  forbidden=$1
  if printf '%s\n' "$contract" | grep -Fq -- "$forbidden"; then
    echo "forbidden build option exposed: $forbidden" >&2
    exit 1
  fi
}

require_line "FFMPEG_VERSION=9.0.1"
require_line "FFMPEG_URL=https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz"
require_line "FFMPEG_SHA256=cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635"
require_line "FFMPEG_SIGNING_KEY_FINGERPRINT=FCF986EA15E6E293A5644F10B4322F04D67658D8"
require_line "MACOS_DEPLOYMENT_TARGET=12.0"
require_line "MACOS_ARCHITECTURES=macos-arm64,macos-x86_64"
require_line "FFMPEG_X86_64_FLAGS=--disable-x86asm"
require_line "--disable-network"
require_line "--disable-programs"
require_line "--disable-avdevice"
require_line "--disable-avfilter"
require_line "--disable-swscale"
require_line "--disable-swresample"
require_line "--enable-demuxer=matroska,flv"
require_line "--enable-protocol=file"
require_line "--enable-parser=aac,h264,hevc,mpegaudio"
require_line "--disable-gpl"
require_line "--disable-nonfree"

reject_text "--enable-gpl"
reject_text "--enable-nonfree"
reject_text "--enable-decoder=h264"
reject_text "--enable-decoder=hevc"
reject_text "--enable-decoder=mp3"
reject_text "--enable-protocol=http"
reject_text "--enable-protocol=https"

archs=$(lipo -archs "$binary")
case " $archs " in
  *" arm64 "*) ;;
  *) echo "missing arm64 framework slice: $archs" >&2; exit 1 ;;
esac
case " $archs " in
  *" x86_64 "*) ;;
  *) echo "missing x86_64 framework slice: $archs" >&2; exit 1 ;;
esac

require_symbol() {
  symbol=$1
  if ! nm -gU "$binary" | grep -Fq -- "$symbol"; then
    echo "missing exported framework symbol: $symbol" >&2
    exit 1
  fi
}

require_symbol "_ylf_build_configuration"
require_symbol "_ylf_ffmpeg_version"
require_symbol "_ylf_open_callbacks"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/yl_player_macos_contract.XXXXXX")
cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

cat >"$test_root/main.m" <<'EOF'
#import <Foundation/Foundation.h>
#import <YlFFmpegBridge/YlFFmpegBridge.h>
#include <stdio.h>

int main(void) {
  const char *version = ylf_ffmpeg_version();
  const char *configuration = ylf_build_configuration();
  if (version == NULL || configuration == NULL) return 2;
  printf("%s\n%s\n", version, configuration);
  return 0;
}
EOF

clang -fobjc-arc -mmacosx-version-min=12.0 \
  -F"$(dirname "$framework")" \
  -framework Foundation -framework YlFFmpegBridge \
  "$test_root/main.m" -o "$test_root/contract-smoke"

DYLD_FRAMEWORK_PATH="$(dirname "$framework")" "$test_root/contract-smoke" \
  | grep -Fq "9.0.1"

cat >"$test_root/live_probe.m" <<'EOF'
#import <Foundation/Foundation.h>
#import <YlFFmpegBridge/YlFFmpegBridge.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>

typedef struct {
  const uint8_t *bytes;
  size_t size;
  size_t offset;
} LoopSource;

static int32_t read_loop(void *opaque, uint8_t *buffer, int32_t capacity) {
  LoopSource *source = opaque;
  if (source->offset >= source->size) source->offset = 13;
  size_t available = source->size - source->offset;
  size_t count = MIN((size_t)capacity, available);
  memcpy(buffer, source->bytes + source->offset, count);
  source->offset += count;
  return (int32_t)count;
}

static int64_t reject_seek(void *opaque, int64_t offset, int32_t whence) {
  (void)opaque;
  (void)offset;
  (void)whence;
  return YLFCallbackSeekUnsupported;
}

static void cancel_loop(void *opaque) { (void)opaque; }

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 2) return 2;
    NSData *data = [NSData dataWithContentsOfFile:@(argv[1])];
    if (data.length <= 13) return 3;
    LoopSource source = { data.bytes, data.length, 0 };
    YLFMediaContextRef context = NULL;
    YLFMediaInfo info = {0};
    alarm(3);
    int32_t result = ylf_open_callbacks(
        &source, read_loop, reject_seek, cancel_loop, &context, &info);
    alarm(0);
    if (result != YLFResultOK || context == NULL || info.stream_count < 1) {
      ylf_close(&context);
      return 4;
    }
    ylf_close(&context);
    return 0;
  }
}
EOF

clang -fobjc-arc -mmacosx-version-min=12.0 \
  -F"$(dirname "$framework")" \
  -framework Foundation -framework YlFFmpegBridge \
  "$test_root/live_probe.m" -o "$test_root/live-probe"

DYLD_FRAMEWORK_PATH="$(dirname "$framework")" "$test_root/live-probe" \
  "$repo_root/packages/yl_player/example/assets/test_media/h264_aac.flv"

test -f "$package_root/LICENSES/FFmpeg-LGPL-2.1-or-later.txt"
test -f "$package_root/THIRD_PARTY_NOTICES.md"

printf '%s\n' "macOS FFmpeg build contract passed."
