# Third-party notices

## FFmpeg 9.0.1

`YlFFmpegBridge.xcframework` contains a minimized build of FFmpeg 9.0.1
`libavformat`, `libavcodec`, and `libavutil`. It is used for
Matroska, FLV, MP4/MOV, MPEG-TS/PS, and AVI demultiplexing, packet parsing,
and DCA/Vorbis audio decoding. A statically linked libopus decoder handles Opus.
VideoToolbox remains the preferred video path. The controlled software bridge adds
FFmpeg VP9 and libdav1d AV1; production use requires matching measured admission. Ordinary Matroska VOD integrates container trimming and seek
preroll for family 0 mono/stereo 48 kHz Opus. Active audio-track changes reuse
seek preroll. SILK, hybrid and CELT are supported within this family-0 scope;
strict Opus policies remain unsupported.

The minimized allowlist enables `matroska,flv,mov,mpegts,mpegps,avi,h264` demuxers;
`aac,h264,hevc,mpegaudio,dca,ac3,av1,vp9` parsers; `dca,ac3,eac3,vorbis,libdav1d,vp9` decoders; the `dovi_rpu`
bitstream filter; and the `file` protocol used by package-owned custom AVIO.
FFmpeg's native Opus decoder and `libswresample` remain disabled.
Test-only host libopus provides a PCM reference independent of bridge
packet trimming and reset; it is not an independent decoder algorithm.
FFmpeg networking, protocols other than `file`,
all other decoders, encoders, muxers, filters, scaling, GPL, and nonfree
components remain disabled.

- Source: <https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz>
- Signature: <https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz.asc>
- SHA-256: `cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635`
- Release-key fingerprint: `FCF986EA15E6E293A5644F10B4322F04D67658D8`
- License: LGPL-2.1-or-later; see `LICENSES/FFmpeg-LGPL-2.1-or-later.txt`.

The combined `darwin/yl_player_media_core/Frameworks/YlFFmpegBridge.xcframework`
contains `ios-arm64` (iOS 15.0+), `ios-arm64_x86_64-simulator` (iOS 15.0+),
and `macos-arm64_x86_64` (macOS 12.0+). The macOS framework retains its
versioned `Versions/A` layout. The shared bridge source and public header are
in `darwin/native/YlFFmpegBridge`.

From the repository root, the canonical builder is:

```sh
sh packages/yl_player_media_core/tool/apple_ffmpeg/build_xcframework.sh --print-contract
python3 packages/yl_player_media_core/tool/apple_ffmpeg/verify_artifact.py
sh packages/yl_player_media_core/tool/apple_ffmpeg/build_relocated_xcframework.sh --rebuild-check
```

`verify_artifact.py` is the consumer verifier used by CI. It checks the exact
accepted lock (including recorded builder provenance), all recorded recipe,
source, license and key inputs, configuration, complete artifact bytes and
symlink targets, the signed FFmpeg source receipt and pinned Opus/dav1d archive hashes
without requiring the verifier machine to match the original builder. It never compiles, updates a lock, or changes artifact bytes.
`YL_FFMPEG_ARCHIVE`, `YL_FFMPEG_SIGNATURE`, `YL_OPUS_ARCHIVE`, and `YL_DAV1D_ARCHIVE` accept
existing local source inputs;
otherwise the verifier obtains the exact pinned public archives and FFmpeg signature.

`--rebuild-check` requires the exact toolchain recorded in the lock, builds all
five targets in a fresh temporary directory, and compares every byte and
symlink target. The original self-hashed builder's `--verify` remains a
historical exact-host interface; use the separate consumer verifier above on
other hosts. Neither interface refreshes the lock. An accepted replacement
artifact requires reviewing and explicitly updating the consumer verifier's
accepted-lock digest along with its new provenance.

To rebuild or replace the LGPL component, use an absent output directory:

```sh
sh packages/yl_player_media_core/tool/apple_ffmpeg/build_xcframework.sh --build-candidate /tmp/yl-ffmpeg-candidate
sh packages/yl_player_media_core/tool/apple_ffmpeg/build_xcframework.sh --rebuild-check /tmp/yl-ffmpeg-candidate
```

