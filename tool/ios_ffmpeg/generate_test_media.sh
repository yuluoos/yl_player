#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
fixture_dir="$repo_root/packages/yl_player/example/ios/RunnerTests/Fixtures"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg is required to generate test fixtures" >&2
  exit 1
fi

mkdir -p "$fixture_dir"

common_video_flags="-c:v libx264 -pix_fmt yuv420p -g 24 -keyint_min 24 -sc_threshold 0 -threads 1"
common_output_flags="-t 2 -fflags +bitexact -map_metadata -1"

# shellcheck disable=SC2086
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i testsrc2=size=320x180:rate=24 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 \
  -map 0:v -map 1:a \
  $common_video_flags -c:a aac -b:a 96k \
  $common_output_flags \
  "$fixture_dir/h264_aac.mkv"

# shellcheck disable=SC2086
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i testsrc2=size=320x180:rate=24 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 \
  -f lavfi -i sine=frequency=880:sample_rate=48000 \
  -map 0:v -map 1:a -map 2:a \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=zho \
  $common_video_flags -c:a aac -b:a 96k \
  $common_output_flags \
  "$fixture_dir/two_audio_tracks.mkv"

# Keep HEVC output deterministic and small. Limit x265 to one frame thread so
# fixture generation does not depend on host core count.
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i testsrc2=size=320x180:rate=24 \
  -f lavfi -i sine=frequency=660:sample_rate=48000 \
  -map 0:v -map 1:a \
  -c:v libx265 -pix_fmt yuv420p -g 24 -keyint_min 24 \
  -x265-params "log-level=error:pools=1:frame-threads=1:scenecut=0" \
  -c:a aac -b:a 96k \
  $common_output_flags \
  "$fixture_dir/hevc_aac.mkv"

echo "generated deterministic MKV fixtures in $fixture_dir"
