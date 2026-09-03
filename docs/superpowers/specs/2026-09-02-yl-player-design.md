# yl_player Architecture Design

Date: 2026-09-02

## 1. Purpose

`yl_player` is an open-source Flutter playback-kernel package for TVBox-style applications. It provides a stable Dart API and native Android and iOS playback implementations while leaving source parsing, playlists, application UI, and content services to the host application.

The first supported operating-system versions are Android 7.0 (API 24) and iOS 15. The design prioritizes hardware decoding, bounded memory use, predictable failure, and long-running playback on low-memory Android TV devices. It does not claim that every codec, profile, resolution, or damaged stream can play smoothly on every device.

## 2. Scope

### 2.1 First-release inputs

- Local files through ordinary paths and `file://` URIs.
- Android content-provider media through `content://` URIs.
- HTTP and HTTPS progressive video on demand, including redirects, byte ranges, and custom request headers.
- HLS live and video-on-demand streams.
- HTTP-FLV live streams.

The initial container targets are MP4/M4V/MOV, Matroska/MKV, WebM, MPEG-TS, MPEG-PS, and FLV. AVI is a compatibility target without a guarantee of accurate seeking.

The cross-platform priority video codecs are H.264/AVC and H.265/HEVC. VP8, VP9, AV1, MPEG-2 Video, and MPEG-4 Part 2 are available only when the selected platform path and device capabilities support the concrete profile, level, resolution, and frame rate.

The initial audio targets are AAC, MP3, AC-3, E-AC-3, Opus, Vorbis, FLAC, and PCM. DTS is not part of the default build. It can be evaluated later as a separately documented build option after distribution and regional licensing review.

### 2.2 Explicit exclusions

The first release does not include:

- Subtitles or subtitle-track selection.
- DRM, including Widevine and FairPlay.
- Offline downloads, persistent media cache, or download management.
- Casting, AirPlay-specific controls, or picture-in-picture orchestration.
- RTMP ingest, RTSP, SRT, WebRTC, or BitTorrent.
- TVBox source rules, web sniffing, JSON/M3U parsing, URL resolution, or alternate-line selection.
- Application playback controls, episode UI, recommendations, accounts, or analytics upload.

The host application resolves a playable media URL and supplies it, along with any User-Agent, Referer, Cookie, and other HTTP headers, to `yl_player`.

## 3. Architectural Decisions

### 3.1 Hybrid native backends

The package uses platform-native main paths and a restricted FFmpeg-based fallback path:

```text
Flutter application UI
        |
        v
yl_player Dart API and state model
        |
        v
typed platform messages
        |
   +----+---------------------------+
   |                                |
Android main path                  iOS main path
Media3 / ExoPlayer                 AVPlayer
MediaCodec -> Surface              AVPlayer -> CVPixelBuffer
   |                                |
   +----- unsupported media --------+
                  |
      bounded libavformat fallback
                  |
        +---------+---------+
        |                   |
 Android MediaCodec       iOS VideoToolbox
 Android AudioTrack       native iOS audio output
```

Android uses Media3 first because it already includes extractors for the principal TVBox containers and provides adaptive-streaming, buffering, decoder, track-selection, and error-handling infrastructure. FFmpeg must not redundantly demux every Android source.

iOS uses AVPlayer for supported MP4/MOV and HLS content. Media such as MKV, WebM, and HTTP-FLV that AVPlayer cannot handle uses libavformat for demuxing, VideoToolbox for supported compressed video, and native audio output with a narrowly built FFmpeg audio-decoding layer where necessary.

FFmpeg is not the default video decoder. Demuxing with FFmpeg does not imply software video decoding. The first release does not promise software video decoding; unsupported 4K, 10-bit, profile, or level combinations return a structured capability error so the host can switch to a lower-quality stream.

### 3.2 Package decomposition

The project is a package-separated federated Flutter plugin:

- `yl_player`: app-facing controller, source/configuration models, immutable state, public events, and the texture widget.
- `yl_player_platform_interface`: typed platform contract and platform-registration boundary.
- `yl_player_android`: Media3, MediaCodec, Surface, AudioTrack, Android lifecycle, and Android fallback integration.
- `yl_player_ios`: AVPlayer, VideoToolbox, CoreVideo, iOS audio/lifecycle, and iOS fallback integration.

The app-facing package endorses the Android and iOS implementations. FFmpeg remains an internal native dependency of the platform packages and has no public Dart API.

### 3.3 Control and media-data boundaries

