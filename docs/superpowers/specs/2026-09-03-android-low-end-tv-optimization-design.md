# Android Low-End TV Playback Optimization Design

## 1. Goal and status boundary

Optimize the Android Media3 backend for real TVBox constraints while preserving
the existing Flutter player API and the package's local, VOD, and live playback
scope. The reference device is Android 7.0, 1.5 GB RAM, 32 GB storage, and a
32-bit ARM process.

The primary target is smooth H.264 1080p30 playback when the device advertises a
compatible hardware decoder. H.265/HEVC is allowed only when an explicit
hardware capability check succeeds. The package must not fall back to software
video decoding.

This milestone is complete when its automated tests, analysis, and Android 32-bit
build gates pass. Physical-device endurance and smoothness validation are
explicitly deferred and must not be claimed as completed in documentation.

## 2. Scope

### Included

- Android 7.0 (API 24) and later.
- 32-bit and 64-bit ARM Android TV and TVBox devices.
- Existing local/content, HTTP/HTTPS VOD, HLS live, and HTTP-FLV live routes.
- Media3 demuxing, networking, audio decoding, and hardware video decoding.
- Automatic device classification and source-specific low-memory policies.
- Hardware-codec capability checks, adaptive track constraints, one-step decoder
  recovery, runtime health monitoring, and one-way quality degradation.
- Bounded encoded buffering without persistent media caching.
- Flutter Texture output, Surface reconstruction, HDMI/display changes, audio
  focus, becoming-noisy handling, app lifecycle, and memory-pressure handling.
- Structured diagnostics and stable failure codes.

### Excluded

- Subtitles and text renderers.
- Software video decoding, FFmpeg, custom Android codecs, or a second playback
  engine.
- Playback controls, D-pad focus UI, recommendations, channel lists, and other
  TV application UI.
- Background audio, `MediaSession`, picture-in-picture, downloads, and disk
  media cache.
- DRM and source-site parsing.
- RTMP, RTSP, SMB, FTP, WebSocket, or other transports not already represented
  by the public source model.
- Changes to the iOS playback architecture.

The device's 32 GB storage does not increase memory budgets and is not used to
enable a disk cache.

## 3. Chosen architecture

Retain Media3/ExoPlayer as the only Android playback engine and introduce a
small policy layer around it. This is preferable to an Android FFmpeg fallback:
it keeps decoded frames out of Dart, uses vendor hardware paths, avoids a large
native binary, and preserves Media3's extractors and adaptive streaming stack.

The Android implementation is split into independently testable responsibilities:

- `YlAndroidDeviceProfile` collects RAM, process bitness, API level, display
  limits, and codec capabilities. It produces a stable process-level tier plus a
  per-source decode envelope.
- `YlAndroidPlaybackPolicy` combines the device profile, media-source class,
  public configuration, and runtime pressure into effective buffer, quality,
  live-edge, and lifecycle decisions.
- `YlAdaptiveLoadControl` applies a mutable target byte budget. Lowering the
  budget stops new loading and trims free allocator segments without forcibly
  copying or retaining old media data.
- `YlHardwareCodecSelector` admits only video decoders classified as hardware,
  validates size/rate/profile/level, and ranks known-good matches. Audio remains
  on Android's normal decoder-selection path.
- `YlPlaybackHealthMonitor` consumes dropped-frame, rebuffer, live-offset,
  decoder, and memory signals and requests bounded recovery actions.
- `YlVideoOutput` owns the native `Surface` attached to the existing Flutter
  texture and isolates stale surface generations.
- The existing Android player owns Media3 state, commands, source generations,
  track selection, and metrics. The plugin owns Flutter channels, the single
  active-video-player rule, Android lifecycle, and component callbacks.

The current monolithic Kotlin source is divided along these boundaries only as
needed for this work. There is no unrelated rewrite of the federated package.

## 4. Device classification and capability envelope

Device classification is automatic and requires no host-application setting.
It is computed once per process using `ActivityManager.MemoryInfo.totalMem`, the
application memory class, `Process.is64Bit()`, and the Android API level:

| Tier | Rule |
| --- | --- |
| `constrained` | Total RAM is at most 2 GB, or the process is 32-bit, or API level is 24-27. |
| `capable` | Total RAM is at least 4 GB, the process is 64-bit, and API level is at least 29. |
| `standard` | Every other supported device. |

