# yl_player v0.2 Architecture Design

Date: 2026-09-06

Status: Approved in design review; review corrections authorized on 2026-09-07

## 1. Purpose

`yl_player` will become a truthful, extensible playback kernel for Android,
iOS, and macOS while preserving a stable extension point for independently
published platform implementations. The v0.2 release may break the v0.1 API
and package layout where compatibility would preserve ambiguous lifecycle,
policy, or capability semantics.

The redesign addresses five root problems:

- native player creation and event attachment are currently implicit;
- commands, state, and events do not expose a public media-load identity;
- configuration claims guarantees that some native engines cannot enforce;
- the hand-written map protocol and duplicated Apple sources can drift;
- application-facing exports include platform-implementation contracts.

The working Media3, AVPlayer, FFmpeg demux, VideoToolbox, AudioToolbox, texture,
clock, and scheduling algorithms are retained unless a failing regression test
requires a behavioral correction.

## 2. Scope

The v0.2 architecture covers:

- app-facing player and playback-session APIs;
- media-source, loading, policy, capability, state, event, failure, metric, and
  video-geometry models;
- a stable public SPI for third-party platform implementations;
- implementation-private typed platform communication;
- Android session coordination and decoder-resource arbitration;
- one shared Apple implementation package for iOS and macOS;
- audio-session and audio-focus ownership;
- safe diagnostics and credential handling;
- deterministic integration, packaging, and release verification.

The following remain outside this release:

- subtitles and text-track rendering;
- DRM;
- downloads or persistent media cache;
- background audio;
- picture in picture, casting, and AirPlay orchestration;
- playlists and content-source parsing;
- application playback controls and gestures;
- software video decoding as a package-provided fallback.

The supported floors remain Android API 24, iOS 15, macOS 12, Dart 3.12, and
Flutter 3.44 unless a separately approved decision changes them.

## 3. Domain Language

The canonical terms are maintained in the repository root `CONTEXT.md`. The
central distinction is between a long-lived **Player** and one committed
**Playback Session**. Each Load creates a unique Playback Session ID, and that
identity correlates every command, state snapshot, state delta, and event.

Ready and First Frame remain distinct. Ready means that a Playback Session can
begin or resume playback; initial buffering alone does not prove Ready. Ready
requires an actual ready/playing transition or a measured load-to-ready result.
First Frame means that the first video frame has actually been presented on the
committed public output, not a private surface used to prepare a candidate. Stop ends the current Playback Session without
destroying its Player.

## 4. Package Architecture

The repository will contain four publishable packages:

```text
yl_player
├── application-facing controller and view
└── selective exports of public domain models

yl_player_platform_interface
├── stable handwritten platform SPI
├── shared domain value types and validation
└── reusable platform conformance tests

yl_player_android
├── endorsed Android implementation
└── private Pigeon Dart/Kotlin transport pair

yl_player_apple
├── endorsed iOS and macOS implementation
├── shared Darwin native core
└── private Pigeon Dart/Swift transport pair
```

The separate `yl_player_ios` and `yl_player_macos` packages are replaced by
`yl_player_apple`. Their removal is documented as a v0.2 migration rather than
hidden behind runtime compatibility shims.

Third-party packages such as `yl_player_windows`, `yl_player_linux`, or a
vendor-specific player depend only on `yl_player_platform_interface`. They may
use Pigeon, FFI, method channels, pure Dart, or another private transport.

The app-facing `yl_player.dart` barrel exports only the controller, view, and
domain types required by applications. It does not export platform
registration, native-player contracts, validation helpers, or generated
transport types.

## 5. Public Player and Session API

Native creation is explicit and asynchronous:

```dart
final player = await YlPlayerController.create(
  options: const YlPlayerOptions(
    decoderPolicy: YlDecoderPolicy.hardwarePreferred,
    audioPolicy: YlAudioPolicy.appManaged,
  ),
);
```

`create` completes only after the native player exists, its event route is
attached, protocol compatibility is confirmed, and immutable capabilities are
available. Creation failure is returned directly by `create`; no unobserved
Future or property-read side effect is permitted.

