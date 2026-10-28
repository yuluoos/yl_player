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

For known on-demand Media3 periods, loading duration targets follow playback
speed, with at most a 2x multiplier. For example, a 15-second media target becomes
22.5 seconds at 1.5x. The allocator byte target and memory-pressure reduction do
not increase; they still stop further loading decisions first. These are
scheduling targets, not a hard limit on total process/native/decoder memory.
Live, dynamic, unknown and ad periods retain the original duration targets.
When Android reports a positive `memoryClass`, the compressed-media byte target
is additionally capped at one eighth of that heap class (64 MiB heap → 8 MiB,
128 MiB → 16 MiB). This cap only lowers tier/user targets, applies to preparation
and live-mode changes, and remains in force after memory-pressure recovery.
Unknown heap class retains the existing tier policy. The remaining heap allowance
is not a guarantee of free memory or a bound on native allocations. If the byte
budget fills before the startup/rebuffer duration target, already-buffered media
may start draining it; an empty buffer does not qualify for this fallback.

Constrained clear non-DASH TVs use a 750ms PCM AudioTrack target, adding no more
than 256 KiB above Media3's normal size (aligned to complete frames). Platform
minimums, passthrough/offload sizing and software speed processing are preserved.
This cushion can absorb short scheduling delays; it cannot fix sustained network
or decoding throughput deficits. Legacy vendor codecs retain Media3's default
queue mode; asynchronous queueing and platform audio speed changes are not forced
without device qualification. Tunneling remains limited to the existing 1x path.

While active playback above 1x develops new rebuffer, frame-drop or audio-underrun
events, `YlPlayer` emits a numeric `speedHealth` log at most once per 10 seconds.
`bufferedMediaMs` and `bufferedPlayoutMs` distinguish media duration from playback
time; allocator bytes are separate from decoded/native memory. `tunnelingRequested`
describes selection intent, not proof that the hardware tunnel is active. No media
URL, headers, credentials or exception text is logged. The log only reports
observations and never changes speed, track selection or the playback position.
`supplyEvidence=byteBudgetReached` identifies an allocator scheduling limit.
`belowVideoDemand` requires a short buffer, active loading and a recent measured
transfer rate below the selected video's bitrate multiplied by speed; it is a
hint, not proof of a network fault. `measured`, `notLoading` and `unknown` avoid
claiming available capacity from idle or missing data. Transfer measurements
expire after 10 seconds; `bufferTrend`/`consumedMediaMs` use one previous snapshot
and reject pauses, speed changes and obvious position discontinuities.

Health windows use actual Media3 rendered/dropped output counters, including
renderer replacement, rather than wall time multiplied by nominal frame rate.
Pause clears the observation window without resetting recovery cooldowns.
Buffering contributes no invented rendered frames; its actual duration remains
in the separate rebuffer health check and is counted only once across windows.
Missing decoder counters do not produce a guessed frame-drop ratio.

Physical low-end TV acceptance remains required: compare the same local file and
cloud-drive file at 1x/1.5x, capture these logs alongside process memory, and check
seek, pause/resume, return to 1x and memory-pressure handling. JVM regression tests
do not establish MT8176/MT9652 smoothness or firmware compatibility.

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
