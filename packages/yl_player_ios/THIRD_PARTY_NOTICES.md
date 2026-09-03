# Third-party notices

## FFmpeg 9.0.1

`YlFFmpegBridge.xcframework` contains a minimized build of FFmpeg 9.0.1
`libavformat`, `libavcodec`, and `libavutil`. It is used for local Matroska
demultiplexing and packet parsing only; video decoding remains in Apple
VideoToolbox.

- Source: <https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz>
- Signature: <https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz.asc>
- SHA-256: `cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635`
- Release-key fingerprint: `FCF986EA15E6E293A5644F10B4322F04D67658D8`
- License: LGPL-2.1-or-later; see `LICENSES/FFmpeg-LGPL-2.1-or-later.txt`.

The exact configure options are emitted by:

```sh
tool/ios_ffmpeg/build_xcframework.sh --print-contract
```

Rebuild with:

```sh
tool/ios_ffmpeg/build_xcframework.sh
```

The script verifies the official detached signature and checksum, builds the
device and Simulator slices, then replaces
`ios/yl_player_ios/Frameworks/YlFFmpegBridge.xcframework`. Keep the scripts,
lock file, license, and notices with every binary distribution so recipients
can replace the LGPL component. Distribution still requires project-specific
legal review.

The same rebuild inputs are included inside the published `yl_player_ios`
package at `tool/ios_ffmpeg`; repository-root copies are retained for the
monorepo development workflow.