Rules are evaluated in the order shown, so any constrained signal wins. The
reference Android 7.0, 1.5 GB, 32-bit box is therefore always constrained.
Unknown RAM or bitness is treated conservatively and cannot produce `capable`.

Tiering is not a promise that a codec works. A separate decode envelope is
computed from `MediaCodecList`, the codec's advertised profile/level and video
capabilities, the selected format's resolution and frame rate, and the active
display size/refresh rate. For old Android versions where the platform does not
directly label hardware codecs, Media3's software-only classification and a
conservative codec-name denylist are used. An uncertain codec is not accepted
for constrained-device video.

For constrained devices the package applies a 1920x1080 and 30 fps ceiling.
The host's `YlQualityConstraint`, the display envelope, and the codec envelope
are intersected; the smallest limit wins. HEVC tracks are eligible only when a
hardware HEVC decoder explicitly passes the same checks. H.264 profiles or
levels beyond the decoder's advertised capabilities are not selected.

The process tier never oscillates at runtime. Health signals can only tighten a
source's effective envelope until the next `open`; they never promote the tier
or automatically raise quality within the same source generation.

## 5. Source classification and buffer policy

The source is classified before Media3 prepares it:

1. `file` and `content` sources use the local profile.
2. Explicit `hls`, or an automatic network URL ending in `.m3u8`, uses HLS.
3. Explicit `httpFlv`, or a live automatic network URL ending in `.flv`, uses
   HTTP-FLV.
4. Other non-live HTTP/HTTPS sources use network VOD.
5. Other live sources use the HLS-stability profile without claiming HLS
   semantics that the extractor has not discovered.

Query strings do not participate in extension detection. An explicit format
hint wins over a URL suffix.

For a constrained device, `automatic` uses these effective targets:

| Source | Minimum / maximum buffer | Target encoded bytes |
| --- | ---: | ---: |
| Local/content | 2 s / 10 s | 16 MiB |
| Network VOD | 4 s / 15 s | 24 MiB |
| HLS live | 6 s / 12 s | 20 MiB |
| HTTP-FLV live | 2 s / 5 s | 12 MiB |

These values are also hard ceilings for constrained devices. A built-in or
custom configuration requesting larger values is safely clamped. A smaller
valid custom value remains effective. If the caller supplies a minimum duration
above the effective maximum, both become the effective maximum. The resulting
values are observable through metrics rather than treated as an error.

For standard and capable devices, existing mode durations remain the base
policy: low latency is 1-5 seconds, balanced/automatic is 5-20 seconds, and
stable is 15-50 seconds. Low latency targets 24 MiB and balanced/automatic
targets 48 MiB. Stable/custom encoded-byte targets are capped at 64 MiB for a
standard device and 96 MiB for a capable device. All device tiers prioritize
the byte ceiling over accumulating extra time.

`YlAdaptiveLoadControl` owns the effective values for a player. On a running-low
memory signal it reduces the current target by 25%, stops loading above the new
target, and trims allocator segments that are no longer referenced. It does not
interrupt the current decoder or pretend that in-use Media3/native codec memory
can be reclaimed synchronously. A new source or foreground reconstruction
restores the normal tier/source target.

## 6. Decoder and track-selection policy

Android video is hardware-only in this milestone. Both public decoder policies
may choose among multiple compatible hardware decoders, but neither may fall
back to a software video decoder. This Android behavior is documented explicitly.
Audio continues to use the system Media3 decoder path. The text renderer remains
disabled before preparation.

Adaptive sources initially select the highest track satisfying all of:

- the host quality constraint;
- the device/display decode envelope;
- the constrained-device 1080p30 ceiling; and
- Media3's supported-format determination.

If video decoder initialization fails on an adaptive source, the player excludes
that representation, lowers the quality ceiling by one available step, and
retries once. A second decoder initialization failure terminates with a stable
error. A fixed/progressive source cannot change representation and fails
immediately when no compatible hardware path exists.

Only one Android player may own an active video decoder. Activating a second
player deactivates the previous owner after saving its playback recipe and
position. Audio-only parallel playback is not introduced.

## 7. Runtime adaptation and live behavior

The health monitor evaluates non-overlapping 30-second windows after the first
frame. A window is unhealthy when any of these occurs:

- more than 60 dropped frames or a dropped-frame ratio above 5%;
- at least two rebuffers or more than three accumulated rebuffer seconds;
- a running-low memory callback; or
- a decoder diagnostic indicating that the selected representation is not
  sustainable.

