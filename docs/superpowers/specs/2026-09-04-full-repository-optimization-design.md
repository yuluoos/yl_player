# yl_player Full-Repository Optimization Design

Date: 2026-09-04

## 1. Purpose

This change hardens the complete `yl_player` federated plugin after the
repository-wide review. It fixes correctness and security defects, makes the
Dart/native contract harder to drift, reduces recurring platform-channel work,
and improves maintainability and continuous verification without replacing the
working Media3, AVPlayer, VideoToolbox, AudioToolbox, or FFmpeg pipelines.

The implementation is compatibility-first. Existing application source code
continues to compile. Behavioral corrections are allowed where the current
behavior is unsafe, internally inconsistent, or claims success without applying
the requested operation.

## 2. Scope and Constraints

The optimization covers:

- public Dart validation and controller error semantics;
- shared Android/iOS channel encoding, decoding, and player plumbing;
- Android redirect security, first-frame accounting, capabilities, surface
  lifecycle tests, and Gradle configuration;
- iOS fallback metrics, quality constraints, capabilities, and cancellation;
- lower-overhead periodic state delivery;
- decomposition of oversized native source files along existing responsibility
  boundaries;
- repository CI and regression coverage.

The following remain outside scope:

- software video decoding;
- new container, codec, subtitle, DRM, caching, or background-audio features;
- a wholesale Pigeon migration;
- changes to the established FFmpeg build contents;
- claiming physical-device or endurance acceptance without new evidence.

The minimum supported versions remain Android API 24, iOS 15, Dart 3.12, and
Flutter 3.44. The implementation must preserve the one-active-video-decoder
resource policy and must not expose media URLs, query strings, credentials, or
headers in diagnostics.

## 3. Error and State Semantics

Native state events remain the sole authority for playback state. A rejected
method call returns a structured `YlPlayerError` to its caller but does not, by
itself, change the mirrored player state or emit `YlErrorEvent`.

This rule applies to invalid speed, unavailable tracks, unsupported seek,
quality-constraint rejection, superseded asynchronous commands, and an iOS
candidate `open` that fails before replacing the current backend. It prevents a
healthy native player from appearing terminally failed in Dart.

Actual terminal playback failures are published by native code as both an error
event and an error state. Platform-player creation failure remains terminal in
the app-facing controller because no native player exists. Disposing remains
terminal and best-effort.

Opening a second source cancels an older unfinished open. The older Future
completes with the existing `cancelled` error, while the current mirrored state
is left to the newest native operation. No stale cancellation error event is
emitted.

## 4. Input Validation

The existing const configuration constructors remain available. Runtime
validation occurs before native player creation and before each public command,
so release builds receive the same guarantees as debug builds.

Validation rules are:

- connect and read timeouts must be greater than zero and fit the Android
  millisecond representation;
- retry delays must be nonnegative, and maximum retry delay must not be less
  than base retry delay;
- retry and redirect counts must be in the inclusive 0–20 range already
  enforced by the iOS implementation;
- position event interval must be positive; native code may continue clamping
  it to the supported 100–2000 ms range;
- custom buffer durations must be nonnegative, minimum must not exceed maximum,
  and byte ceilings must be positive and fit supported native integers;
- seek positions must be nonnegative;
- playback speed must be finite and within 0.25–4.0;
- volume must be finite and within 0.0–1.0 rather than silently diverging across
  platforms;
- quality limits must be positive, finite where applicable, and fit Android
  integer fields.

Direct platform-interface consumers receive equivalent defensive validation in
the Android and iOS adapters. Android and iOS must give zero timeout the same
meaning: it is invalid, not infinite on one platform and immediate failure on
the other.

## 5. Redirect Credential Security

Android adopts the same origin definition already used by iOS: lowercase
scheme and host plus effective port. On every OkHttp network-interceptor pass,
the current request destination is compared with the original call origin.

`Authorization`, `Cookie`, and `Proxy-Authorization` are retained only for the
same origin. They are removed before following any cross-origin redirect. Other
caller headers remain available across redirects. Redirect counting and the
configured maximum remain unchanged.

Regression tests cover implicit/default ports, scheme changes, port changes,
multiple redirect hops, same-origin retention, and cross-origin stripping.

## 6. Shared Dart Channel Contract

The duplicated Android and iOS channel codec and player implementations move to
a separately importable library in `yl_player_platform_interface`. The main
platform-interface barrel does not export these implementation helpers, keeping
the ordinary public API focused while allowing endorsed implementations to
share one source of truth.

The shared layer provides:

- configuration, source, and quality-constraint encoders;
- defensive state, event, error, track, capability, and metric decoders;
- one configurable channel-backed `YlPlatformPlayer` implementation;
- stable wire-key constants, including `droppedVideoFrames`;
- EventChannel `onError` and `onDone` handling;
- per-player filtering and idempotent disposal.

Malformed or interrupted native event streams produce one stable internal or
resource error and do not escape as unhandled zone errors. Method-call failures
are returned to the caller without mutating playback state.

Pigeon is intentionally deferred. Replacing the entire native protocol while
also changing lifecycle behavior would enlarge the regression surface without
being necessary to remove current duplication and key drift.