Typed platform messages carry control commands, identifiers, configuration, immutable state snapshots, and discrete events. They never carry encoded media packets, decoded YUV frames, CVPixelBuffers, or PCM buffers.

Command acknowledgements are asynchronous. State-change events are emitted immediately when semantics change; playback position updates are throttled to a documented low frequency. Native code owns the authoritative playback state, and Dart keeps an immutable mirror for UI consumption.

Each Flutter engine receives independent plugin state. Player instances are keyed by opaque IDs and are disposed idempotently. Native global player singletons are prohibited. Multiple allocated players are permitted, but the default resource policy allows only one active video decoder; activating another instance pauses and releases the previous instance's video-decoder resources.

## 4. Playback Routing

### 4.1 Source selection

The source model includes a URI, live/VOD intent, optional format hint, headers, and network policy. A hint helps route sources with missing or misleading file extensions and MIME types, but native probing remains authoritative.

Android initially routes all supported local, progressive HTTP, HLS, and HTTP-FLV media to Media3. iOS initially routes supported MP4/MOV and HLS media to AVPlayer only when the request requirements are compatible with AVFoundation. An iOS source that requires arbitrary headers on playlists or every media segment routes to the fallback network/demux path; the implementation must not depend on undocumented AVFoundation header keys. Known unsupported source/container combinations go directly to the platform fallback rather than intentionally failing the main player first.

The package accepts cleartext HTTP URIs because they remain common in TVBox deployments, but it cannot silently weaken application transport security. The host Android application must opt into the required Network Security Configuration, and the host iOS application must declare narrowly scoped App Transport Security exceptions when a source cannot use HTTPS. Invalid TLS certificates are rejected by default.

### 4.2 Fallback policy

Fallback is eligible only for:

- An unrecognized or unsupported container.
- A decoder-unsupported result for which another native decode path is known to exist.
- A decoder initialization/runtime failure explicitly classified as eligible by the platform implementation or device-quirk policy.

HTTP authorization errors, missing files, DNS failures, timeouts, and general network errors never trigger engine fallback. Each `open` operation may automatically switch engines at most once. This prevents loops and produces a deterministic final error.

The package ships a versioned local quirk table for verified device/decoder failures. Applications may inject additional routing overrides, but the package does not download remote rules.

## 5. Public Dart Contract

The intended public shape is:

```dart
final player = YlPlayerController(
  configuration: const YlPlayerConfiguration(
    bufferMode: BufferMode.automatic,
    decoderPolicy: DecoderPolicy.preferHardware,
  ),
);

await player.open(
  YlMediaSource.network(
    Uri.parse(url),
    isLive: true,
    formatHint: YlFormatHint.hls,
    headers: const <String, String>{},
  ),
);

await player.play();
await player.pause();
await player.seekTo(position);
await player.seekToLiveEdge();
await player.setPlaybackSpeed(1.25);
await player.setVolume(0.8);
await player.selectAudioTrack(trackId);
await player.setQualityConstraint(
  const YlQualityConstraint(maxHeight: 1080),
);
await player.dispose();
```

The controller exposes:

- `state`, an immediately readable immutable snapshot.
- `states`, a broadcast stream of semantic state changes and throttled position updates.
- `events`, a broadcast stream for first frame, track changes, retries, fallback, and errors.
- Audio and video track descriptions.
- A device/source capability report.
- An internal texture identifier consumed by `YlPlayerView`.

`YlPlayerView` renders only the video texture and contains no controls. Scaling and layout are Flutter concerns and do not cause decoded-frame copies through Dart.

### 5.1 State machine

The semantic state machine is:

```text
idle -> opening -> ready -> playing <-> paused
                       \       ^
                        buffering
                            |
                     completed / error
```

Opening another source cancels the previous open operation, clears old events and buffers, and assigns a new source generation. Native callbacks from an older generation are ignored.

Live state includes whether playback is at the live edge, current live offset, seekability, and the available DVR window. HTTP-FLV is normally non-seekable. HLS seek is enabled only when the manifest provides a DVR window.

## 6. Rendering and Synchronization

Android creates a Flutter-managed `TextureRegistry.SurfaceProducer`. Media3 and fallback MediaCodec instances render directly to its Surface. Surface recreation must not recreate the complete player or lose the logical position.

iOS implements `FlutterTexture` and retains native CVPixelBuffer references only for the duration required by the Flutter raster thread. AVPlayer-backed and VideoToolbox-backed frame providers conform to one internal rendering interface. Decoded image data is never converted to a Dart object.

