# AirPlay video on iOS and macOS

AirPlay is opt-in per load. It uses AVPlayer external playback and Apple's
visible device picker. Android and older native adapters reject the opt-in.
Deployment floors remain iOS 15 and macOS 12.

```dart
final player = await YlPlayerController.create(
  options: const YlPlayerOptions(
    audioPolicy: YlAudioPolicy.pluginManagedMediaPlayback,
  ),
);
final session = await player.load(
  YlNetworkSource(
    Uri.parse('https://media.example/live.m3u8'),
    format: YlMediaFormat.hls,
    intent: YlStreamIntent.live,
  ),
  options: const YlLoadOptions(airPlay: true),
);
await session.play();
// Put this widget in the UI after creating the controller:
// YlAirPlayButton(controller: player)
```

Use `player.assess(source, options: const YlLoadOptions(airPlay: true))`
before loading if the UI needs admission feedback. `requiresInspection` is not
a guarantee that codecs, timing or resource limits will pass preparation.

`player.airPlayState` is a `ValueListenable<YlAirPlayState>`:

- `supported`: the native adapter negotiated the optional AirPlay interface.
- `enabled`: the current committed session was loaded with AirPlay enabled.
- `active`: AVPlayer reports actual external playback for that session.
- `sessionId`: identifies the session owning the state.

The user selects the receiver in `YlAirPlayButton`. Enabling AirPlay does not
choose a device. Ordinary loads reset external playback permission. Pause,
play, seek, stop and disposal retain their existing session semantics. A local
`session.firstFrame` is not a remote-screen presentation acknowledgement;
remote playback does not synthesize that event.

## Source paths

| Source | AirPlay path |
|---|---|
| HTTP(S) HLS live or VOD, without custom request metadata | AVPlayer directly consumes the original URL |
| HTTP(S) MP4/MOV, without custom request metadata | AVPlayer directly consumes the original URL |
| Compatible local or seekable HTTP VOD, including MKV/FLV | Compressed H.264/AAC passthrough into temporary HLS, then AVPlayer |
| Automatic format | Inspect the source, then apply the same rules; HLS live is admitted |
| Non-TLS RTMP and HTTP(S)-FLV live | Continuous H.264/AAC passthrough into sliding HLS, then AVPlayer |
| RTMPS or other custom live containers/codecs | Not supported by this bridge |
| DRM, headered HLS, managed network guarantees, nonautomatic buffering, hardwareRequired or video constraints | Rejected rather than weakening the requested policy |

Direct playback remains subject to AVFoundation and receiver codec support.
The receiver must be able to access the URL; local-only addresses, expiring
tokens and server authentication may prevent remote playback.

**RTMP and HTTP-FLV live are supported through a continuous remux worker.**
For HTTP-FLV, specify the live intent explicitly:

```dart
final session = await player.load(
  YlNetworkSource(
    Uri.parse('https://media.example/channel.flv'),
    format: YlMediaFormat.flv,
    intent: YlStreamIntent.live,
  ),
  options: const YlLoadOptions(airPlay: true),
);
await session.play();
```

Use an `rtmp://` URL for RTMP; its automatic intent is also treated as live.
The existing RTMP transport validation still applies, including rejection of
RTMPS, HTTP headers and on-demand intent. HTTP-FLV uses the existing HTTP
transport and its credential/redirect rules. Source credentials stay upstream.

The worker commits after publishing at least 18 seconds of media, while the
source remains connected. Startup has a 45-second deadline. The playlist uses a
6-second target duration and retains at least a 30-second active window, with
at most 32 active segments. This is standard HLS delivery, not a low-latency
streaming promise. Actual startup and playback delay depend on input keyframes,
network conditions and the receiver.

Transient disconnections allow three reconnect attempts per load with 0.5/1/2-second
backoff. Each reconnection gets a fresh initialization map and a discontinuity;
codec/configuration changes within a connection and invalid timestamps are
terminal errors. Pause keeps ingesting the source; seeking is limited to the
available live window. Stop, disposal and successful source replacement stop
the producer. A failed replacement leaves the existing live session intact.

