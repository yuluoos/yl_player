# Owned Matroska VobSub fixture

Original 4x3 DVD SPU from `support/vobsub_fixture.dart` with a 100x100 canvas,
white/red/green palette, two RLE fields and an alpha update. No third-party media.
Host FFmpeg 8.0.1 remuxes the generated IDX/SUB pair:

```sh
ffmpeg -hide_banner -loglevel error -y -i source.idx -c:s copy embedded-vobsub-owned.mkv
ffprobe -v error -show_streams -show_packets -show_data -of json embedded-vobsub-owned.mkv
```

The output contains `dvd_subtitle`, one raw 46-byte SPU at PTS 1s, no packet
duration, and `size`/`palette` CodecPrivate without IDX stream/timestamp rows.
SPU alpha changes at 1.512s and stops at 2.024s. Tests assert actual encoded timing
and pixels. FFmpeg is fixture provenance only, not a new runtime dependency.
Inputs, probe and hashes are recorded under
`docs/superpowers/reports/evidence/2026-10-12-subtitle-embedded-vobsub/`.
