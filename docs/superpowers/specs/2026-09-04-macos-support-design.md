# yl_player macOS Support Design

Date: 2026-09-04

## 1. Purpose

Add a first-party macOS implementation to the federated `yl_player`
playback kernel without changing its public Dart API. The macOS implementation
must provide the same basic playback contract as the existing Android and iOS
implementations while keeping media frames and decoded audio out of Dart.

The first supported desktop target is macOS 12 or later. Distribution artifacts
must contain Apple Silicon (`arm64`) and Intel (`x86_64`) slices.

## 2. Scope

The macOS implementation covers:

- Local files through ordinary paths and `file://` URIs.
- HTTP and HTTPS progressive media, redirects, byte ranges, and custom request
  headers.
- HLS live and video-on-demand playback.
- Local and network Matroska/MKV playback through the fallback pipeline.
- HTTP-FLV live playback through the fallback pipeline.
- H.264/AVC and H.265/HEVC hardware video decoding where VideoToolbox accepts
  the concrete stream.
- AAC and MP3 audio in the fallback implementation, matching the current iOS
  fallback contract.
- Open, play, pause, source replacement, seek, live-edge seek, playback speed,
  volume, audio-track selection, and quality constraints.
- Texture rendering, immutable state updates, first-frame and retry events,
  structured errors, playback metrics, and deterministic disposal.
- Authenticated requests and cross-origin redirect credential protection
  consistent with the existing platform contract.

This work does not add subtitles, DRM, offline downloads, persistent cache,
background audio, picture in picture, casting, playlists, or application player
controls. Software video decoding remains outside the supported contract.

## 3. Package Architecture

Create a dedicated `yl_player_macos` federated implementation package. The
app-facing `yl_player` package endorses it as the default macOS implementation,
and the root Pub workspace includes the package and its example where needed.

The package contains:

- A Dart registration adapter based on the shared versioned channel codec and
  `ChannelPlayer` implementation from `yl_player_platform_interface`.
- A macOS Flutter plugin using `FlutterMacOS` method channels, event channels,
  and texture registry APIs.
- An AVPlayer backend for AVFoundation-compatible progressive media and HLS.
- A bounded FFmpeg/libavformat fallback backend for MKV, HTTP-FLV, and requests
  that cannot safely use the AVPlayer path.
- macOS-specific application lifecycle and audio-output integration.
- A reproducibly built macOS FFmpeg bridge XCFramework with universal macOS
  support.

The stable iOS package is not restructured as part of this work. Pure policies
may be ported with tests, but macOS owns its platform integration and lifecycle.
After both implementations have production evidence, shared Apple-native
components may be extracted in a separate change.

## 4. Playback Data Flow

### 4.1 AVPlayer path

AVFoundation-compatible media follows this path:

```text
YlPlayerController
  -> shared channel protocol
  -> yl_player_macos plugin
  -> AVPlayer / AVPlayerItem
  -> AVPlayerItemVideoOutput
  -> CVPixelBuffer
  -> FlutterTexture
```

The backend observes item readiness, duration, tracks, buffering, playback rate,
completion, and failures. It emits full state snapshots for semantic changes and
generation-scoped compact deltas for throttled position updates.

### 4.2 Fallback path

MKV, HTTP-FLV, and other approved fallback cases follow this path:

```text
file or bounded network byte source
  -> FFmpeg/libavformat demux
  -> bounded packet queues
  -> VideoToolbox hardware decode
  -> CVPixelBuffer / FlutterTexture

audio packets
  -> supported native audio conversion
  -> macOS native audio output
```

The fallback keeps duration and byte ceilings on all queues. Audio is the master
clock when present; otherwise video timestamps drive presentation. Seeking and
source replacement flush packet, decoder, renderer, and clock state before new
output is accepted.

Encoded packets, decoded video frames, and PCM samples never cross the Flutter
channel.

## 5. Native Platform Adaptation

The macOS implementation uses `FlutterMacOS`, not the iOS `Flutter` module. It
uses `NSApplication` lifecycle notifications and must not depend on `UIKit` or
`AVAudioSession`.

AVPlayer video frames are obtained with `AVPlayerItemVideoOutput`. Fallback
frames are emitted by VideoToolbox. Both backends conform to one internal frame
provider contract and expose `CVPixelBuffer` instances through `FlutterTexture`.
Texture ownership must remain valid for the Flutter raster-thread copy without
leaking buffers across source generations.

Audio output uses APIs available on macOS 12. The implementation may reuse
platform-neutral AudioToolbox scheduling logic from the iOS design, but session
activation and interruption behavior are implemented in macOS-specific code.

The plugin listens for application activation, deactivation, and termination.
Termination disposes all players. Deactivation must preserve logical playback
state and must not silently manufacture a pause unless the public lifecycle
policy requires it.