## 7. Periodic State Efficiency

Semantic transitions continue sending full state snapshots. Periodic position
ticks use a versioned state-delta envelope containing only fields that can
change continuously: position, buffered position, live offset/edge, and dynamic
metrics.

The shared Dart channel layer merges a delta into the latest immutable state.
Tracks, video size, decoder identity, capabilities, and current error are not
re-serialized on every timer tick. A delta received before an initial full
state is ignored. Native implementations emit a full state immediately when an
event listener attaches and after each source generation changes, so no
delta-request command is added to the protocol.

The default 250 ms interval is preserved. Optimizations must reduce allocation
and serialized payload size without lowering observable update frequency.

Tests verify full-state decoding, delta merging, ordering, disposal, and that a
delta cannot resurrect stale data after a source generation changes.

## 8. Android Corrections

Android records first frame once per source generation. Surface replacement,
configuration change, and foreground reconstruction may notify Media3 again,
but they do not emit another public `YlFirstFrameEvent` or overwrite
`firstFrameDuration`.

Capabilities use canonical MIME codec identifiers and report every format that
the current Android route accepts, including MOV and AVI. Capability tests
compare the declared formats with the format-hint-to-MIME routing table.

The current Android hardware-only decoder selector is retained. The public
default changes to `hardwareOnly`. `preferHardware` remains source-compatible
but is deprecated with documentation that it currently resolves to the same
policy. On iOS, plugin-owned VideoToolbox decoding must require hardware while
AVPlayer remains system-managed because Apple does not expose decoder-selection
control. Capabilities document that distinction. No platform may intentionally
select software video decoding as part of this work.

The Android implementation is split without changing algorithms:

- plugin registration, player registry, and application lifecycle;
- Media3 player and callback handling;
- network configuration, redirect policy, and retry policy;
- state/event encoding and capability collection.

The implementation migrates away from deprecated Gradle flags. Surface output
continues using the currently compatible Flutter texture API during this change;
a `SurfaceProducer` migration is permitted only if Flutter 3.44 exposes all
required lifecycle callbacks on API 24 and regression tests prove restoration.

## 9. iOS Corrections

The fallback metric key changes from `droppedFrames` to
`droppedVideoFrames`, with an end-to-end native-envelope-to-Dart-model test.

Fallback quality constraints no longer return false success. Since the current
fallback selects one fixed video stream, it validates maximum width, height,
and bitrate against that stream. A constraint that the stream exceeds returns
a nonterminal `decoderUnsupported` capability error. A constraint that the
stream already satisfies succeeds. If bitrate metadata is unavailable, a
requested bitrate ceiling returns the same nonterminal capability error rather
than claiming success. The selected constraint is also applied during open,
reactivation, reconnect, and track reconstruction.

Capability codec identifiers use the same canonical MIME strings as Android.
Supported-format reporting describes the complete player implementation rather
than whichever backend happens to be active, while actual stream suitability
still depends on hardware initialization.

The large fallback implementation is decomposed by extracting cohesive helper
types for state encoding/metrics, track selection, and recovery policy. The
demux pump, lock ownership, decoder lifecycle, audio scheduling, and reconnect
transaction ordering remain unchanged unless a failing regression test requires
a correction.

## 10. Tests and CI

Every behavioral correction follows red-green-refactor. Required new tests
include:

- Dart: command rejection preserves current state; cancelled open does not emit
  a fatal event; creation failure remains terminal; shared codec rejects
  malformed values; EventChannel error/done behavior; state-delta merging;
- Android: same-origin credential policy; cross-origin stripping; first-frame
  single emission per source; capabilities match route support; validation;
- iOS: dropped-frame metric contract; fallback constraint acceptance and
  rejection; cancellation preserves active state; canonical capabilities;
- integration: existing HLS, MKV, network MKV, HTTP-FLV, and authenticated HLS
  suites continue passing.

GitHub Actions provides separate jobs for:

1. Dart analysis, formatting, package tests, and FFmpeg build contract;
2. Android debug compilation and native unit tests;
3. iOS simulator build, XCTest, and integration tests on a macOS runner where
   the required simulator and local-network behavior are available.

CI does not replace the deferred physical-device matrices. Release documentation
continues identifying Android TV endurance, physical VideoToolbox availability,
memory profiling, and long-duration playback as unverified until recorded.

## 11. Acceptance Criteria

The work is complete when:

- all findings and optimization items in this design have implementation or an
  explicit, tested compatibility decision;
- no cross-origin Android request contains caller-supplied credential headers;
- rejected commands and superseded opens cannot move a healthy player to error;
- invalid configuration behaves consistently in debug and release builds;
- first-frame and dropped-frame metrics are correct across the Dart boundary;
- no public command reports success while intentionally doing nothing;
- periodic state traffic no longer repeats static metadata;
- duplicated Dart channel implementations are removed;
- native source files are split without lifecycle or media-pipeline regression;
- foundation, Android native, iOS native, and all simulator integration checks
  pass from a clean worktree;
- the repository contains CI definitions for the same repeatable checks.