A Load returns a session handle after the new session is committed:

```dart
final session = await player.load(
  YlNetworkSource(
    Uri.parse('https://media.example/live.m3u8'),
    intent: YlStreamIntent.live,
    format: YlMediaFormat.hls,
  ),
  options: const YlLoadOptions(autoplay: false),
);

await session.ready;
await session.play();
await session.firstFrame;
```

Load completion means that validation and routing succeeded and the native
implementation committed the session. It does not mean Ready or First Frame.
The session exposes separately correlated futures for those milestones.
The platform adapter completes Load only after receiving both its commit reply
and the corresponding authoritative full state, regardless of delivery order.
A returned handle can issue play immediately without an extra event-loop pump.
A replacement, Stop, or disposal during this barrier invalidates the pending
Load instead of returning a handle to a session that is already stale.

Before commit, the previous session remains authoritative. A pre-commit failure
leaves it unchanged. After commit, network, container, or decoder failure
belongs to the new session. A newer Load cancels an older uncommitted Load.

Session-scoped commands are:

- play and pause;
- seek to position and seek to live edge;
- playback speed;
- audio-track selection;
- runtime video constraints.

Player-scoped commands are:

- assess a source;
- load;
- volume;
- stop;
- dispose.

Calling a command through a replaced or stopped session fails with a stable
`session.stale` failure. It can never control whichever source became current
later. Stop ends the current session and returns the Player to idle while
retaining its native instance and video output.

Ready and First Frame are historical milestones cached per session. A same-
session First Frame is not discarded merely because a newer timeline revision
arrived first. Replaced/stopped sessions cannot reveal the current output.
Pending milestone failures have internal error observers so applications that
do not await every milestone receive no unhandled asynchronous error; awaiting
the same Future still reports its failure. Keep current and bounded in-flight
records only, and release invalidated session records.

Controller disposal is idempotent. Commands after disposal fail with a stable
player-lifecycle failure rather than a generic `StateError`.

## 6. Media Sources and Requests

`YlMediaSource` becomes a sealed hierarchy:

- `YlFileSource` for validated local filesystem media;
- `YlNetworkSource` for absolute HTTP or HTTPS media;
- `YlAndroidContentSource` for the explicitly Android-only content-URI route.

`YlStreamIntent` has `automatic`, `onDemand`, and `live` values. It replaces the
ambiguous default-false live flag. `YlMediaFormat` has one `flv` value rather
than separate `httpFlv` and `flv` spellings. Other initial formats are
automatic, HLS, MP4, MOV, Matroska, WebM, MPEG-TS, MPEG-PS, and AVI.

Network URIs must have an HTTP(S) scheme and non-empty host. URI user-info is
rejected. File paths, header names, and header values receive release-mode
validation before any native call. Player-owned transport headers cannot be
overridden accidentally.

HTTP request metadata separates ordinary headers from credentials:

```dart
YlHttpRequest(
  headers: <String, String>{'User-Agent': 'Example'},
  credentials: <String, String>{'X-Api-Key': 'secret'},
)
```

Ordinary headers may be forwarded where the selected media protocol requires
cross-origin resources. Credentials are sent only to the source origin and
remain stripped after an origin-changing redirect. This protection applies to
custom token names, not only Authorization and Cookie.

## 7. Policies and Enforcement

Policies distinguish a preference from a requirement. Default policies favor
compatibility and report limitations. Explicit requirements fail when they
cannot be enforced.

### 7.1 Network policy

`YlNetworkPolicy.platformDefault` delegates scheduling, timeout, and retry
behavior to the selected platform engine and promises no exact values.

`YlNetworkPolicy.managed` requires the implementation to enforce every supplied
timeout, retry, redirect, and credential rule. A route whose native network
stack is opaque or only partially controllable is incompatible with the
requested policy. Credential origin protection applies to platformDefault as
well: an opaque route must reject credential-bearing sources when it cannot
prove safe forwarding; it must not silently omit credentials or weaken scope.

