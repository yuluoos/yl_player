# Owned embedded Matroska fixture

`embedded-owned.mkv` contains 2 seconds of 32×32 black MPEG-4 video at 2 fps and
two authored SRT tracks. No downloaded content, fonts, or binary library.

Inputs:

```
# normal.srt
1
00:00:00,503 --> 00:00:01,707
Owned embedded normal

# forced.srt
1
00:00:00,750 --> 00:00:01,250
Owned embedded forced
```

Generation with the host FFmpeg CLI (fixture use only):

```sh
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i color=c=black:s=32x32:r=2:d=2 \
  -i normal.srt -i forced.srt -map 0:v -map 1:s -map 2:s \
  -c:v mpeg4 -c:s srt \
  -metadata:s:s:0 language=eng -metadata:s:s:0 title=Normal \
  -metadata:s:s:1 language=eng -metadata:s:s:1 title=Forced \
  -disposition:s:0 0 -disposition:s:1 forced -y embedded-owned.mkv
```

Generated UIDs may vary. Tests assert stable discovered identity and stream
semantics, not fixed random muxer UIDs. The committed binary hash, generator
version and ffprobe stream/packet output are recorded in the embedded evidence.