The native backend owns the media clock. Audio is the default master clock when present; video presentation follows media timestamps, and late non-key video frames may be dropped within bounded policy. Seek flushes decoder, packet, and audio queues, starts from a suitable keyframe, and suppresses stale pre-seek callbacks.

## 7. Buffering and Low-Memory Behavior

Buffer profiles are `lowLatency`, `balanced`, `stable`, and `custom`. `automatic` chooses among them using source type, live/VOD intent, memory class, decoder capability, observed throughput, and buffer health.

Every native queue has both a duration ceiling and byte ceiling. Reading stops when either ceiling is reached. The fallback pipeline bounds compressed video and audio packet queues separately. It does not add an arbitrary second queue of decoded video frames in front of the hardware decoder.

For live playback, `lowLatency` keeps small queues and may drop late non-key video frames when the live offset exceeds policy. For VOD, `stable` may buffer further ahead but remains byte bounded.

Android `onTrimMemory` and iOS memory-warning callbacks reduce target buffers, clear nonessential probe/index caches, and release inactive decode resources. Background transitions release the video output and nonessential queues according to application lifecycle policy while retaining enough logical state to resume.

Device capability decisions prioritize codec-advertised profile, level, dimensions, frame rate, performance information when available, and actual decoder initialization. RAM, CPU count, ABI, OS version, and model-specific quirks are secondary inputs. A device that cannot safely hardware-decode the selected stream receives `decoderUnsupported` rather than an automatic 4K software-decoding attempt.

## 8. Network and Recovery

The network configuration supports connection/read timeouts, a finite retry count, exponential backoff with jitter, redirect limits, request headers, and a host-application cancellation signal.

After a live reconnection:

- HLS resumes near the newest safe live position.
- HTTP-FLV starts from the first usable keyframe on the new connection.
- Old packet and audio queues are discarded.
- Decoder timestamp state and the media clock are re-established before presentation resumes.

The player reports that a line failed but does not select a backup URL. Alternate-line selection remains a host-application responsibility.

## 9. Errors and Observability

Public errors are classified as `source`, `network`, `container`, `decoderUnsupported`, `decoderFailure`, `render`, `resource`, `cancelled`, or `internal`. Errors contain a stable package code, a safe human-readable message, relevant source/engine metadata, and an optional platform diagnostic string. Platform exception text is not used as a stable application contract.

The package makes the following local metrics available without uploading them:

- Open-to-ready and time-to-first-frame durations.
- Rebuffer count and accumulated rebuffer duration.
- Dropped video frames and audio underruns.
- Estimated bitrate and current buffer duration/bytes.
- Decoder name, hardware/software classification, and actual output resolution.
- Live offset, reconnect count, retry events, and fallback decision.

The host application decides whether and where to record metrics. `yl_player` performs no analytics or telemetry network requests.

## 10. Implementation Milestones

### Milestone 1: Public foundation

Create the federated packages, typed platform contract, controller lifecycle, state/error/event models, texture widget, fake backend, unit tests, API documentation, and example shell. No decoder is claimed functional until a native milestone passes its acceptance tests.

### Milestone 2: Android main path

Implement Media3 local/progressive HTTP/HLS/HTTP-FLV playback, headers, audio tracks, seeking, live-edge state, bounded buffering, reconnection, SurfaceProducer rendering, capability reporting, and lifecycle cleanup. Validate Android 7, 32-bit ARM, and low-memory behavior.

### Milestone 3: iOS main path

Implement AVPlayer local/progressive HTTP/HLS playback for AVFoundation-compatible requests, route sources requiring arbitrary per-request headers to the fallback path, and add audio tracks, seeking, live state, texture rendering, audio-session integration, and foreground/background lifecycle behavior on iOS 15 and later.

### Milestone 4: Extended fallback path

Add reproducibly built and minimized libavformat/libavcodec dependencies. Connect compressed video to Android MediaCodec and iOS VideoToolbox, and decoded audio to AudioTrack and native iOS output. Enable the approved MKV, WebM, TS, and HTTP-FLV fallback combinations without changing the stable Dart contract.

### Milestone 5: Device hardening and publication

Complete the physical-device and adverse-media matrix, memory/leak profiling, package documentation, example application, third-party notices, reproducible native-build documentation, and pub.dev dry runs.

## 11. Verification Strategy

### 11.1 Automated tests