Managed connectTimeout is the deadline from starting each initial/retry/redirect
HTTP hop until response headers (including DNS, connection, TLS and server wait).
readTimeout measures body inactivity after headers and resets on progress. There
is no overall/call-timeout field or total-time promise; native socket-connect
timeout settings alone do not implement this header deadline. maxRetries excludes the initial attempt. Retry only
idempotent GET/HEAD after transient transport failures or HTTP
408/429/500/502/503/504; validation, cancellation, certificate/trust failures and
other terminal responses are not retried. Retry n starts at 1 and waits
min(maxRetryDelay, baseRetryDelay * 2^(n-1)), with saturating arithmetic and no
jitter. A valid Retry-After seconds/date replaces this delay when within
maxRetryDelay; an excessive value ends retries rather than retrying too early.
Absent/malformed Retry-After uses the formula. Date parsing uses an injected wall
clock, while scheduling and timeouts use a monotonic clock. Redirect count is
separate from retry count and spans the original resource request's attempts;
retrying never restores stripped credentials. Engine/watchdog recovery must not
bypass this request budget by independently restarting the same request.

### 7.2 Buffer strategy

The built-in strategies are automatic, low latency, and smooth playback. They
are optimization goals rather than exact memory guarantees.

`YlBufferStrategy.bounded` supplies required minimum and maximum managed-media
durations plus a maximum managed byte count. All fields are required and
validated together. The byte boundary covers package-managed media caches,
compressed-packet queues, and frame or audio queues explicitly assigned to the
budget. Admission includes retained compressed samples waiting for submission,
not only samples already executing in a decoder. Reserve before retaining or
copying payload, carry the reservation for its full retained lifetime, and
release queued payload on cancellation. State explicitly which payload queues
are charged, including decoded frames/PCM assigned to the budget; collection
metadata and spare capacity are not a process RSS guarantee. It does not claim
to bound OS, TLS, decoder, or GPU allocations. Active/prepared/recovery generations
share the appropriate Player-owned budget rather than each receiving a fresh
full allowance.

A system engine such as AVPlayer that cannot enforce this budget rejects the
requirement rather than silently ignoring its fields.

### 7.3 Decoder policy

The decoder policies are system default, hardware preferred, and hardware
required.

Hardware preferred chooses a proven hardware path where available but permits a
system-managed engine whose actual decoder mode is unknown. Hardware required
accepts a video session only after hardware decode can be positively
established. An AVPlayer route cannot claim to satisfy hardware required because
AVPlayer does not expose that evidence. Android codec-name heuristics, including
API 24–28, are not positive hardware proof; without independently verified
evidence a strict video request is rejected. Audio-only sources have no video
hardware requirement. Decoder recreation must re-establish the requirement.
On iOS 15/16 retain the verified VideoToolbox string-key compatibility path;
newer SDK constant availability must not raise the declared deployment floor.

`YlDecoderMode` is `unknown`, `hardware`, or `software`; it replaces the
non-null boolean that currently conflates unknown and software.

### 7.4 Load options

`YlLoadOptions` contains autoplay, optional start position, buffer strategy,
initial video constraints, and an optional per-load decoder-policy override.
Network request policy remains part of the network source because it describes
how that source must be fetched.

## 8. Capabilities and Source Assessment

`YlPlayerCapabilities` is an immutable device-and-implementation snapshot
returned during Player creation. It is not repeated in high-frequency playback
state. Device profile, available engines, decoder evidence, maximum known video
envelope, and supported public operations belong here.

Capabilities do not claim that a bare container hint proves source support.
Applications may request a `YlSourceAssessment` for a concrete source and load
options. Its outcome is:

- compatible;
- incompatible;
- requires inspection during Load.

The assessment includes a candidate engine, satisfied requirements,
limitations, and a structured rejection where applicable. Compatible means the
descriptor can be routed and the requested policies can be honored. It does not
guarantee network reachability or that uninspected media codecs will initialize.
Requirement and limitation identifiers are extensible typed values with stable,
validated wire strings rather than a closed enum or arbitrary diagnostic text.
Implementation identity has a single immutable authority in the SPI handshake;
controller read-only name/version getters expose it to apps without duplicating
it in capabilities or exporting the SPI metadata type.

