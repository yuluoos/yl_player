# iOS Native Fallback Design

Date: 2026-09-03

## 1. Goal and first deliverable

Add a bounded native fallback backend to `yl_player_ios` without changing the
public Dart API. The first retained vertical slice plays local Matroska (`.mkv`)
files containing H.264/AVC or H.265/HEVC video and AAC-LC audio on iOS 15 or
later. Video decoding must use VideoToolbox hardware decoding; there is no
software-video fallback.

The slice includes open, first frame, play, pause, seek, volume, playback speed,
audio-track selection, state/metrics, source-generation cancellation,
background and memory-warning release, repeated open/dispose, and Flutter
Texture output. Subtitles remain disabled and unexposed.

HTTP-FLV, remote MKV, WebM, MPEG-TS/PS, AVI, non-AAC audio, DRM, and software
video decoding are later slices. Until each is implemented, it continues to
return the existing structured fallback-required or decoder-unsupported error.

## 2. Considered approaches

### Selected: minimized FFmpeg demux plus Apple decode/render APIs

Pin FFmpeg 9.0.1 and compile a replaceable dynamic XCFramework containing only
the required demuxing and packet-support code. FFmpeg identifies streams and
reads Matroska packets. CoreMedia constructs compressed video sample buffers,
VideoToolbox performs required-hardware video decode, and AudioToolbox plus
AVAudioEngine handle AAC and PCM playback.

This keeps container compatibility separate from device codec capability,
avoids copying frames through Dart, and makes it impossible for this build to
silently start an FFmpeg software video decoder.

### Rejected: enable FFmpeg video decoders

This would broaden codec coverage quickly, but creates high CPU, heat, memory,
and frame-copy costs on low-end devices. It also contradicts the package's
hardware-first failure policy.

### Rejected: third-party all-in-one playback framework

An all-in-one binary reduces initial code, but gives the package weak control
over ABI reproducibility, queue ceilings, licensing features, stale callbacks,
and publication size. The project keeps a narrow owned bridge instead.

AVFoundation alone is not an alternative because AVPlayer does not provide the
required Matroska demux path.

## 3. Dependency and distribution policy

The build pins the official FFmpeg 9.0.1 source archive and records its URL,
archive checksum, source commit/release identity, configure arguments, compiler
versions, deployment target, enabled components, and local patches in a lock
manifest. The build must be reproducible for:

- `iphoneos`: arm64
- `iphonesimulator`: arm64 and x86_64
- minimum deployment target: iOS 15.0

The initial configure allowlist enables the Matroska demuxer, file protocol,
H.264/HEVC/AAC parsers and packet utilities needed by the bridge. It does not
enable FFmpeg programs, devices, filters, encoders, muxers, network protocols,
GPL components, nonfree components, or H.264/HEVC software decoders. AAC decode
uses Apple audio APIs in the first slice; FFmpeg audio decoders and
`libswresample` are not included until a non-AAC slice requires them.

The output is a dynamically linked `YlFFmpegBridge.xcframework`, not a
machine-specific prebuilt downloaded at application-build time. CocoaPods uses
`vendored_frameworks`; Swift Package Manager uses a local binary target. Both
integration paths consume the same checked-in artifact.

Before publishing a package containing the binary, the repository includes:

- the FFmpeg license texts and a third-party notice;
- the exact corresponding source archive location and checksum;
- the reproducible build script and any patch files;
- instructions for replacing/rebuilding the dynamic framework;
- a documented legal-review gate for the final distribution method.

The build follows FFmpeg's own LGPL checklist: `--enable-gpl` and
`--enable-nonfree` are forbidden. This design is an engineering constraint, not
legal advice.

References:

