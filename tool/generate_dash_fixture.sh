#!/bin/sh
set -eu

YL_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
YL_REPO_ROOT=$(git -C "$YL_SCRIPT_DIR" rev-parse --show-toplevel)
YL_OUTPUT="$YL_REPO_ROOT/packages/yl_player/example/assets/test_media/dash"
YL_WORK=$(mktemp -d "${TMPDIR:-/tmp}/yl-dash-fixture.XXXXXX")
trap 'rm -rf "$YL_WORK"' EXIT HUP INT TERM

generate_period() {
  YL_PERIOD=$1
  YL_FREQUENCY=$2
  mkdir -p "$YL_WORK/$YL_PERIOD"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i 'testsrc=size=320x180:rate=24:duration=4' \
    -f lavfi -i "sine=frequency=$YL_FREQUENCY:sample_rate=48000:duration=4" \
    -map 0:v:0 -map 1:a:0 \
    -c:v libx264 -preset veryfast -profile:v baseline -level:v 3.0 \
    -pix_fmt yuv420p -g 24 -keyint_min 24 -sc_threshold 0 -b:v 350k \
    -c:a aac -b:a 64k -ar 48000 -ac 1 \
    -f dash -seg_duration 1 -use_template 1 -use_timeline 1 \
    -adaptation_sets 'id=0,streams=v id=1,streams=a' \
    -init_seg_name 'init-$RepresentationID$.m4s' \
    -media_seg_name 'chunk-$RepresentationID$-$Number%05d$.m4s' \
    "$YL_WORK/$YL_PERIOD/generated.mpd"
  rm "$YL_WORK/$YL_PERIOD/generated.mpd"
}

generate_period period0 440
generate_period period1 660

cat > "$YL_WORK/manifest.mpd" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" type="static" mediaPresentationDuration="PT8S" minBufferTime="PT1S">
  <Period id="period0" start="PT0S" duration="PT4S">
    <BaseURL>period0/</BaseURL>
    <AdaptationSet id="0" contentType="video" segmentAlignment="true" startWithSAP="1">
      <Representation id="0" mimeType="video/mp4" codecs="avc1.42c01e" bandwidth="350000" width="320" height="180" frameRate="24/1">
        <SegmentTemplate timescale="12288" initialization="init-$RepresentationID$.m4s" media="chunk-$RepresentationID$-$Number%05d$.m4s" startNumber="1">
          <SegmentTimeline><S t="0" d="12288" r="3"/></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
    <AdaptationSet id="1" contentType="audio" segmentAlignment="true" startWithSAP="1">
      <Representation id="1" mimeType="audio/mp4" codecs="mp4a.40.2" bandwidth="64000" audioSamplingRate="48000">
        <AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="1"/>
        <SegmentTemplate timescale="48000" initialization="init-$RepresentationID$.m4s" media="chunk-$RepresentationID$-$Number%05d$.m4s" startNumber="1">
          <SegmentTimeline><S t="0" d="47104"/><S d="48128" r="2"/><S d="512"/></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
  <Period id="period1" start="PT4S" duration="PT4S">
    <BaseURL>period1/</BaseURL>
    <AdaptationSet id="0" contentType="video" segmentAlignment="true" startWithSAP="1">
      <Representation id="0" mimeType="video/mp4" codecs="avc1.42c01e" bandwidth="350000" width="320" height="180" frameRate="24/1">
        <SegmentTemplate timescale="12288" initialization="init-$RepresentationID$.m4s" media="chunk-$RepresentationID$-$Number%05d$.m4s" startNumber="1">
          <SegmentTimeline><S t="0" d="12288" r="3"/></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
    <AdaptationSet id="1" contentType="audio" segmentAlignment="true" startWithSAP="1">
      <Representation id="1" mimeType="audio/mp4" codecs="mp4a.40.2" bandwidth="64000" audioSamplingRate="48000">
        <AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="1"/>
        <SegmentTemplate timescale="48000" initialization="init-$RepresentationID$.m4s" media="chunk-$RepresentationID$-$Number%05d$.m4s" startNumber="1">
          <SegmentTimeline><S t="0" d="47104"/><S d="48128" r="2"/><S d="512"/></SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
EOF

mkdir -p "$YL_OUTPUT"
find "$YL_OUTPUT" -mindepth 1 -maxdepth 1 ! -name README.md -exec rm -rf {} +
cp -R "$YL_WORK/period0" "$YL_WORK/period1" "$YL_WORK/manifest.mpd" "$YL_OUTPUT/"

(cd "$YL_OUTPUT" && find . -type f ! -name README.md ! -name SHA256SUMS -print0 \
  | LC_ALL=C sort -z \
  | xargs -0 shasum -a 256 > SHA256SUMS)
cat "$YL_OUTPUT/SHA256SUMS"
