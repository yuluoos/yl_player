The ISO test fixture is a gzip-compressed, unencrypted UDF 2.50 Blu-ray title
created with tsMuxer. The extra .bin suffix preserves the compressed asset in
Android packages. The 18-second video contains red, green and blue pictures
with a continuous 880 Hz AC-3 track. MPLS playlist 00000 references three
M2TS clips. To generate an equivalent image in a temporary directory:

```sh
ffmpeg -f lavfi -i color=red:s=320x180:r=24:d=7 \
  -f lavfi -i color=green:s=320x180:r=24:d=7 \
  -f lavfi -i color=blue:s=320x180:r=24:d=4 \
  -filter_complex '[0:v][1:v][2:v]concat=n=3:v=1:a=0' \
  -c:v libx264 -g 24 -keyint_min 24 -sc_threshold 0 -bf 0 -f h264 colors.h264
ffmpeg -f lavfi -i sine=frequency=880:sample_rate=48000 -t 18 -c:a ac3 movie.ac3
cat > colors.meta <<'META'
MUXOPT --blu-ray --split-duration=6s
V_MPEG4/ISO/AVC, colors.h264, fps=24
A_AC3, movie.ac3
META
tsmuxer colors.meta colors.iso
gzip -nc colors.iso > bluray_colors.iso.gz.bin
```
