The iOS simulator cadence test uses a single VOD segment with 384 H.264 frames at 24 fps. The segment uses the existing HLS fixture key and an all-zero IV, as served by the example's HLS test server.

To regenerate from this directory with FFmpeg, x264 and OpenSSL, run

```sh
work=$(mktemp -d)
ffmpeg -v error -f lavfi -i 'testsrc2=s=160x90:r=24:d=16' \
  -c:v libx264 -profile:v baseline -level 1.3 -crf 30 -pix_fmt yuv420p \
  -g 24 -sc_threshold 0 -f hls -hls_time 16 -hls_playlist_type vod \
  -hls_segment_filename "$work/cadence%d.ts" "$work/cadence.m3u8"
openssl enc -aes-128-cbc -K "$(xxd -p hls_key.bin)" \
  -iv 00000000000000000000000000000000 \
  -in "$work/cadence0.ts" -out hls_cadence_16s.ts
```