Apple v0.2 managed fallback support is constrained by the shipped bridge:
Matroska and FLV (WebM only to the extent of actual codec support) are the managed
success routes. Managed HLS, MP4/MOV, AVI, and MPEG routes remain explicitly
unsupported until the required demuxers and controlled child-resource I/O exist.
AVPlayer remains the default compatible route where its guarantees are adequate.
Known supported strict-policy fixtures must succeed; a suite in which every
explicit requirement is rejected does not prove implementation of supported
managed playback.

Load performs the same assessment automatically, so calling assess first is
optional.

## 9. State and Events

`YlPlayerController` implements Flutter's `Listenable` contract and retains a
state stream for asynchronous consumers. Reading state or rendering a view has
no initialization side effect.

`YlPlayerState` contains:

- a monotonically increasing public revision;
- the current Playback Session ID, or null while idle;
- status: idle, loading, ready, playing, paused, buffering, completed, or
  failed;
- timeline, live-edge, and DVR information;
- video geometry;
- audio and video tracks;
- active playback engine;
- decoder mode and safe decoder identity where known;
- cross-platform playback metrics;
- the current terminal failure, if any.

All domain value objects implement structural equality, `hashCode`, and useful
safe `toString` output.

The public discrete events are:

- first frame;
- retry scheduled;
- playback engine changed;
- playback failed.

Every event contains a Playback Session ID, revision, and timestamp. Track and
ordinary status changes are state, not duplicate events. A terminal native
failure changes authoritative state and emits exactly one failure event. A
rejected command throws but does not mutate healthy playback state.

Native implementations send full snapshots for semantic changes and narrowly
defined deltas for periodic timeline and metric updates. Deltas are applied only
when their session identity and revision are current. Native typed callbacks
use one per-player FIFO dispatcher, awaiting each Dart acknowledgement before
sending the next callback across Pigeon's method-specific channels. Callback
sequence and state revision are distinct: event deduplication must not discard a
valid historical milestone solely because a newer state revision exists.
Callback timeout/disposal invalidates the route; it must not hang teardown.

## 10. Failure and Diagnostic Contract

Transportable failure data and thrown Dart exceptions are separate types:

```dart
final class YlFailure {
  final YlFailureCategory category;
  final String code;
  final String message;
  final bool retryable;
  final YlFailureScope scope;
  final String diagnosticId;
}

final class YlPlayerException implements Exception {
  final YlFailure failure;
}
```

Failure scope distinguishes command, session, and player failures. Stable codes
cover cancellation, stale sessions, unsupported policy, missing source,
network, container, decoder, resource, protocol, platform, and internal causes.

Public messages and string representations never contain media URIs, query
strings, user-info, headers, credentials, or native stacks. A centralized
redaction boundary applies before native diagnostics are logged or transported.
Public failures carry a diagnostic ID that can correlate with safe native logs.

Implementation-specific counters may be exposed through an explicitly optional
safe diagnostic stream. They do not become cross-platform playback metrics.

## 11. Metrics

The common metric model contains only values with shared semantics:

- load-to-ready duration;
- load-to-first-frame duration;
- rebuffer count and duration;
- dropped video frames;
- audio underruns;
- estimated bitrate;
- managed buffered duration and bytes;
- live offset;
- reconnect count.

Every metric is nullable. Null means unsupported or not yet measured; zero means
the implementation measured an actual zero. Android device tier moves to
capabilities, selected bitrate moves to the selected video track, and surface
rebuild or adaptive-downgrade counters move to diagnostics.

## 12. Video Output and View

`YlVideoGeometry` describes encoded size, display size, pixel aspect ratio,
rotation, and derived display aspect ratio. Native implementations use the best
authoritative geometry available from Media3, AVPlayer, or the managed fallback.

