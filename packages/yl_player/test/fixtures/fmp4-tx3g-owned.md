# Owned independently muxed fMP4 tx3g fixture

`fmp4-tx3g-owned.mp4` was generated with host FFmpeg 8.0.1, not a runtime
library dependency. Black 64×64 video and the SRT text in the evidence directory
are owned synthetic content. No downloaded media.

```sh
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=black:s=64x64:r=5:d=5 \
  -i source.srt -map 0:v -map 1:s -c:v libx264 -g 5 -bf 0 -c:s mov_text \
  -movflags empty_moov+frag_keyframe+default_base_moof \
  -metadata:s:s:0 language=eng fmp4-tx3g-owned.mp4
ffprobe -v error -select_streams s -show_streams -show_packets -of json fmp4-tx3g-owned.mp4
```

TrackID2 is mov_text/tx3g, languageeng, timebase1/1000000. Subtitle samples:
empty0–1s, bold `bold` plus ` and 中文` from1–3.123s, `second` from3.123–4.567s,
and an empty terminal sample. The first text's sample ends at3.123s per ffprobe,
although the inputSRT ends it at2.5s; assertions use encoded sample intervals.

Positive parser tests verify TrackID, language, literal text, bold style and exact
microsecond times, including audio/video-traf skipping. This is one producer
interoperability sample, not universal BMFF/QuickTime/native-device conformance.
SHA256 and raw probe/generator inputs are retained in
`docs/superpowers/reports/evidence/2026-10-11-subtitle-fmp4-tx3g/`.