## 6. Source Routing and Network Security

Known AVFoundation-compatible MP4/M4V/MOV and HLS sources use AVPlayer when the
request policy can be represented safely. Known MKV and HTTP-FLV inputs route
directly to fallback. A source may switch engines automatically at most once,
and only for an explicitly eligible container or decoder failure.

Authentication, DNS, TLS, missing-file, timeout, and authorization failures do
not trigger a second engine. Network requests use finite timeouts and retries,
honor cancellation, and strip `Authorization`, `Cookie`, and
`Proxy-Authorization` when a redirect crosses origins. Old-generation network
responses and callbacks are ignored.

Cleartext HTTP remains an application entitlement decision. The plugin does not
disable App Transport Security globally or accept invalid TLS certificates.

## 7. State, Commands, and Errors

macOS uses the existing channel protocol version, generation identifiers,
command vocabulary, state model, event model, and error categories. No macOS-
specific public Dart branch is introduced.

Invalid or rejected commands return `YlPlayerError` without mutating the
authoritative player state or emitting a terminal player error event. Native
source, decoder, render, or resource failures transition the active generation
to the appropriate terminal error state and emit one matching error event.

The decoder policy remains hardware-only. If VideoToolbox rejects a codec,
profile, level, pixel format, resolution, or stream configuration, the backend
returns a structured `decoderUnsupported` error. It must not silently perform
software video decoding.

First-frame is emitted at most once per source generation. Disposal is
idempotent and cancels open work, network I/O, timers, observers, packet queues,
decoders, audio output, and textures.

## 8. FFmpeg Bridge and Distribution

The macOS bridge uses the same pinned, signature-verified, minimal LGPL FFmpeg
configuration principle as the iOS bridge. It enables only the demuxing and
parsing functions required by the supported fallback formats. Apple native
audio conversion handles AAC and MP3, and FFmpeg is not the video decoder.

The build produces a macOS XCFramework containing `arm64` and `x86_64` slices,
with a deployment target of macOS 12. The build contract records the FFmpeg
version, archive checksum, signing-key fingerprint, configure flags,
architectures, and deployment target. Package notices and license files include
the macOS binary.

The existing iOS XCFramework is left unchanged. macOS owns a separate binary so
publishing or rebuilding one platform cannot invalidate the other.

## 9. Testing and Acceptance

### 9.1 Automated tests

- Dart tests verify macOS plugin registration, channel names, creation,
  protocol-version validation, full snapshots, compact deltas, errors, and
  disposal.
- Swift unit tests verify source routing, channel decoding, lifecycle policy,
  first-frame gating, header/redirect policy, retry and reconnect policy,
  buffering ceilings, clock and scheduler behavior, track catalogs, quality
  constraints, state encoding, and ownership cleanup.
- FFmpeg contract tests verify the pinned source, build flags, deployment
  target, exported symbols, licenses, and both macOS architectures.
- Existing Dart, Android, and iOS suites remain green.

### 9.2 Integration scenarios

The macOS example runs these end-to-end scenarios on Apple Silicon:

1. HLS playback through AVPlayer.
2. Local MKV playback through FFmpeg and VideoToolbox.
3. Seekable network MKV playback through the bounded network byte source.
4. HTTP-FLV playback and live reconnection.
5. Authenticated HLS with header and redirect-policy assertions.

Each scenario must demonstrate open-to-ready, first frame, playback progress,
basic control behavior relevant to the source, and clean disposal. Failures must
surface as bounded structured errors rather than hangs or crashes.

### 9.3 Architecture coverage

The available development machine is Apple Silicon. All runtime and integration
tests therefore run natively on `arm64`. Intel coverage consists of compiling
and linking `x86_64`, verifying every vendored dependency contains the required
slice, and inspecting final artifacts. If Rosetta is available, an additional
`x86_64` smoke launch is run.

The verification report must state that Intel build compatibility was checked
but Intel hardware runtime was not tested. A real Intel Mac remains a publication
matrix item rather than a condition for completing this implementation.

## 10. Documentation and Completion Criteria

The public README and platform capability table add macOS 12+, supported source
types, hardware-only decode behavior, HTTP security requirements, Intel
verification limits, and the unchanged exclusions. The macOS implementation
package documents its binary licensing and reproducible build process.

The feature is complete when:

- `yl_player` automatically selects `yl_player_macos` on macOS.
- Both macOS architectures compile and link with the declared minimum version.
- The five Apple Silicon integration scenarios pass.
- macOS Dart and Swift tests pass alongside all existing repository checks.
- Static analysis, formatting, binary-contract checks, and package metadata
  checks pass.
- The verification report accurately distinguishes tested runtime behavior from
  build-only Intel coverage.