`YlPlayerView` defaults to:

- `BoxFit.contain`;
- centered alignment;
- a black background;
- the supplied placeholder until the current session presents its first frame;
- texture rendering with configurable filter quality.

The view first computes logical width = displaySize.width * pixelAspectRatio
and logical height = displaySize.height, then applies unapplied rotation, and
finally BoxFit. Rotation participates inside the fit calculation. Display-size
fields must not already bake in PAR and then multiply it a second time.

Applications may opt into another fit or placeholder policy. The view continues
to contain no controls, gestures, playlist behavior, or application state.

## 13. Platform SPI

The handwritten SPI represents Player and Session operations with public domain
types. It contains no channel maps, string command names, Flutter method-channel
objects, or Pigeon-generated classes.

Each implementation reports its name, version, supported SPI major, and
capabilities. Major incompatibility fails during Player creation. Normal Dart
package constraints remain the first compatibility boundary; runtime metadata
provides a deterministic failure for stale native artifacts or invalid manual
integration.

`yl_player_platform_interface/testing.dart` publishes a conformance harness for
third-party implementations. It verifies lifecycle, Load commit semantics,
stale session rejection, Stop, revision ordering, event correlation, failure
safety, policy rejection, and idempotent disposal. Every case has a configurable
deadline, isolated resources, and bounded finally cleanup, including late create
completion. Deterministic fixture hooks hold/release pre-commit loads to exercise
cancellation; no timing race substitutes for control. Known supported policy
cases have explicit success expectations alongside unsupported-policy cases.

## 14. Private Typed Transport

Android and Apple each keep a complete Pigeon-generated Dart/native pair inside
their own package. Generated types are private implementation details. This
keeps both ends of each transport on the same package version and avoids making
Pigeon code part of the public SPI.

Each native Player receives an instance-scoped typed channel after creation.
The current global event stream, repeated per-player filtering, map coercion,
and string command dispatch are removed.

The typed transport contains:

- a create handshake with schema version, native instance identity, texture
  identity, and capability payload;
- typed source and policy messages;
- typed session commands;
- full state and delta messages;
- typed events and failures;
- session ID, revision, and sequence validation.

Schemas specify every field's type, nullability, unit and range. Idle full state
has null sessionId; session events require non-empty IDs. Policy timeouts and
managed byte budgets fit signed 32-bit values; timeline positions, monotonic
timestamps, revisions and sequences use nonnegative signed 64-bit integers.
Nullable delta updates distinguish absent from explicit clearing.

Generated sources are committed. CI regenerates them and fails when the schema
or generated files drift.

## 15. Android Architecture

The Android implementation is decomposed into:

- plugin entry and registration;
- Player registry;
- decoder-lease coordinator;
- session coordinator and state reducer;
- Media3 engine adapter;
- media-source and network construction;
- video output lifecycle;
- metrics collection;
- safe diagnostics.

The decoder-lease coordinator validates and prepares a candidate session before
committing it. When a hardware resource must change owners, it quiesces the
previous owner, activates the candidate, commits on success, and restores the
previous owner on failure. Activation and restoration are cancellable async
stages so the main looper remains free for decoder callbacks, Stop and lifecycle
events. If restoration itself fails, publish its actual terminal failure rather
than claiming the previous session is still playing. The plugin no longer marks a Player active or
deactivates peers before the target command has a viable commit path.

The existing hardware-only MediaCodec selector, bounded Media3 load-control
behavior, audio focus handling, surface restoration, stall watchdog, and
low-memory policies remain covered by regression tests during decomposition.

## 16. Shared Apple Architecture

`yl_player_apple` declares iOS and macOS with `sharedDarwinSource: true`. Its
native tree separates shared code from thin platform integrations:

