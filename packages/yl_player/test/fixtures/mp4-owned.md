# Owned MP4 fixture

`embedded-owned.mp4` is generated from a 32×24 black video and two authored text
cues, with host FFmpeg (not a runtime dependency). No borrowed media/font assets.

Source SRT:

```
1
00:00:01,000 --> 00:00:02,500
<b>bold</b> and 中文

2
00:00:03,123 --> 00:00:04,567
second
```

Generation command:

```
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=black:s=32x24:r=2:d=5 -i mp4-owned.srt -map 0 -map 1 -c:v mpeg4 -c:s mov_text -metadata:s:s:0 language=eng -y embedded-owned.mp4
ffprobe -v error -show_streams -show_packets -select_streams s -of json embedded-owned.mp4
```

Track ID2, languageeng; text intervals 1.000–2.500 and3.123–4.567seconds are derived
from the authored source and independently recorded by ffprobe, not the parser.
First cue has bold characters0..4 plus unstyled remainder. Media includes video
packets interleaved with subtitle chunks; the parser test checks precise times,
text and style. Original ffprobe output and fixture SHA256 are in the MP4 evidence
manifest. This is a demux/Flutter fixture, not native/device playback evidence.
