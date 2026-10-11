# Owned FFmpeg stpp negative fixture

`stpp-ffmpeg-owned.mp4` contains a generated black16×16 video and two self-authored subtitles, no external media. Host FFmpeg8.0.1 encodes TTML and independently muxes MP4; this CLI is not a runtime dependency. Reproduction source and ffprobe are archived in the stpp evidence directory.

```sh
ffmpeg -hide_banner -f lavfi -i color=c=black:s=16x16:d=5 -i stpp-owned.srt -map 0:v -map 1:s -c:v libx264 -c:s ttml -metadata:s:s:0 language=eng -movflags +faststart -y stpp-owned.mp4
```

ffprobe reports subtitle Track ID2, codec ttml/tag stpp, one XML sample from0 to4.567seconds. XML cue intervals are1.250–2.500 and3.123–4.567seconds. The encoder emits cellResolution,16c font size,Arial/overflow properties outside our existing TTML subset. The test expects explicit unsupported; it does **not** claim successful independent-producer rendering. Positive rendering uses separate owned supported-subset fixtures.
