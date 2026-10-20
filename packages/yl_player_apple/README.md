# yl_player_apple

Shared endorsed iOS and macOS implementation for `yl_player` 0.2. Applications
should depend on `yl_player`; Flutter registers this package on both Apple
platforms. Deployment floors are iOS 15.0 and macOS 12.0 for CocoaPods and Swift
Package Manager.

Opt-in [AirPlay video](../../docs/airplay.md) adds a system route picker, native
external-playback state, direct HLS live/VOD and bounded H.264/AAC remux
for custom VOD and RTMP/RTMPS/HTTP-FLV live. Physical receiver and CarPlay acceptance remain pending.

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
macOS slices. It uses FFmpeg 9.0.1 for Matroska/FLV/MP4/MPEG-TS/MPEG-PS/AVI demuxing,
packet parsing and DCA/Vorbis audio decoding. Pinned open-source libopus 1.6.1 supplies
SILK/hybrid/CELT Opus decoding with Matroska trim and seek preroll integration
(ordinary VOD, family 0, mono/stereo 48 kHz; active track switches rewind and trim decoder preroll); networking and video decode remain
package/system owned. Binary
redistributors must keep `THIRD_PARTY_NOTICES.md`,
`LICENSES/FFmpeg-LGPL-2.1-or-later.txt`, `LICENSES/Opus-BSD.txt`, the artifact lock, and replacement
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

Ordinary Matroska Vorbis playback uses the bundled FFmpeg native decoder for
mono/stereo at 44.1/48 kHz, with 200 ms seek/track-switch preroll and PCM target
trimming. CodecDelay up to 4096 samples is reflected once in demux timestamps;
the decoder owns overlap priming, and the presenter suppresses negative/preroll
PCM. Other leading trim, rates/channels and strict policies are rejected with
specific errors. Independent Xiph PCM reference tools are
test-only; no commercial SDK or new runtime dependency is introduced.

Ordinary seekable Matroska/WebM video tries a proven hardware decoder first.
The hardware VP9 path retains its validated Profile 0 visible-frame limits.
Default/preferred policies can then use the owned dav1d AV1 Main 8/10-bit or
FFmpeg VP9 decoder only when the exact device, OS, executable/bridge build and
stream descriptor have a measured admission entry. Hardware-required never
uses software. The production admission table is currently empty.
Controlled tests cover hidden VP9 superframes, retained image ownership,
seek/generation fences and transactional DASH Period replacement. Decoder
identity reports the actual selected implementation. Process CPU observations
continue during pause, and current/candidate players share the same budget.

Managed seekable VOD Opus/Vorbis now has real Range, retry, cancellation and
retained PCM accounting coverage. Bounded-buffer, live and hardware-required
combinations retain explicit rejection where their complete contract cannot
be enforced.

MPEG-PS/AVC VOD uses package-owned demux I/O, zero-based presentation time,
and bounded keyframe search. Live and strict managed/bounded/hardware-required
PS requests retain explicit rejection until those policy combinations are
validated. MPEG-2 video remains a diagnostic case outside the required codec set.
Automatic progressive sources inspect at most 4 KiB before choosing a container,
including familiar but wrong extensions. On older Apple systems without MIME
override support, renamed inspected MP4 uses owned sample playback.
Network MP4/MOV VOD with request headers or credentials automatically uses the
owned progressive fallback, preserving metadata during inspection, loading and
seeking. Unheadered default sources retain AVPlayer; HLS routing and progressive
live restrictions are unchanged.


P03 software candidate bridge now includes pinned dav1d AV1 Main 8/10-bit 420
and FFmpeg VP9, with independently retained codec configuration for rebuilds.
Actual reference/output surfaces and compressed copies are reserved before
allocation and stay charged through final CoreVideo release. Discovery retains
an audio-only decoder whitelist, so linking a software video decoder cannot
implicitly admit it during metadata probing. Production software admission is
still empty; controlled pipeline tests do not constitute device qualification.
The reference harness compares every visible planar sample with libaom/libvpx,
checks drain/reset and validates image lifetime after decoder destruction.

Build dependencies: Meson/Ninja (versions pinned in artifact provenance) and
pkg-config in addition to the documented Xcode/FFmpeg/Opus tools. Set
`YL_DAV1D_ARCHIVE` to the exact pinned local tarball for offline verification.
`test_software_video.sh` needs host libaom's `aomdec` and FFmpeg with libvpx
for independent test references; those tools are not product dependencies.

### Application-owned external playback (iOS)

A native host using a dedicated Flutter engine for CarPlay can obtain that
engine's published `YlPlayerApplePlugin` and call
`setExternalPlaybackActive(true)` on the main thread before loading media.
This allows existing players and players created while backgrounded to keep
playing, and sets the AVPlayer background policy to `continuesIfPossible`.
The application still owns its audio session, background audio entitlement,
external-route lifecycle, and interruption handling when using `appManaged`.
The switch applies to this engine's players, so do not enable it on the phone's
ordinary playback engine. Call `setExternalPlaybackActive(false)` after stop or
disconnect; revoking while backgrounded suspends non-AirPlay playback. Default
behavior remains unchanged. This API does not grant a system background mode or
prove physical CarPlay/video support.

The iOS `YlAppleMemoryWarningTests` covers background creation, continued
external playback, revocation, and default foreground restoration.

## Dedicated external-display engines

An iOS app that registers its own CarPlay/external-display Flutter engine can
opt ordinary video into Flutter texture composition at registration:

```swift
YlPlayerApplePlugin.register(with: registrar, useFlutterTexture: true)
```

This avoids the main-screen scale used by UIKit platform-view composition in
Flutter versions affected by external-display sizing errors. The normal generated
plugin registration still uses native video surfaces. Choose once per engine,
before creating players. This option uses Flutter's SDR texture pipeline and is
not an HDR presentation mode. FairPlay retains its separate secure native view;
this option does not change protected playback or audio/background policies.
