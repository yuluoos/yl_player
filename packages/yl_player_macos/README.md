# yl_player_macos

`yl_player_macos` is the endorsed macOS implementation of `yl_player`. Most
applications should depend on `yl_player`; Flutter then registers this package
automatically on macOS without a platform-specific API branch.

## Requirements and verified platforms

- macOS 12.0 or later.
- Flutter 3.44.0 or later and Dart 3.12.0 or later.
- Universal distribution artifacts with `arm64` and `x86_64` slices.

Apple Silicon runtime: verified.

Intel build and link: verified.

Intel physical-device runtime: not verified; no Intel Mac was available.

The Intel slice also passes a Rosetta smoke launch on the tested Apple Silicon
machine. That check does not replace testing on Intel hardware. See the
[macOS verification matrix](../../docs/verification/macos-device-matrix.md).

## Playback support

| Source | Native path | Current boundary |
| --- | --- | --- |
| HLS live/VOD | AVPlayer | Plain and caller-header requests are supported. |
| AVFoundation-compatible local/progressive media | AVPlayer | Files and HTTP/HTTPS sources are supported without custom headers. |
| Local MKV | FFmpeg demux + VideoToolbox | VOD with H.264/H.265 video and AAC/MP3 audio. |
| HTTP/HTTPS MKV | Bounded URLSession/FFmpeg fallback | VOD; Range seek or sequential HTTP 200 playback. |
| HTTP/HTTPS FLV | Bounded URLSession/FFmpeg fallback | Non-seekable live playback with bounded reconnect. |

Fallback video decoding is hardware-only. If VideoToolbox cannot accept the
concrete H.264 or H.265 stream, playback returns a structured decoder error; it
does not switch to software video decoding. AAC and MP3 fallback audio use
Apple's native audio conversion and output APIs. Encoded packets, decoded video
frames, and PCM samples remain native and never cross the Flutter channel.

Caller headers are supported by the package-owned HLS, MKV, and FLV network
paths. `Authorization`, `Cookie`, and `Proxy-Authorization` are removed when a
redirect or HLS resource crosses origins. Header-bearing non-HLS progressive
AVPlayer sources are rejected. Cleartext HTTP still requires an appropriate,
host-scoped App Transport Security policy. Sandboxed macOS applications must
also have the network client entitlement; header-bearing HLS uses a loopback
proxy and therefore needs the network server entitlement.

The plugin preserves logical playback state when the application resigns or
becomes active and disposes every player on application termination. Open,
play, pause, seek, live-edge seek, source replacement, rate, volume,
audio-track selection, quality constraints, state/events, and deterministic
disposal use the shared `yl_player` contract.

Subtitles, DRM, downloads, persistent cache, background audio, picture in
picture, casting, playlists, software video decoding, network-live MKV,
audio-only FLV, seeking/DVR for FLV, and application player controls are not
provided.

## Validation

From the repository root, run:

```sh
flutter test packages/yl_player_macos/test
sh tool/check_native_macos.sh
```

The native gate runs Swift tests, the binary contract, a universal release
build, architecture/link inspection, an optional Rosetta smoke launch, and five
integration suites covering HLS, local MKV, network MKV, HTTP-FLV reconnect,
and authenticated HLS. It also verifies the Release network-server entitlement
required by the authenticated-HLS loopback transport.

## FFmpeg bridge and LGPL replacement

The vendored `YlFFmpegBridge.xcframework` contains a minimized FFmpeg 9.0.1
build under LGPL-2.1-or-later. FFmpeg performs Matroska/FLV demuxing and packet
parsing only; FFmpeg networking and all FFmpeg decoders are disabled. The exact
version, checksum, signing-key fingerprint, flags, architectures, and macOS 12
deployment target are pinned in `tool/macos_ffmpeg`.
`bridge-artifact.lock` binds the reviewed Objective-C source, public header,
module map, and vendored universal binary by SHA-256; the contract gate also
requires the packaged header and module map to be byte-for-byte copies.

From this package directory, inspect and verify the committed binary with:

```sh
tool/macos_ffmpeg/build_xcframework.sh --print-contract
tool/macos_ffmpeg/test_build_contract.sh
```

Rebuild the replaceable component with Xcode command-line tools, `curl`, GnuPG,
and the standard build tools installed:

```sh
tool/macos_ffmpeg/build_xcframework.sh
```

The rebuild downloads the official archive and detached signature, verifies the
pinned signature and SHA-256 digest, builds separate `arm64` and `x86_64`
slices, and replaces the committed XCFramework. Distributions must retain
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md),
[`LICENSES/FFmpeg-LGPL-2.1-or-later.txt`](LICENSES/FFmpeg-LGPL-2.1-or-later.txt),
the lock file, signing key, and rebuild scripts so recipients can replace the
LGPL component. Obtain project-specific legal advice before distribution.

The package itself uses the BSD 3-Clause license.
