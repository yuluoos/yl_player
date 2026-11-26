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

## First seek into an unread Blu-ray clip

We compared against `9a244f83` on arm64 macOS 27.2. Each trial opened a fresh ISO session and AVPlayer, waited for the initial video frame, then sought with zero tolerance to three seconds before the end. The timer stopped when AVPlayerItemVideoOutput returned a pixel buffer with a display timestamp at the target (within 50 ms before to 2 s after). The loopback origin added 50 ms per Range and did not throttle bandwidth. We alternated the order of the two AOT builds.

The long image is the same 30-minute, 30-clip title used above. The higher-bitrate image contains 96 seconds of synthetic 1280×720 H.264 motion at 24 fps, a 12 Mbps target with a one-second GOP, and 192 kbps AC-3. It was authored with tsMuxer using a 24-second clip split. The first far seek lands inside the last M2TS clip on both images.

Values are medians. Range counts and bytes cover the interval from the first video frame to the first far-seek frame. The startup column includes opening the ISO and launching the native process.

| Image / origin | Fresh sessions per build | Cold seek to frame (ms) | Origin requests during cold seek | Open to first frame (ms) |
| --- | ---: | ---: | ---: | ---: |
| 30 min, HTTP | 6 | 459.5 → 402.5 | 5 → 5 | 1,239 → 1,303 |
| 30 min, HTTPS | 6 | 498.5 → 457 | 5 → 5 | 1,612 → 1,462 |
| 12 Mbps, HTTP | 5 | 4,849 → 3,205 | 69 → 58 | 1,089 → 1,211 |
| 12 Mbps, HTTPS | 5 | 5,451 → 3,792 | 69 → 58 | 1,590 → 1,703 |

The short-segment rows were collected after the other verification jobs finished. Those seeks requested exactly 520,704 origin bytes in both versions. A separate eight-pair run during concurrent verification was noisy. HTTP cold-seek medians were 518 → 1,073 ms and HTTPS medians were 573.5 → 445 ms. The smaller gain is sensitive to scheduling on this host.

For a fixed full GET of the last segment on the 12 Mbps image, three fresh HTTPS sessions consistently requested 1,666,368 origin bytes. The request count fell from 6 to 4, and median time to receive the complete segment fell from 488 to 202 ms. During the native seek, the high-bitrate HTTP median requested body bytes increased from 26,286,336 to 34,603,008 and HTTPS from 26,589,120 to 34,603,008. These counters include extra HLS buffering around the seek by the native client.

Across both builds the HLS manifest required exactly 12 origin requests / 658,433 bytes for the long image and 8 requests / 396,289 bytes for the 12 Mbps image. On the latter, AVPlayer sometimes buffered a different number of segments before displaying the target frame. The measurements include this variability. The cold last segment and both complete FFmpeg elementary stream SHA-256 hashes matched for each image.

The virtual HLS server can read an unseen clip's PAT/PMT and the target segment's first media block concurrently on a complete network GET. The first media read is capped at 384 KiB. For a segment starting inside a clip, subsequent reads of its body can cover up to 768 KiB each, bounded by the requested segment. A short segment needs only the overlap. A large segment saves additional round trips. HEAD and bounded byte-range requests retain their on-demand reads.

To repeat the native measurement, compile the probe and pass its path to the existing Range benchmark. Run once with the default HTTPS origin and once with `--http`. The driver emits three fresh sessions per invocation. `frameMs` is measured inside AVPlayer. The outer `ms`, request count, and requested body bytes are cumulative from ISO open. Subtract the `firstFrame` counters from the `coldSeek` counters for the cold-seek interval, which can include outstanding AVPlayer buffering.

```sh
xcrun swiftc tool/playback_benchmark/iso_seek_frames.swift -o /tmp/yl-iso-seek-frames
dart packages/yl_player/tool/iso_ranges.dart \
  --frame-probe=/tmp/yl-iso-seek-frames /path/to/multi-clip.iso
```
