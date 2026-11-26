# ISO startup and DVD seek measurements

Measured on macOS 27.2 against commit `41e0b7fb`. Each value is the median of three fresh sessions. The loopback origin delayed every Range response by 50 ms and accepted single ranges. The measurements cover local network round trips and media processing with an unconstrained transfer rate.

| HTTPS image | Origin requests before manifest, before → after | Origin body bytes before manifest | Manifest ready (ms) | First decoded video frame (ms) |
| --- | ---: | ---: | ---: | ---: |
| DVD, 14 s | 14 → 10 | 464,897 → 413,957 | 593 → 475 | 851 → 735 |
| Blu-ray, 18 s | 11 → 8 | 524,289 → 396,289 | 629 → 468 | 970 → 740 |
| DVD, 30 min | 395 → 201 | 12,967,937 → 391,556 | 6,114 → 3,068 | 6,319 → 3,404 |
| Blu-ray, 30 min, 30 clips | 45 → 12 | 3,377,653 → 658,433 | 2,507 → 679 | 2,829 → 1,057 |
| DVD, 5 min, 6 Mbps target video | 98 → 68 | 6,002,689 → 4,120,056 | 3,037 → 1,675 | 3,146 → 1,901 |

Plain HTTP on the short fixtures had the same request counts as HTTPS. Median manifest times were 566 → 451 ms for DVD and 594 → 433 ms for Blu-ray. The 30-minute images extend the authored short sources with repeated synthetic material. The higher-bitrate DVD uses 720×480 NTSC MPEG-2 motion video and stereo AC-3.

The source benchmark measures from image open to the loopback HLS server becoming ready. A separate AVPlayer probe starts from a fresh session and waits for a pixel buffer from AVPlayerItemVideoOutput. Its end-to-end time includes starting the native probe process.

## Seeking

The source benchmark consumes the first and last segments (A and B), then times three complete requests for A, B and A. On the 30-minute DVD these revisits took 283 → 1 ms and 5 → 0 upstream requests. On the 6 Mbps DVD they took 4,910 → 16 ms and 87 → 0 upstream requests. The cache retains up to 16 MiB of completed DVD segments per session, with at most 64 entries. Concurrent requests for one segment share the remux.

The native probe separately issues zero-tolerance seeks to three seconds before the end and back to one second, twice. It waits for a decoded frame at the requested position each time. On the 6 Mbps DVD the second far seek took 1,564 → 37 ms and the final return took 1,718 → 26 ms. On the 30-minute Blu-ray, the first far seek into a previously untouched clip took 378 → 423 ms. That clip's program tables are now read on demand. The second far seek took 219 → 224 ms.

## Media integrity and memory

A separate full-title stream-copy pass used FFmpeg to hash the elementary video and audio streams. Both SHA-256 hashes matched the baseline on each of the three longer images. An AOT-compiled Dart ISO server ran in its own process, with the source HTTP server and FFmpeg in separate processes. Median peak resident memory was 61.6 → 60.7 MiB for the 30-minute DVD, 29.9 → 29.8 MiB for the 30-minute Blu-ray, and 111.4 → 111.8 MiB for the 6 Mbps DVD. Peak memory on the latter varied between runs (106.8–193.6 MiB before and 104.2–135.8 MiB after).

## Repeating the Range measurements

Run from the repository root with the Flutter workspace dependencies installed. The command outputs one JSON record per session. It accepts gzip-compressed fixtures and uncompressed ISO paths. Add `--http` for plain HTTP. To compare another revision, use the same benchmark driver and input image with each version of the ISO implementation.

```sh
dart packages/yl_player/tool/iso_ranges.dart \
  packages/yl_player/example/assets/test_media/dvd_titles.iso.gz.bin \
  packages/yl_player/example/assets/test_media/bluray_colors.iso.gz.bin
```