## Custom-source remux limits

The bridge uses the existing FFmpeg demux library and AVFoundation compressed
sample writer. It neither invokes an external ffmpeg executable nor decodes and
re-encodes video. The first H.264 video track and optional first mono/stereo
AAC-LC audio track are exported; additional tracks and subtitles are not muxed.
HEVC, HE-AAC, ADTS AAC and other codecs are not admitted by this bridge.

For finite VOD, preparation scans timestamps, seeks to zero and writes HLS. Network sources
must support finite seekable input, and may be downloaded twice. Limits are:
120 seconds of preparation; six hours of duration; 500,000 video samples;
512 MiB of input packets/local-file size and 512 MiB of output; 8 MiB per packet;
32 MiB per video keyframe interval. Long or large movies can therefore fail
with `airplay.resource_limit`. Cancellation, failed preparation, replacement,
stop and disposal release temporary resources.

Live input instead preserves its DTS/PTS, including valid B-frame reordering,
and starts from an IDR frame. It is bounded by 8 MiB per packet, 32 MiB per
segment and 6 seconds between segment boundaries; FLV tags are capped at
8 MiB before demuxing. Sequence headers are limited to 64 KiB and changes within
a connection are rejected. Audio/video drift and PTS/DTS
offset must also stay within 6 seconds. Output is limited to 128 MiB and 128
files, including retained files needed by existing readers. Exceeding bounds
fails the session rather than growing storage indefinitely. Expired segments
remain available for the longest previously published playlist duration plus
the segment duration, measured using a monotonic clock. Live playlists are
published atomically and served without caching; immutable media is cacheable.

Generated media is served on one active Wi-Fi/Ethernet IPv4 address, with a
random capability URL, an explicit filename allowlist, GET/HEAD and single
byte-range support. Connections and transfer buffers are bounded. The source
credentials are not copied into the playlist. Generated video is clear HTTP
on the LAN; possession of its temporary URL permits reading it while active.
IPv6-only networks and network-interface changes require a different serving
strategy or a fresh load. Phone and receiver must have mutual LAN reachability;
peer-to-peer AirPlay and CarPlay network topology are not assumed to provide it.

## Host configuration

For iOS, enable the **Audio, AirPlay, and Picture in Picture** background mode
(`UIBackgroundModes` containing `audio`). Use `pluginManagedMediaPlayback`, or
configure/activate the media playback audio session in the host when using
`appManaged`. The latter leaves audio-session ownership with the application.
Only an active AirPlay session with background-audio configuration bypasses
normal background suspension. Interruptions pause playback; automatic
background restoration requires the same external route to remain selected.

For LAN remux delivery add `NSLocalNetworkUsageDescription` to the app's
Info.plist and allow local networking in its ATS policy where required.
Sandboxed macOS hosts need both `com.apple.security.network.client` and
`com.apple.security.network.server`. The example includes these declarations
and an opt-in switch, device picker and route status. System local-network
permission must be granted on the device.

CarPlay video UI, entitlements, vehicle support and parked-state behavior are
separate host-app concerns. This plugin does not install an IJK view into the
official CarPlay video channel.

## Verification status

Dart contract/widget tests and native source/commit/cleanup tests cover the
implementation. Real fixture remux tests verify AVPlayer video frames, decoded
AAC, seeking, HTTP bounds and cancellation. Native tests additionally use the
production HTTP input path. See [remux harness](../tool/airplay/README-remux.md)
and [initial verification record](verification/2026-10-19-airplay.md).
The [live verification record](verification/2026-10-19-airplay-live.md) covers
continuous HTTP-FLV and RTMP fixtures, rolling/reconnected playlists, live
video decoding, ownership, cancellation and storage bounds.

Physical receiver and CarPlay playback remain unverified. Device acceptance
must exercise direct HLS live/VOD, custom VOD and RTMP/HTTP-FLV live, pause/seek, route disconnect and
reconnect, background playback/interruption, permissions and LAN reachability.
