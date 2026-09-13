# yl_player_android

Endorsed Android implementation for `yl_player` 0.2. Applications should depend
on `yl_player`; Flutter registers this package automatically. It targets Android
7.0/API 24 or later and uses Media3 1.11.0 with a Flutter texture.

Media3 remains the primary route. When its extractor cannot expose video or its
decoder cannot initialize, the package makes one managed fallback attempt:
FFmpeg demuxes MP4/MOV, Matroska/WebM, FLV, and MPEG-TS into H.264/H.265 packets
for MediaCodec when hardware supports the stream; otherwise FFmpeg software
decodes H.264 or H.265 video up to 720p30 into the existing Flutter texture.
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
System-default retains the Media3 order, hardware-preferred ranks hardware but
retains fallbacks, and hardware-required filters candidates and verifies the
initialized MediaCodec for video. A capability snapshot is conservative and
does not prove that a codec will initialize for arbitrary media.

Plugin-managed audio uses one focus owner and preserves current playback intent
through replacement, transient focus loss, foreground reconstruction, Stop,
and Dispose. App-managed audio leaves focus decisions to the application. One
active Android video decoder lease is granted at a time; memory and lifecycle
events can quiesce and reconstruct the active session.

The implementation exposes Media3 state, tracks, geometry, decoder mode,
metrics, correlated events, and safe `YlFailure` values through the v0.2 SPI.
VP9/AV1 software decoding, subtitles, downloads, persistent media cache, and
background audio are outside
the package. See the [support matrix](../../docs/platform-support.md) for route
limits and the outstanding physical Android endurance evidence.
