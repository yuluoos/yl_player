# Owned hybrid MP4 tx3g fixture

Generated with hostFFmpeg8.0.1 from owned64×64blackvideo and source.srt in the
evidence directory; not a runtime dependency, no downloaded media. Unlike the
previous empty_moov fixture, initial moov has a populated subtitle sample table.

```sh
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=black:s=64x64:r=5:d=5 \
  -i source.srt -map 0:v -map 1:s -c:v libx264 -g 5 -bf 0 -c:s mov_text \
  -movflags frag_keyframe+default_base_moof \
  -metadata:s:s:0 language=eng hybrid-mp4-owned.mp4
ffprobe -v error -select_streams s -show_streams -show_packets -of json hybrid-mp4-owned.mp4
```

TrackID2, mov_text, eng,1/1000000. Visible initial text=`bold and 中文` with bold
firstword,0–3.123s. Later fragment text=`second`,3.123–4.567s; then empty terminal
sample. Use encoded ffprobe intervals: inputSRT firstend2.5s differs from muxedend.
Test verifies track identity, text, style and microsecond timing. This single
producer positive case does not qualify native playback or every BMFF producer.

SHA256, generator input, ffprobe and structural box audit are in
`docs/superpowers/reports/evidence/2026-10-12-subtitle-hybrid-mp4/`.