```text
darwin/
├── Shared/
│   ├── Session
│   ├── SourceRouting
│   ├── Network
│   ├── HLS
│   ├── FFmpeg
│   ├── VideoToolbox
│   ├── Audio
│   ├── Clock
│   ├── Metrics
│   └── Diagnostics
├── Engines/
│   ├── AvPlayerEngine
│   └── ManagedFallbackEngine
├── iOS/
│   ├── Lifecycle
│   ├── AudioSession
│   └── TextureOutput
└── macOS/
    ├── Lifecycle
    ├── DisplayTimer
    └── TextureOutput
```

Common source routing, request policy, HLS handling, byte sources, FFmpeg
wrappers, VideoToolbox decode, audio conversion, state, metrics, and recovery
policy have one source of truth. Conditional platform code remains concentrated
in integration adapters.

The iOS device, iOS simulator, and universal macOS FFmpeg bridge slices are
packaged in one XCFramework with repeatable source and artifact verification.

Migration first moves tested behavior without changing algorithms. After
parity, the oversized fallback backend is decomposed into session state,
demuxing, video decode, audio pipeline, frame scheduling, and recovery
components. Behavioral changes require their own failing test.

## 17. Audio and Lifecycle Ownership

`YlAudioPolicy.appManaged` is the default. The host application controls shared
iOS audio-session and Android audio-focus policy. The plugin does not globally
change or deactivate audio state it does not own.

`YlAudioPolicy.pluginManagedMediaPlayback` is an explicit convenience mode. In
that mode, the plugin manages media playback audio focus, noisy-output handling,
and Apple playback-session activation. It records ownership and deactivates only
state it activated, and only after the last plugin-managed Player releases it.
Apple audio leases are process-wide across Flutter engine/plugin registrations.
Android uses one focus/noisy owner; when the shared coordinator owns focus,
individual ExoPlayer instances do not also enable automatic focus management.
Lifecycle suspension covers all active and pending sessions, including audio-only
sessions without a video-decoder lease.

Background audio remains unsupported. Existing lifecycle suspension and
resource-release behavior is preserved and made explicit in state.

## 18. Migration Sequence

### Phase 0: preserve the verified baseline

Record the current full gate results and preserve the existing uncommitted
macOS and channel changes independently. Architecture work must not overwrite,
silently absorb, or revert those changes. Those original changes are now
checkpointed by 1b239e0 and 49f59cf; include the separately reviewed submission,
audio, display and test fixes in the migration baseline. Command roots are
resolved once from the selected checkout/worktree, never a machine-specific
original checkout path.

### Phase 1: public v0.2 domain and SPI

Add the new domain models, Player/Session API, platform SPI, fake implementation,
and conformance tests. Use a temporary adapter over the existing native
transport so the repository remains testable while native migration begins.
First synchronize migration package versions and workspace constraints. Introduce
v2 definitions behind an internal barrel while v1 remains buildable; add native
Stop before switching the API. Adapter/controller/registration/example migration
and removal of superseded v1 exports form one atomic green cutover, not separate
broken commits. Do not publish transitional packages.

### Phase 2: Android typed transport and coordination

Move Android to its private Pigeon pair, implement Load and Session semantics,
add Stop and strict policy handling, and replace eager peer deactivation with
transactional decoder-lease coordination.

### Phase 3: Apple package consolidation

Create `yl_player_apple`, merge the bridge XCFramework, move common sources into
the Darwin layout without algorithm changes, add the private Pigeon pair, and
prove iOS/macOS behavior parity before changing package endorsement. Bootstrap
independent Flutter consumers early so CocoaPods and SwiftPM checks have genuine
Flutter/FlutterMacOS engine linkage. A bare swift build with an unresolved
relative FlutterFramework dependency is not a consumer gate. Artifact provenance
requires clean source/toolchain rebuild evidence, not simply replacing a binary
and updating its checksum.

### Phase 4: Apple decomposition and policy enforcement

Split native responsibilities, implement explicit audio ownership, unify
source assessment and strict policy behavior, centralize diagnostics, and
remove duplicated Apple sources.

### Phase 5: view, cleanup, and release surface

Adopt Video Geometry in the public view, migrate all examples, delete the old
API and old platform packages, update documentation and migration guidance, and
run publication checks.

