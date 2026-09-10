# Migrating to yl_player 0.2

Version 0.2 replaces the implicit controller lifecycle with an explicitly
created Player and committed Session. It also narrows the application barrel,
separates player-wide choices from per-load requirements, and replaces raw
platform diagnostics with safe structured failures. No compatibility shim is
provided.

## Application API mapping

| v0.1 | v0.2 |
|---|---|
| `YlPlayerController(...)` | `await YlPlayerController.create(...)` |
| `YlPlayerConfiguration` | `YlPlayerOptions` plus per-load `YlLoadOptions` |
| `controller.open(source)` | `final session = await player.load(source)` |
| `controller.play/pause/seekTo` | `session.play/pause/seekTo` |
| `controller.seekToLiveEdge` | `session.seekToLiveEdge` |
| `controller.setPlaybackSpeed` | `session.setPlaybackSpeed` |
| `controller.selectAudioTrack` | `session.selectAudioTrack` |
| `controller.setQualityConstraint` | `session.setVideoConstraints` |
| `YlQualityConstraint` | `YlVideoConstraints` |
| `YlMediaSource.file/network/content` | `YlFileSource` / `YlNetworkSource` / `YlAndroidContentSource` |
| `YlMediaSourceKind` and `source.kind` | Source subtype checks; there is no public kind enum |
| `bool isLive` | `YlStreamIntent` (`automatic`, `onDemand`, or `live`) |
| `YlFormatHint.httpFlv` or `YlFormatHint.flv` | `YlMediaFormat.flv` |
| Other `YlFormatHint` values | Same-named `YlMediaFormat` values where present |
| `source.headers` | `YlHttpRequest(headers: ..., credentials: ...)` on `YlNetworkSource` |
| `YlBufferMode` and custom fields | `YlBufferStrategy` |
| `YlDecoderPolicy.preferHardware` | `YlDecoderPolicy.hardwarePreferred` |
| `YlDecoderPolicy.hardwareOnly` | `YlDecoderPolicy.hardwareRequired` |
| `YlNetworkPolicy(...)` | `YlNetworkPolicy.platformDefault()` or `YlNetworkPolicy.managed(...)` |
| `YlPlayerError` | `YlFailure` plus `YlPlayerException` |
| `YlPlayerErrorCategory` | `YlFailureCategory` |
| `isHardwareDecoding` | `YlDecoderMode` |
| `YlVideoSize` | `YlVideoGeometry` and `YlPixelSize` |
| `yl_player_ios` / `yl_player_macos` | `yl_player_apple` |

Constructor arguments move as follows:

| v0.1 configuration argument | v0.2 location |
|---|---|
| `decoderPolicy` | `YlPlayerOptions.decoderPolicy`, optionally overridden by `YlLoadOptions.decoderPolicyOverride` |
| `positionEventInterval` | `YlPlayerOptions.positionUpdateInterval` |
| no audio ownership argument | `YlPlayerOptions.audioPolicy` |
| `bufferMode` | `YlLoadOptions.bufferStrategy` |
| `minBufferDuration`, `maxBufferDuration`, `maxBufferBytes` | Required arguments of `YlBufferStrategy.bounded` |
| `networkPolicy` | `YlNetworkSource.networkPolicy` |
| no autoplay/start argument | `YlLoadOptions.autoplay` and `startPosition` |
| `YlQualityConstraint` | `YlLoadOptions.videoConstraints`, later changed with `session.setVideoConstraints` |

The former `balanced` and `stable` buffer modes have no exact identity. Choose
`automatic` when the platform should tune playback, `smoothPlayback` when the
goal is additional continuity, or an enforceable `bounded` request when exact
package-owned duration and byte limits are required. Built-in strategies are
goals, not strict memory promises.

## Lifecycle changes

Creation is asynchronous and can fail before a controller exists. Load no
longer means Ready: it completes at the native commit/state barrier and returns
`YlPlaybackSession`. Await `session.ready` separately and await
`session.firstFrame` only when video is expected. A newer Load, successful Stop,
or Dispose invalidates the previous handle with `session.stale`. Failed
candidate preparation and rejected Stop preserve the accepted session.

The controller's old `audioTracks`, `videoTracks`, and `metrics` convenience
getters move to `player.state.audioTracks`, `player.state.videoTracks`, and
`player.state.metrics`. Capabilities are now the non-null
`player.capabilities` creation snapshot rather than `state.capabilities`.

## State, events, and diagnostics

| v0.1 | v0.2 |
|---|---|
| `state.position`, `duration`, `bufferedPosition`, live/seek fields, `dvrWindow` | `state.timeline` fields |
| `state.videoSize` | `state.videoGeometry` |
| `state.decoderName` | `state.decoderIdentity` (sensitive; do not log) |
| `state.error` | `state.failure` |
| `YlPlaybackStatus.opening` | `YlPlaybackStatus.loading` |
| `YlPlaybackStatus.error` | `YlPlaybackStatus.failed` |
| `YlPlaybackStatus.disposed` | No terminal snapshot; operations fail with `player.disposed` |
| `YlPlaybackEngine.nativeFallback` | `YlPlaybackEngine.managedFallback` |
| `YlFirstFrameEvent(width, height)` | Correlated `YlFirstFrameEvent`; geometry is in state |
| `YlRetryEvent` | `YlRetryScheduledEvent` |
| `YlFallbackEvent` | `YlPlaybackEngineChangedEvent` |
| `YlTracksChangedEvent` | Authoritative track lists in `YlPlayerState` |
| `YlErrorEvent` | `YlPlaybackFailedEvent` and `state.failure` |
| `platformDiagnostic` | Opaque `diagnosticId`; raw native text is not public |

All v0.2 events carry `sessionId`, state revision, and monotonic occurrence time.
The retry event uses `retryIndex`, `delay`, and `failure`. Failures add explicit
`retryable` and `scope` fields. See [diagnostics](diagnostics.md).

Metrics now use `loadToReady`, `loadToFirstFrame`,
`managedBufferedDuration`, and `managedBufferedBytes`. The old `openDuration`,
`firstFrameDuration`, `bufferedDuration`, and `bufferedBytes` names do not carry
forward. Former Android-specific fields (`androidDeviceTier`,
`targetBufferBytes`, `adaptiveDowngradeCount`, `surfaceRebuildCount`, and
`selectedVideoBitrate`) are not in the v0.2 application metrics contract.
Absence is represented by nullable fields rather than synthetic zeroes.

`YlPlayerCapabilities.supportedFormats` is replaced by a conservative creation
snapshot (`availableEngines`, `supportedOperations`, decoder evidence, hardware
codecs, concurrency, and size limits) plus per-source `player.assess(...)`.
Assessment may require inspection and is not a playback guarantee.

## Platform implementors

Applications should import only `package:yl_player/yl_player.dart`. Version 0.1
wildcard-exported registration, backend SPI, and validation functions through
that barrel; v0.2 deliberately does not. Platform packages import
`package:yl_player_platform_interface/yl_player_platform_interface.dart`, and
tests may import its `testing.dart` conformance utilities.

The platform SPI now creates a player from `YlPlayerOptions`, publishes an
implementation identity with SPI major 2, assesses sources explicitly, returns
`YlPlatformLoadResult` only after commit/state pairing, receives session IDs on
session commands, and implements player-owned Stop. Validators are split into
the v0.2 option/source validators and state/publication validators. They remain
platform-interface APIs, not application-barrel APIs.
