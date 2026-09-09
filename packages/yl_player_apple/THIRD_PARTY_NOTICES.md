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

The combined `darwin/yl_player_apple/Frameworks/YlFFmpegBridge.xcframework`
contains `ios-arm64` (iOS 15.0+), `ios-arm64_x86_64-simulator` (iOS 15.0+),
and `macos-arm64_x86_64` (macOS 12.0+). The macOS framework retains its
versioned `Versions/A` layout. The shared bridge source and public header are
in `darwin/native/YlFFmpegBridge`.

From the repository root, the canonical builder is:

```sh
sh packages/yl_player_apple/tool/apple_ffmpeg/build_xcframework.sh --print-contract
python3 packages/yl_player_apple/tool/apple_ffmpeg/verify_artifact.py
sh packages/yl_player_apple/tool/apple_ffmpeg/build_xcframework.sh --rebuild-check
```

`verify_artifact.py` is the consumer verifier used by CI. It checks the exact
accepted lock (including recorded builder provenance), all six recipe/source/key
inputs, configuration, complete artifact bytes and symlink targets, and the
signed source receipt without requiring the verifier machine to match the
original builder. It never compiles, updates a lock, or changes artifact bytes.
`YL_FFMPEG_ARCHIVE` and `YL_FFMPEG_SIGNATURE` accept existing local source inputs;
otherwise the verifier obtains the exact pinned public archive and signature.

`--rebuild-check` requires the exact toolchain recorded in the lock, builds all
five targets in a fresh temporary directory, and compares every byte and
symlink target. The original self-hashed builder's `--verify` remains a
historical exact-host interface; use the separate consumer verifier above on
other hosts. Neither interface refreshes the lock. An accepted replacement
artifact requires reviewing and explicitly updating the consumer verifier's
accepted-lock digest along with its new provenance.

To rebuild or replace the LGPL component, use an absent output directory:

```sh
sh packages/yl_player_apple/tool/apple_ffmpeg/build_xcframework.sh --build-candidate /tmp/yl-ffmpeg-candidate
sh packages/yl_player_apple/tool/apple_ffmpeg/build_xcframework.sh --rebuild-check /tmp/yl-ffmpeg-candidate
```

After reviewing the clean rebuild comparison and all provenance changes,
replace `darwin/yl_player_apple/Frameworks/YlFFmpegBridge.xcframework` with the
candidate XCFramework and `tool/apple_ffmpeg/bridge-artifact.lock` with its
candidate lock. Candidate creation does not install or accept an artifact.
`YL_FFMPEG_ARCHIVE` and `YL_FFMPEG_SIGNATURE` may point to local copies of the
pinned release inputs; checksum and signature validation still run.
`YL_KEEP_FFMPEG_BUILD=1` retains temporary build evidence. The lock records
the required Xcode, SDK and compiler inputs; full binaries, including signing
metadata, are compared without exclusions.

Keep the scripts, lock files, license, and notices with every binary
distribution so recipients can replace the LGPL component. Distribution
still requires project-specific legal review.