Two unhealthy media windows request one adaptive quality downgrade. A memory
callback may request it immediately. Downgrades are separated by a 60-second
cooldown, move only one available representation step, increment
`adaptiveDowngradeCount`, and never auto-upgrade during that source generation.
Fixed streams that remain unsustainable after buffer reduction fail with a
structured capability error rather than starting software decode or looping
forever.

HLS favors stability. Its constrained target window is 6-12 seconds. When the
player falls behind the live target, Media3 may catch up gradually but playback
speed is capped at 1.03x. If the offset exceeds the recoverable window, the
player performs one seek to the current live default position, with at least 30
seconds between forced live-edge corrections.

HTTP-FLV uses a 2-5 second constrained buffer. It never exposes a fake seek.
When backlog exceeds the effective maximum plus three seconds and normal
consumption cannot recover it, the player closes and reopens the stream at its
live head. Reconnects use the public network retry limit/backoff, increment
`reconnectCount`, and stop with `network.live_retry_exhausted` when exhausted.

## 8. Surface, TV lifecycle, and audio focus

Decoded video travels from `MediaCodec` to a native `Surface`, then to the
Flutter texture. No encoded bytes or decoded pixel buffers cross the Dart
channel.

Surface lifetime is separated from ExoPlayer lifetime. A transient Surface loss
clears only the video output, releases the old `Surface`, and retains the player,
audio path, playback intent, and media position while the app remains
foreground. Reconstruction creates a new Surface from the texture, increments
a surface generation, sets the current video size, and attaches it only if both
source and surface generations still match. Late callbacks from an HDMI switch,
resolution change, Activity recreation, or older Surface are ignored.

Real application backgrounding pauses playback and releases MediaCodec, Surface,
and nonessential buffered media. It retains only the sanitized source recipe,
selected track, volume, playback intent, and position (or live-edge intent).
Foreground activation rebuilds the Media3 pipeline and resumes only when the
player had been playing before backgrounding. Background audio is never kept
alive.

Media3 receives movie/media audio attributes with automatic audio-focus
handling, becoming-noisy handling, and network wake mode. A transient focus loss
pauses immediately but keeps resources for a three-second grace period. Focus
gain within the grace period resumes only playback that focus loss paused; an
explicit user pause is never undone. Permanent loss or grace expiry releases the
decoder using the normal deactivation recipe. Network wake mode includes only
the narrowly required Android wake-lock permission.

TV remote play/pause commands use the same idempotent player commands as Flutter.
This milestone does not add focusable controls or a `MediaSession`.

## 9. Memory-pressure behavior

Android component callback levels map to explicit actions:

| Signal | Action |
| --- | --- |
| `TRIM_MEMORY_RUNNING_LOW` / `RUNNING_MODERATE` | Reduce the load target, trim free allocations, keep playback active, and record pressure. |
| `TRIM_MEMORY_RUNNING_CRITICAL` | Save state and release the active decoder, Surface, and buffered media. |
| `TRIM_MEMORY_UI_HIDDEN` or real background | Save state and release playback resources; do not continue audio. |
| Foreground after release | Rebuild from the saved VOD position or live edge and restore the normal policy ceiling. |

Repeated callbacks are idempotent. Release, reactivation, `open`, and `dispose`
all advance or validate generations so stale decoder, Surface, retry, or player
events cannot mutate a newer source. Disposal releases the texture exactly once.

## 10. Public diagnostics

`YlPlaybackMetrics` gains these nullable, backward-compatible fields:

- `String? androidDeviceTier`, with stable values `constrained`, `standard`, or
  `capable`;
- `int? targetBufferBytes`, the current effective Media3 encoded-byte target;
- `int? adaptiveDowngradeCount`;
- `int? surfaceRebuildCount`; and
- `int? selectedVideoBitrate`.

Non-Android backends return `null` for these fields. Android counters report
zero before an event and reset on each new source generation, matching the
existing per-open metrics. `targetBufferBytes` changes when memory pressure
changes the effective target. `selectedVideoBitrate` is null when Media3 does
not expose a known bitrate.

The platform channel decoder must tolerate all fields being absent so older
native implementations remain compatible. No device identifiers, codec dumps,
URLs, headers, or other sensitive values are added to public metrics.

