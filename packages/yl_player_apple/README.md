# yl_player_apple

Shared endorsed iOS and macOS implementation for `yl_player` 0.2. Applications
should depend on `yl_player`; Flutter registers this package on both Apple
platforms. Deployment floors are iOS 15.0 and macOS 12.0 for CocoaPods and Swift
Package Manager.

The package contains one typed registry/session lifecycle, AVPlayer routes,
controlled HLS loading, managed Matroska/FLV/MPEG-TS fallback, VideoToolbox and
AudioToolbox output, and one combined FFmpeg bridge XCFramework. AVPlayer handles
HLS and native progressive media where policy permits. Package-owned fallback
also handles VOD HEVC-in-MPEG-TS media playlists, inspected Matroska, and
network FLV with the codec and timing limits in
the [support matrix](../../docs/platform-support.md).

Apple managed networking is available only on the owned Matroska/FLV and
supported MPEG-TS HLS byte
routes. Bounded buffering uses one Player-wide assigned-byte ledger and is
available only on the managed fallback. Hardware-required video needs positive
VideoToolbox evidence before commit; AVPlayer cannot supply that evidence.
Plugin-managed audio uses process-wide ownership leases, with iOS media-playback
session/category management and macOS no-global-session behavior. See
[policy semantics](../../docs/policies.md) for enforcement and transition
restrictions.

The combined XCFramework contains iOS device, iOS Simulator, and universal
macOS slices. It uses FFmpeg 9.0.1 for Matroska/FLV/MP4/MPEG-TS/AVI demuxing,
packet parsing, DCA audio decoding, and a low-level CELT-only Opus decoder (player
integration pending); networking and video decode remain
package/system owned. Binary
redistributors must keep `THIRD_PARTY_NOTICES.md`,
`LICENSES/FFmpeg-LGPL-2.1-or-later.txt`, the artifact lock, and replacement
scripts. The notice documents verification and exact-toolchain rebuild flows.

Focused native and Flutter evidence exists for iOS Simulator and native macOS,
including strict-policy rejection and controlled hardware paths. Physical iOS,
minimum-OS, native Intel decoding, endurance, profiling, full consumer, and
release matrices remain pending final acceptance.

The iOS and macOS plugins negotiate native video surfaces for HDR precision. Managed
Dolby Vision Profile 5 retains dvcC/RPU and uses 10-bit output; in-band HEVC
configuration repair preserves track metadata. AppKitView and UiKitView use the same high-bit-depth sample renderer.
Texture-only consumers still reject managed HDR instead of displaying an invalid base layer. Code/build and native Mac probe evidence are
recorded in [HDR verification](../../docs/verification/2026-09-19-ios-hdr-dolby-vision.html);
The source colored-frame comparison passed on this Mac; active HDR highlights,
sustained playback and physical iOS acceptance remain pending.

## Dolby audio and profile limits

Managed fallback playback identifies AC-3/E-AC-3 and decodes them through
CoreAudio, preserving explicit speaker layouts in PCM and the output graph.
Unknown audio codecs report `decoder.audio_unsupported`.

Profile 8 remains unsupported on the managed fallback path.

An experimental Profile 7 path splits single-track BL/EL access units, decodes
both layers at 10-bit precision, pairs frames by timestamp, and reconstructs FEL
into floating-point HDR output. Missing EL/RPU, unsupported NLQ ranges or Dolby
display trims fail explicitly; there is no base-layer fallback. This is not full
Dolby Vision display-management or external Dolby Vision signaling support.
The reported Baidu source still fails with
`decoder.dolby_vision_fel_metadata_unsupported` because its non-neutral Level 2
trims are not implemented. See the
[FEL verification record](../../docs/verification/2026-09-20-dolby-audio-and-profiles.md).


FairPlay HLS uses a separate AVPlayer/AVContentKeySession/AVPlayerLayer route
negotiated through private schema5. It never reads decoded pixels into the
Flutter texture path. The public license client sends binary SPC/CKC through
an independently configured endpoint; media headers are not license headers.
This initial route requires explicit HLS, platform-default networking without
media headers/credentials, automatic buffering, unconstrained video and no
hardware-required policy. Protected video supports contain/center layout.
Protected audio/variant track catalogs are not yet exposed; system ABR remains
in control. Unsupported strict settings are rejected before replacing playback.

Engineering tests cover ownership, cancellation, recovery, protected view ACKs
and ordinary media regression. Authorized FairPlay playback, device protection,
HDCP and external/HDR output remain unverified without licensed test resources;
see the [DRM contract](../../docs/superpowers/specs/2026-09-26-drm-contract.md).