- [FFmpeg 9.0.1 download](https://www.ffmpeg.org/download.html)
- [FFmpeg license and legal considerations](https://ffmpeg.org/legal.html)
- [VideoToolbox](https://developer.apple.com/documentation/videotoolbox)
- [Audio Queue Services](https://developer.apple.com/documentation/audiotoolbox/audio-queue-services)

## 4. Package structure

The existing monolithic Swift implementation is split along ownership
boundaries:

```text
YlPlayerIosPlugin.swift        channel registration and player registry
YlIosPlayer.swift              source router and one-active-backend session
YlAvPlayerBackend.swift        existing AVPlayer main path
YlFallbackBackend.swift        fallback state machine and orchestration
YlVideoToolboxDecoder.swift    format descriptions and VT decode session
YlAudioRenderer.swift          AAC conversion, AVAudioEngine, and audio clock
YlFrameScheduler.swift         PTS ordering, late-drop policy, frame store
YlFallbackModels.swift         internal packets, stream metadata, errors
YlFFmpegBridge/                opaque C/Objective-C bridge and module header
```

`YlIosPlayer` remains the single object registered as `FlutterTexture`. It owns
exactly one active backend and maps both backends to the existing method/event
channel protocol. `YlAvPlayerBackend` and `YlFallbackBackend` conform to an
internal `YlPlaybackBackend` protocol with open/control/state/dispose operations
and a pixel-buffer provider. No FFmpeg type crosses into Dart or the public
Swift surface.

The C bridge exposes opaque handles and retained CoreMedia objects. Swift never
imports FFmpeg headers directly. A returned compressed video sample owns its
underlying `AVPacket` storage until CoreMedia releases the block buffer, avoiding
an extra encoded-packet copy while keeping lifetime explicit.

## 5. Routing and state ownership

Routing is deterministic before tearing down the current source:

- local `.mkv` or `YlFormatHint.matroska` routes directly to fallback;
- MP4/MOV/HLS and AVFoundation-compatible automatic sources remain on AVPlayer;
- network MKV and HTTP-FLV continue to return
  `container.native_fallback_required` during this slice;
- unsupported video codecs return `decoderUnsupported` without trying software
  decode;
- unsupported audio codecs return `decoderUnsupported` with an audio-specific
  stable code.

Every `open` increments a source generation. Demux, decode, audio completion,
seek, frame, retry, and error callbacks carry that generation and are ignored
after a newer open or dispose. A rejected open is validated before the active
source is disturbed.

The fallback publishes `engine: nativeFallback`. It emits one routing
`YlFallbackEvent`, first-frame, track-change, retry/error, and the existing
state/metrics envelopes. No new public Dart model is required.

## 6. Media pipeline

### Demux

A dedicated serial demux queue owns `AVFormatContext` and all file reads. It
selects one video stream and one host-selected audio stream, normalizes missing
timestamps conservatively, and pushes reference-counted packets into separate
bounded queues. End-of-file, cancellation, malformed data, and seek are explicit
results rather than exceptions crossing threads.

### Video

The bridge translates Matroska H.264/H.265 codec configuration into a
`CMVideoFormatDescription` and wraps each compressed packet as a timed
`CMSampleBuffer`. `VTDecompressionSession` is created with
`kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder` set to
true. Failure to create a required-hardware session returns
`decoderUnsupported`.

Decoded `CVPixelBuffer` frames retain their presentation timestamps and enter a
maximum-three-frame ordered store. The scheduler exposes only the newest due
frame to Flutter Texture. Late non-key frames may be dropped; frames from an old
generation are released immediately. The backend reports the actual
`kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder` value.

### Audio and clock

AAC codec configuration and compressed packets feed an Apple audio converter.
Converted interleaved Float32 PCM is scheduled on `AVAudioPlayerNode` through
`AVAudioEngine`; `AVAudioUnitTimePitch` implements the public 0.25–4.0 speed
range. The player's rendered sample timeline is the master media clock. Video
presentation follows that clock; for video-only files a monotonic clock anchored
to the first PTS is used.

Volume is applied at the player node. Audio-track switching flushes queued audio,
recreates converter state for the new stream, anchors the clock at the current
media position, and resumes without rebuilding the video decoder.

## 7. Bounded memory and lifecycle

Every queue stops demux input when either its duration or byte ceiling is hit.
The initial ceilings are:

| Mode | Video packets | Audio packets | Decoded video | Scheduled PCM |
| --- | --- | --- | --- | --- |
| lowLatency | 1 s / 8 MiB | 1 s / 2 MiB | 2 frames | 250 ms / 1 MiB |
| automatic/balanced | 3 s / 24 MiB | 2 s / 4 MiB | 3 frames | 500 ms / 2 MiB |
| stable | 8 s / 64 MiB | 5 s / 8 MiB | 3 frames | 1 s / 4 MiB |

For custom mode, `maxBufferBytes` is divided 75% video and 25% audio, while
`minBufferDuration` and `maxBufferDuration` bound packet duration. Hitting any
byte limit wins over duration. Decoded pixel-buffer memory is not counted as
compressed buffer bytes and remains bounded by frame count.

Only one iOS backend owns active decode/audio resources. Activating another
player pauses and releases the previous player's demux context, VT session,
audio engine buffers, display link, and packet/frame queues while retaining URI,
selected tracks, quality intent, position, and live-edge intent. Background and
memory-warning handling performs the same release. `play` reconstructs the
pipeline and resumes from the retained position. Dispose is idempotent from
every partial-open state.

## 8. Seek, completion, and failure

Seek pauses scheduling, increments a seek generation, clears packet/frame/PCM
queues, seeks the demuxer backward to the nearest video keyframe, flushes parser
and audio converter state, invalidates and recreates the VT session, and decodes
forward while suppressing frames earlier than the requested position. Audio and
video clocks are re-anchored only after the first valid post-seek sample.

Natural completion occurs only after demux EOF and all selected audio/video
queues drain. A single-stream file may complete from its remaining stream.

Stable failure groups include:

- `container.mkv_open_failed` and `container.mkv_malformed`;
- `decoder.video_hardware_unavailable` and `decoder.video_configuration_invalid`;
- `decoder.audio_aac_unsupported` and `decoder.audio_failed`;
- `render.videotoolbox_failed` and `render.audio_engine_failed`;
- `resource.buffer_limit_invalid`, `cancelled.source_replaced`, and
  `internal.fallback_invariant`.

Diagnostics may contain native status codes, but applications branch only on
the stable category and code.

## 9. Verification and acceptance

Tests use generated, redistribution-safe, checksum-pinned fixtures outside the
published archive: H.264/AAC MKV, HEVC/AAC MKV, two-audio-track MKV, video-only
MKV, truncated MKV, and unsupported-codec MKV.

Native unit tests cover routing, source generations, byte/duration queue limits,
packet ownership, timestamp conversion, frame ordering/drop, error mapping,
seek flush, audio-track switching, and partial-open teardown. Bridge tests read
the fixtures and verify stream metadata, packet PTS/keyframe flags, EOF, seek,
and packet-release balance.

Simulator integration proves build/link, structured unsupported errors, routing,
Texture lifetime, and H.264 first frame where the simulator exposes a compatible
decoder. Physical-device acceptance is required for the retained milestone:

- local H.264/AAC MKV reaches first frame, plays audibly, pauses, seeks, changes
  audio track, changes speed/volume, completes, and disposes;
- HEVC/AAC either uses reported hardware decode or returns
  `decoder.video_hardware_unavailable`;
- rejected/failed MKV open does not stop the prior source;
- 100 open/play/seek/dispose cycles have no leaked contexts, VT sessions,
  textures, display links, or monotonically growing packet/frame memory;
- background and memory warning release active decode resources and a later
  `play` resumes;
- existing AVPlayer HLS integration and all Android behavior remain green;
- both CocoaPods and Swift Package Manager example builds link the same
  XCFramework;
- all four Dart packages still pass `dart pub publish --dry-run` with zero
  warnings after publication exclusions are applied.

Passing Simulator tests alone does not justify claiming MKV support. The README
changes from “fallback required” to supported only after the physical-device
acceptance matrix is recorded.