- Dart unit tests cover state transitions, generation cancellation, command ordering, idempotent disposal, retry decisions, event throttling, and error mapping.
- Platform-contract tests verify serialization compatibility and platform-package conformance.
- Android unit and instrumentation tests cover source routing, Media3 events, Surface recreation, memory callbacks, headers, bounded retry, and repeated lifecycle operations.
- iOS unit and integration tests cover routing, AVPlayer observation, FlutterTexture lifetime, PixelBuffer ownership, audio-session transitions, and repeated lifecycle operations.
- Native fallback tests feed deterministic packet sequences with discontinuities, corrupt packets, missing timestamps, seek flushes, and reconnection boundaries.

### 11.2 Media and device matrix

The maintained test corpus includes licensed or generated H.264 and H.265 samples at 720p, 1080p, and 4K; supported audio combinations; local MP4/MKV/TS; progressive HTTP; HLS live/VOD; and HTTP-FLV live. It also includes 403/404 responses, redirects, missing Range support, misleading MIME types, slow responses, random disconnects, timestamp jumps, and corrupt packets.

Physical validation includes at least:

- An Android 7, 2 GB, 32-bit ARM TVBox.
- An Android 7 or later arm64 TVBox.
- A current Android phone for modern decoder and lifecycle behavior.
- An iOS 15-capable low-end physical iPhone.
- A current iPhone for modern decoder behavior.

### 11.3 Initial quality gates

Under a controlled local-file or LAN test environment:

- A representative 2 GB Android 7 device hardware-decodes 1080p30 H.264 for two hours without crash or out-of-memory termination.
- After warm-up, dropped frames remain below 1 percent and measured A/V skew remains approximately within 80 milliseconds for the controlled corpus.
- One hundred `open -> play -> dispose` cycles show no continuing staircase growth in memory.
- Local time to first frame is at most 1.5 seconds, and LAN live/VOD time to first frame is at most 3 seconds for the controlled corpus.
- A forced live disconnect either recovers according to policy or ends with a classified error after finite retries.
- Test reports record device model, OS, ABI, media properties, selected engine, decoder name, and hardware/software status.

These are release gates for named test devices and media, not universal guarantees for arbitrary hardware or sources.

## 12. Distribution and Compliance

The four federated packages are published to pub.dev. Chinese users may consume synchronized packages through the CFUG mirror at `pub.flutter-io.cn`; the mirror is not treated as a separate publication authority.

Android initially targets `armeabi-v7a` and `arm64-v8a`. Emulator-only native artifacts are kept out of production dependencies where practical. iOS native artifacts include the required device and simulator slices. Platform packages are kept below pub.dev size limits; if minimized native artifacts cannot meet the limits, they move to versioned native repositories referenced by Gradle and CocoaPods/Swift Package Manager rather than being hidden downloads during Flutter package installation.

FFmpeg builds are reproducible, version pinned, checksummed, and configured with GPL and nonfree components disabled. Only required protocols, demuxers, parsers, and audio decoders are enabled. Source offers, notices, relinking obligations, and all transitive licenses are documented. Codec patent and store-distribution obligations require separate legal review before release; an open-source software license does not grant all patent rights.

Each package includes a license, changelog, README, API documentation, repository metadata, and a working example. Every release runs tests, static analysis, native builds, package-size checks, and `flutter pub publish --dry-run` before publication.

## 13. Primary Technical References

- [Flutter package and federated-plugin development](https://docs.flutter.dev/packages-and-plugins/developing-packages)
- [Flutter Android `TextureRegistry`](https://api.flutter.dev/javadoc/io/flutter/view/TextureRegistry.html)
- [Flutter iOS `FlutterTextureRegistry`](https://api.flutter.dev/ios-embedder/protocol_flutter_texture_registry-p.html)
- [Android Media3 supported formats](https://developer.android.com/media/media3/exoplayer/supported-formats)
- [Android Media3 customization](https://developer.android.com/media/media3/exoplayer/customization)
- [Apple AVFoundation](https://developer.apple.com/av-foundation/)
- [Apple VideoToolbox](https://developer.apple.com/documentation/videotoolbox)
- [Dart package publication requirements](https://dart.dev/tools/pub/publishing)
- [Flutter use in China and the CFUG mirror](https://docs.flutter.cn/community/china/)

## 14. Success Definition

The first stable release succeeds when a Flutter TVBox-style application can use one documented API to play the approved local, VOD, HLS, and HTTP-FLV sources on Android 7+ and iOS 15+; render through Flutter textures; select audio tracks; seek when the source permits; recover from bounded live-stream failures; report actionable capability/errors; and pass the named physical-device memory and playback gates.

Broad format support means the package can parse the listed containers and select an available hardware decode path. It never means every codec/profile/resolution combination is guaranteed on every device.