No compatibility shim is required for v0.1 application source. The migration
guide must map every removed public symbol to the new contract.

## 19. Test and Verification Strategy

All behavioral work follows red-green-refactor. Each commit passes analysis and
affected tests; complete foundation/native/consumer gates run at phase boundaries.
PR quick gates cover analysis, Dart/conformance, generated transport drift,
artifact manifests and affected native tests. Nightly/release gates supply all
automated devices, independent consumers, architecture and reproducibility
checks. Android emulator CI covers API 24 and 36, with API 35 only an optional
extra. Skipped checks are not recorded as passing. Required coverage includes:

### Dart and SPI

- explicit creation success and failure;
- Load commit, cancellation, replacement, Ready, and First Frame;
- stale-session command rejection;
- command failure preserving healthy state;
- Stop and idempotent disposal;
- structural equality and revision ordering;
- strict source and policy validation;
- capability and source-assessment honesty;
- event correlation and one-shot terminal failures;
- diagnostic redaction;
- video geometry and BoxFit behavior;
- reusable third-party implementation conformance tests.

### Android

- Pigeon schema and adapter tests;
- Media3 source, network, load-control, decoder, audio-focus, surface, and
  lifecycle unit tests;
- decoder-lease commit and rollback tests;
- no credential forwarding after an origin change;
- API 24-or-later emulator integration for local and loopback HLS, progressive
  media, and supported live routes;
- source replacement and multi-Player failure scenarios.

### iOS and macOS

- shared-core XCTest coverage;
- thin platform-integration tests;
- AVPlayer and managed-fallback routing;
- local and loopback HLS, MKV, and FLV integration;
- request credential scope and redirect behavior;
- lifecycle, recovery, cancellation, replacement, clock, scheduler, and audio
  behavior;
- iOS Simulator integration;
- macOS arm64/x86_64 build, link, integration, and Rosetta smoke.

### Packaging and CI

- deterministic Pigeon regeneration;
- combined XCFramework slice, checksum, and linkage contracts;
- Swift Package Manager and CocoaPods consumer fixtures;
- consistent iOS 15 and macOS 12 deployment floors;
- Gradle consumer compatibility rather than relying only on the plugin example;
- package analysis, tests, formatting, documentation, and publish dry-runs.

All automated network tests use loopback servers and repository fixtures. The
current external Apple CDN dependency is removed.

Physical Android TV endurance, physical iOS VideoToolbox evidence, Intel Mac
runtime, long soak/reconnect runs, and Instruments/memgraph profiles remain
separate evidence gates. Documentation must say unverified until each gate is
actually executed.

## 20. Performance Invariants

- Encoded packets, decoded frames, and PCM never cross the Dart boundary.
- Periodic updates do not resend capabilities, tracks, static geometry, or
  static decoder metadata.
- State deltas cannot revive an older Playback Session.
- Managed buffer ceilings retain their documented allocation scope.
- Package restructuring does not change media clocks, decoder throughput,
  presentation order, or reconnect ordering without measured evidence and a
  failing regression test.
- Typed transport overhead is measured against the existing delta protocol and
  must not regress observable update cadence.

## 21. Acceptance Criteria

The redesign is complete when:

- every public command, state, and event is correlated to a Playback Session;
- explicit managed-network, bounded-buffer, and hardware-required requests are
  enforced or rejected, never silently weakened;
- Android candidate failure cannot destroy a previously active Player;
- AVPlayer decoder mode is reported as unknown rather than false software;
- public failures and diagnostics contain no URL, query, credential, header, or
  raw stack data;
- `yl_player` exposes no platform registration or transport implementation API;
- the platform SPI conformance suite can validate a third-party fake package;
- Android and Apple use private typed transports with no hand-written command
  map protocol;
- iOS and macOS share one Apple core and one combined bridge artifact;
- the player view preserves display geometry and placeholder semantics;
- Android, iOS, macOS, packaging, codegen, foundation, and publication gates
  pass from the migrated tree;
- deferred physical-device and endurance claims remain explicitly identified.
