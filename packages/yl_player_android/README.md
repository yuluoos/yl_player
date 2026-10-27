# yl_player_android

Endorsed Android implementation for `yl_player` 0.2. Applications should depend
on `yl_player`; Flutter registers this package automatically. It targets Android
7.0/API 24 or later and uses Media3 1.11.0. Android 7–9 televisions negotiate
an optional clear-video SurfaceView through the existing native-surface SPI.
It uses explicit hybrid composition beneath Flutter controls/subtitles. Media3
requests supported audio/video tunneling at normal speed on this output; other
speeds disable tunneling. Texture startup remains available before the view is
mounted, and the managed fallback continues to use its texture. Other devices
retain texture presentation. This uses internal Android schema 8: rebuild the
Dart and native packages together.
On these legacy TVs, clear non-DASH E-AC-3 audio can use the existing FFmpeg
codec through a bounded Media3 audio renderer when the system renderer does
not support it. Video stays in Media3, retaining its clock and supported
tunneling. Output is stereo PCM16; source video resolution is unchanged.
Encrypted, JOC, unsupported sample rates and unknown channel counts are not
admitted by this adapter. Rebuild all JNI ABIs with the matching source manifest.

Media3 remains the primary route. When its extractor cannot expose video or its
decoder cannot initialize, the package makes one managed fallback attempt:
FFmpeg demuxes MP4/MOV, Matroska/WebM, FLV, MPEG-TS and MPEG-PS into
H.264/H.265 packets for proven hardware MediaCodec. PS uses owned demux because
Media3's PS extractor can silently expose only its audio. AVI and AV1 remain on
Media3. Decoder metadata uses a versioned JNI contract; mismatched libraries
fail explicitly.

Owned H.264/H.265 software decoding requires an exact measured device, OS,
APK/native-build and stream admission record. The production table is empty.
Controlled tests exercise 8-bit 4:2:0 limited-range BT.601 output, actual frames,
shared reference/packet/renderer accounting and resource exhaustion. Other
bit depths/color paths are rejected instead of silently converted. Geometry
limits alone never authorize software decoding.
AAC, MP3, AC-3, E-AC-3, DTS, FLAC, Opus, and Vorbis audio can be decoded to PCM.

The fallback accepts local files, Android content URIs, progressive HTTP, and
HLS VOD/live, including standard AES-128 HLS. It deliberately rejects Widevine,
SAMPLE-AES, and DRM bypass. FFmpeg networking, encoders, filters, GPL, and
nonfree components are disabled; the LGPL shared library is replaceable for
arm64-v8a, armeabi-v7a, and x86_64. Build and replacement inputs are under
`tool/android_ffmpeg`, with license notices under `LICENSES`.

The Media3 route accepts local files, Android content URIs, HLS, HTTP-FLV, and
progressive containers subject to extractor, codec, device, and server support.
Both platform-default and Android managed networking are implemented with
same-origin credential enforcement. Exact managed timeout/retry behavior is
documented in the repository [policy guide](../../docs/policies.md). Exact
bounded-buffer requests are rejected; built-in buffer strategies remain tuning
goals.

Decoder policies are honored per Player with an optional per-Load override.
All policies try positively identified hardware first. Hardware-required never
uses software. Default/preferred can use the separately admitted owned fallback;
opaque MediaCodec software is not admitted. On API24–28, hardware-preferred
also permits recognized vendor decoder names, while reporting their evidence as
unknown. Hardware-required still needs positive platform evidence from API29+.
API24 remains the binary minimum, not a promise that every older decoder works. A capability snapshot is conservative and
does not prove that a codec will initialize for arbitrary media.

Plugin-managed audio uses one focus owner and preserves current playback intent
through replacement, transient focus loss, foreground reconstruction, Stop,
and Dispose. App-managed audio leaves focus decisions to the application. One
active Android video decoder lease is granted at a time; memory and lifecycle
events can quiesce and reconstruct the active session.

The implementation exposes Media3 state, tracks, geometry, decoder mode,
metrics, correlated events, and safe `YlFailure` values through the v0.2 SPI.
Production VP9/AV1 software admission, downloads, persistent media cache and
background audio remain unavailable. Subtitle routes have their own documented
format and protection constraints. See the [support matrix](../../docs/platform-support.md) for route
limits and the outstanding physical Android endurance evidence.

The schema5 Widevine DASH route consumes `YlWidevineDrm` explicitly. Protected
playback requires API29+ for hardware codec evidence, system Widevine/L1,
secure output and usable keys. It uses a secure native SurfaceView with explicit
hybrid composition; it cannot fall back to FFmpeg, software video or a texture.
The current protected view supports contain/center layout. License POST runs
through the controller's separate bounded Dart client; credentials are not
copied to native media requests. Upgrade Dart/native packages together and
rebuild the app. These engineering paths have local state-machine, wire, HTTP
and widget tests; authorized device decryption/display protection is still
unverified. See the [DRM contract](../../docs/superpowers/specs/2026-09-26-drm-contract.md).
