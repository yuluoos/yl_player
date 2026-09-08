# Third-party notices

## FFmpeg 9.0.1

`YlFFmpegBridge.xcframework` contains a minimized build of FFmpeg 9.0.1
`libavformat`, `libavcodec`, and `libavutil`. It is used for Matroska and FLV
demultiplexing and packet parsing only; video decoding remains in Apple
VideoToolbox and AAC/MP3 decoding remains in AudioToolbox.

The minimized allowlist enables only the `matroska,flv` demuxers; the
`aac,h264,hevc,mpegaudio` parsers; and the `file` protocol used by package-owned
custom AVIO. FFmpeg networking, protocols other than `file`, decoders, encoders,
muxers, filters, scaling/resampling, GPL, and nonfree components remain disabled.

- Source: <https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz>
- Signature: <https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz.asc>
- SHA-256: `cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635`
- Release-key fingerprint: `FCF986EA15E6E293A5644F10B4322F04D67658D8`
- License: LGPL-2.1-or-later; see `LICENSES/FFmpeg-LGPL-2.1-or-later.txt`.

This packaging skeleton does not yet include the combined iOS and macOS
`YlFFmpegBridge.xcframework` or its canonical package-local builder. Exact
configure-contract and rebuild commands, slice descriptions, and artifact
replacement paths will be documented when those files are added; the legacy
platform-specific commands do not apply to this shared package.

When the binary distribution is added, keep the scripts, lock file,
license, and notices with every binary distribution so recipients can replace
the LGPL component. Distribution still requires project-specific legal review.