## 11. Errors and bounded recovery

The following stable Android errors are added or normalized:

| Category | Code | Meaning |
| --- | --- | --- |
| `decoderUnsupported` | `decoder.hardware_required` | No acceptable hardware video decoder exists. |
| `decoderUnsupported` | `decoder.capability_exceeded` | The fixed stream or selected format exceeds the safe decode envelope. |
| `decoderFailure` | `decoder.initialization_failed` | Hardware initialization still failed after the one permitted adaptive retry. |
| `resource` | `resource.video_decoder_busy` | A video decoder could not be acquired after ownership transfer. |
| `resource` | `resource.memory_pressure` | Playback could not be safely rebuilt after critical pressure. |
| `network` | `network.live_retry_exhausted` | A live reconnect exhausted the configured attempts. |

Diagnostics may include a sanitized codec name, format dimensions, frame rate,
and Android API level. They must not include request headers or full URLs.
Decoder retry, adaptive downgrade, live-edge correction, Surface reconstruction,
and reconnect loops are all bounded as described above.

## 12. Testing and acceptance

### JVM policy tests

- Tier every RAM/bitness/API boundary, including the reference device.
- Derive the exact constrained buffer profile for local, VOD, HLS, and HTTP-FLV.
- Verify configuration precedence, safety clamping, and memory-pressure shrink.
- Classify explicit hints, suffixes with query strings, unknown VOD, and unknown
  live sources deterministically.
- Filter and rank hardware codecs; reject software, unsupported profile/level,
  excessive resolution/frame rate, and unadvertised HEVC.
- Verify health windows, two-window hysteresis, 60-second cooldown, one-step
  downgrade, no automatic upgrade, and per-open metric reset.
- Verify the memory callback action matrix and idempotent generation handling.

### Android player tests

- Adaptive decoder initialization failure lowers quality exactly once.
- Fixed-stream incompatibility produces the exact structured error.
- HLS catch-up never exceeds 1.03x and forced live-edge recovery is rate-limited.
- HTTP-FLV backlog recovery reconnects without seeking and obeys retry limits.
- Surface reconstruction ignores stale generations and retains playback state.
- Focus loss, explicit pause, grace expiry, Activity recreation, backgrounding,
  foregrounding, and disposal preserve the intended playback state.
- A second video player transfers the single decoder owner without leaking the
  first player's resources.

Pure policy and lifecycle coordination are kept outside Android framework-heavy
objects so most coverage runs as deterministic JVM tests. Narrow instrumentation
tests are used only where Media3 or Android lifecycle behavior cannot be proven
without the framework.

### Flutter compatibility tests

- Encode and decode all five optional metrics.
- Decode envelopes from older Android/iOS implementations with the fields
  absent.
- Confirm iOS state and event tests remain unchanged except for nullable metric
  defaults.

### Automated completion gate

Run Kotlin/JVM tests, applicable Android instrumentation tests available in the
local environment, every Dart test, `flutter analyze`, formatting checks,
`git diff --check`, an Android debug build including `armeabi-v7a`, and package
publication dry runs. Simulator/emulator media success may be capability-gated,
but policy and error behavior may not be skipped.

### Deferred physical-device gate

On an Android 7.0, 1.5 GB, 32-bit ARM TVBox with controlled H.264 1080p30 media:

- play continuously for two hours without crash or OOM;
- keep post-warm-up dropped frames below 1%;
- keep measured A/V skew near or below 80 ms on the controlled corpus;
- complete 100 open/play/seek/dispose cycles without staircase memory growth;
- reach first frame within 1.5 seconds for local media and 3 seconds on the
  controlled LAN; and
- recover from bounded HLS/HTTP-FLV disconnects without an infinite loop.

HEVC passes this gate only on devices whose hardware decoder advertises and
actually sustains the test format. These measurements are release evidence, not
part of the current implementation-complete claim.

## 13. Documentation and publication

README and changelog changes must describe automatic device tiers, constrained
buffer ceilings, hardware-only Android video, supported source classes, and the
deferred real-device status. They must not promise universal 1080p or HEVC
smoothness because vendor codec declarations and firmware quality vary.

The changes remain inside the existing federated packages and preserve the
public constructor defaults. Before publication to `pub-web.flutter-io.cn`, all
packages must pass their existing dry-run gates and contain no test fixtures,
build outputs, credentials, or private TVBox data.