After reviewing the clean rebuild comparison and all provenance changes,
replace `darwin/yl_player_media_core/Frameworks/YlFFmpegBridge.xcframework` with the
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

## libopus 1.6.1

The same XCFramework statically links the official libopus 1.6.1 decoder. It
decodes SILK, hybrid and CELT at 48 kHz for OpusHead v1, mapping family 0,
mono/stereo. Multistream mappings and multichannel output are not enabled by
this bridge. SIMD/assembly/runtime dispatch and optional neural extensions
are disabled for a reproducible scalar build; unused encoder code is removed
by static linking and dead stripping. No commercial SDK or host libopus dylib
is required at runtime.

- Source: <https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz>
- SHA-256: `6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1`
- License: BSD; exact upstream notice and patent declaration references in
  `LICENSES/Opus-BSD.txt`. Preserve it with redistributed binaries.

The archive is hash-verified against `opus-1.6.1.lock`; no detached-signature
verification is claimed for Opus. `YL_OPUS_ARCHIVE` may supply the pinned local
archive. The canonical builder above builds both dependencies for all five
targets, compares upstream COPYING with the tracked license, and records
source pins and recipe inputs in the immutable artifact lock.

## Local FFmpeg correction

`tool/apple_ffmpeg/patches/vorbis-aarch64-zero-coupling.patch` corrects the
ARM64 inverse Vorbis coupling zero-magnitude branch to agree with the scalar
`magnitude > 0` rule. The signed upstream archive remains unchanged; the build
applies the separately hashed patch with zero fuzz. Its bytes are part of the
immutable artifact input manifest. Independent Xiph PCM comparisons and actual
SIMD tail tests cover the correction. The internal H.264 demux probe is enabled
for PS streams lacking a program-stream map; standalone raw H.264 remains outside
the bridge's accepted container routes.

## Test-only Vorbis reference

`tool/apple_ffmpeg/build_vorbis_reference.sh` builds hash-pinned official
[libogg 1.3.6](https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.xz)
and [libvorbis 1.3.7](https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz)
in a fresh external directory, retaining their upstream BSD notices there.
These libraries only generate owned fixtures and independently compare PCM;
they are not linked into the shipped framework. Runtime Vorbis uses FFmpeg's
native decoder. Ordinary Matroska support is limited to mono/stereo at
44.1/48 kHz, zero CodecDelay, no leading trim, and bounded headers/packets.
Seek and active track changes use 200 ms preroll; strict policies remain
unsupported. This does not establish multichannel or physical output acceptance.


## dav1d 1.5.3

The minimal software AV1 candidate statically links VideoLAN dav1d 1.5.3,
BSD-2-Clause, with COPYING reproduced in `LICENSES/dav1d-BSD.txt`.
Official source: <https://downloads.videolan.org/pub/videolan/dav1d/1.5.3/>.
SHA-256: `732010aa5ef461fa93355ed2c6c5fedb48ddc4b74e697eaabe8907eaeb943011`.
Static release/PIC builds disable tools, tests, examples and documentation;
ARM64 assembly is enabled, x86_64 assembly disabled (unmeasured Intel software
performance is not inferred from ARM64). Meson/Ninja versions are in provenance.

`patches/dav1d-owned-pictures.patch` redirects the FFmpeg adapter's picture
allocation to the codec client's `get_buffer2`, retaining its single AVBufferRef
ownership contract. This accounts decoder references through their final release.
The bridge also accounts input copies and published NV12/P010 buffers. Codec
bookkeeping/worker overhead remains a separately measured process cost, not a
claimed hard RSS bound. Film grain stays enabled. CoreVideo images keep full
8/10-bit storage, range and colour/static-HDR attachments; incompatible changes
require reconfiguration. Native C calls cannot be preempted by a timing budget.

Test-only libaom and libvpx produce independent planar reference outputs; neither
is linked into the distributed framework. Short test success never creates a
production software admission entry.

The relocated package uses `build_relocated_xcframework.sh` for checks of the accepted artifact. It forwards the relocated artifact and unchanged lock to the original, self-hashed `build_xcframework.sh` recipe; the recipe and recorded provenance remain byte-for-byte unchanged. Explicit candidate commands continue to use the original recipe.
