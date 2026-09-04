# Dart Contract and State Semantics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make public validation release-safe, make native events authoritative for playback state, and replace the duplicated Android/iOS Dart channel layers with one versioned implementation that merges compact state deltas.

**Architecture:** Keep immutable public models in `yl_player_platform_interface`, expose channel helpers only through a separate `yl_player_channel.dart` entrypoint, and let each endorsed platform provide only its channel names, platform label, and initial engine. Full native snapshots establish a source generation; subsequent version-1 deltas update only continuous fields and are ignored unless their generation matches.

**Tech Stack:** Dart 3.12, Flutter 3.44, `MethodChannel`, `EventChannel`, `ValueNotifier`, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-09-04-full-repository-optimization-design.md`

## Global Constraints

- Existing application source code must continue to compile.
- Minimum versions remain Dart 3.12 and Flutter 3.44.
- Native state events remain the sole authority for playback state; rejected method calls must not synthesize error state or `YlErrorEvent`.
- Platform-player creation failure remains terminal in `YlPlayerController`.
- The ordinary `yl_player_platform_interface.dart` barrel must not export channel implementation helpers.
- Protocol payloads and diagnostics must not expose media URLs, query strings, credentials, or headers.
- The default position update interval remains 250 ms.
- Every behavior change follows red-green-refactor and ends in a focused commit.

## File Structure

- Create `packages/yl_player_platform_interface/lib/src/validation.dart`: release-safe configuration and command validators.
- Create `packages/yl_player_platform_interface/lib/yl_player_channel.dart`: explicit entrypoint for endorsed channel implementations.
- Create `packages/yl_player_platform_interface/lib/src/channel/channel_codec.dart`: wire constants, encoders, full-state decoder, delta merger, and error decoder.
- Create `packages/yl_player_platform_interface/lib/src/channel/channel_player.dart`: shared `YlChannelPlayer` implementation and event-stream lifecycle handling.
- Create `packages/yl_player_platform_interface/test/validation_test.dart`: public validation boundary tests.
- Create `packages/yl_player_platform_interface/test/channel_codec_test.dart`: malformed payload, full snapshot, and delta tests.
- Create `packages/yl_player_platform_interface/test/channel_player_test.dart`: command, stream failure, generation, and disposal tests.
- Modify `packages/yl_player_platform_interface/lib/src/configuration.dart`: hardware-only default and deprecation documentation.
- Modify `packages/yl_player_platform_interface/lib/src/playback_metrics.dart`: immutable `copyWith` used by delta merging.
- Modify `packages/yl_player_platform_interface/lib/yl_player_platform_interface.dart`: export validation only.
- Modify `packages/yl_player/lib/src/player_controller.dart`: validate inputs and distinguish creation failure from command rejection.
- Modify `packages/yl_player/test/player_controller_test.dart` and `packages/yl_player/test/support/fake_player_platform.dart`: state-authority and validation coverage.
- Modify `packages/yl_player_android/lib/yl_player_android.dart` and `packages/yl_player_ios/lib/yl_player_ios.dart`: construct the shared channel player.
- Modify both endorsed-package Dart tests to cover only registration, create wiring, and platform-specific error codes.
- Delete the four duplicated files under `packages/yl_player_android/lib/src/` and `packages/yl_player_ios/lib/src/` after migration.

---

### Task 1: Release-safe public validation and decoder-policy default

**Files:**
- Create: `packages/yl_player_platform_interface/lib/src/validation.dart`
- Create: `packages/yl_player_platform_interface/test/validation_test.dart`
- Modify: `packages/yl_player_platform_interface/lib/src/configuration.dart`
- Modify: `packages/yl_player_platform_interface/lib/yl_player_platform_interface.dart`
- Modify: `packages/yl_player_platform_interface/test/models_test.dart`

**Interfaces:**
- Produces: `validateYlPlayerConfiguration(YlPlayerConfiguration)`, `validateYlSeekPosition(Duration)`, `validateYlPlaybackSpeed(double)`, `validateYlVolume(double)`, and `validateYlQualityConstraint(YlQualityConstraint)`; each returns `void` and throws `ArgumentError` for invalid input.
- Produces: `YlPlayerConfiguration.decoderPolicy` defaulting to `YlDecoderPolicy.hardwareOnly`.
- Compatibility: `YlDecoderPolicy.preferHardware` remains present and is annotated deprecated.

- [ ] **Step 1: Write the failing validation tests**

Create table-driven tests with exact boundaries:

```dart
test('accepts documented configuration boundaries', () {
  expect(
    () => validateYlPlayerConfiguration(const YlPlayerConfiguration(
      networkPolicy: YlNetworkPolicy(maxRetries: 0, maxRedirects: 20),
      minBufferDuration: Duration.zero,
      maxBufferDuration: Duration.zero,
      maxBufferBytes: 1,
      positionEventInterval: Duration(milliseconds: 1),
    )),
    returnsNormally,
  );
});

test('rejects invalid timeout and retry relationships in release logic', () {
  const invalid = <YlPlayerConfiguration>[
    YlPlayerConfiguration(networkPolicy: YlNetworkPolicy(connectTimeout: Duration.zero)),
    YlPlayerConfiguration(networkPolicy: YlNetworkPolicy(readTimeout: Duration.zero)),
    YlPlayerConfiguration(networkPolicy: YlNetworkPolicy(maxRetries: 21)),
    YlPlayerConfiguration(networkPolicy: YlNetworkPolicy(maxRedirects: 21)),
    YlPlayerConfiguration(networkPolicy: YlNetworkPolicy(
      baseRetryDelay: Duration(seconds: 2),
      maxRetryDelay: Duration(seconds: 1),
    )),
  ];
  for (final configuration in invalid) {
    expect(() => validateYlPlayerConfiguration(configuration), throwsArgumentError);
  }
});

test('rejects invalid command values', () {
  expect(() => validateYlSeekPosition(const Duration(milliseconds: -1)), throwsArgumentError);
  expect(() => validateYlPlaybackSpeed(double.nan), throwsArgumentError);
  expect(() => validateYlPlaybackSpeed(0.249), throwsArgumentError);
  expect(() => validateYlPlaybackSpeed(4.001), throwsArgumentError);
  expect(() => validateYlVolume(double.infinity), throwsArgumentError);
  expect(() => validateYlVolume(-0.001), throwsArgumentError);
  expect(() => validateYlVolume(1.001), throwsArgumentError);
  expect(
    () => validateYlQualityConstraint(const YlQualityConstraint(maxWidth: 0)),
    throwsArgumentError,
  );
});
```

Update the default-model assertion from `preferHardware` to `hardwareOnly`.

- [ ] **Step 2: Run the tests and verify failure**

Run:

```bash
flutter test packages/yl_player_platform_interface/test/validation_test.dart packages/yl_player_platform_interface/test/models_test.dart
```

Expected: compilation fails because the validation functions do not exist and
the current const assertions reject the invalid fixtures; after the functions
compile, the default-policy assertion still fails until implementation.

- [ ] **Step 3: Implement validators with checked millisecond conversion**

Remove the constructor `assert` initializers from `YlNetworkPolicy`,
`YlQualityConstraint`, and `YlPlayerConfiguration`. This lets invalid values be
represented consistently in debug and release; the public/controller/channel
boundaries below reject them deterministically. Keep all constructors `const`.

Use a private Android-safe maximum of `0x7fffffff` milliseconds and these helpers:

```dart
const int _maxNativeMilliseconds = 0x7fffffff;
const int _maxNativeCount = 20;

void _positiveNativeDuration(Duration value, String name) {
  final milliseconds = value.inMilliseconds;
  if (milliseconds <= 0 || milliseconds > _maxNativeMilliseconds) {
    throw ArgumentError.value(value, name, 'must be 1..$_maxNativeMilliseconds milliseconds');
  }
}

void validateYlPlaybackSpeed(double speed) {
  if (!speed.isFinite || speed < 0.25 || speed > 4.0) {
    throw ArgumentError.value(speed, 'speed', 'must be finite and between 0.25 and 4.0');
  }
}

void validateYlVolume(double volume) {
  if (!volume.isFinite || volume < 0.0 || volume > 1.0) {
    throw ArgumentError.value(volume, 'volume', 'must be finite and between 0.0 and 1.0');
  }
}
```

Validate both timeouts with `_positiveNativeDuration`; retry delays as nonnegative and Android-safe; counts as `0..20`; `maxRetryDelay >= baseRetryDelay`; position interval as positive and Android-safe; optional buffer durations as nonnegative and Android-safe with `min <= max`; and all byte/dimension/bitrate values as `1..0x7fffffff`.

Annotate and change the default:

```dart
enum YlDecoderPolicy {
  @Deprecated('preferHardware currently resolves to hardwareOnly; use hardwareOnly.')
  preferHardware,
  hardwareOnly,
}

this.decoderPolicy = YlDecoderPolicy.hardwareOnly,
```

Export `src/validation.dart` from the ordinary platform-interface barrel.

- [ ] **Step 4: Format and prove the focused suite passes**

Run:

```bash
dart format packages/yl_player_platform_interface/lib packages/yl_player_platform_interface/test
flutter test packages/yl_player_platform_interface/test/validation_test.dart packages/yl_player_platform_interface/test/models_test.dart
```

Expected: all tests pass without relying on constructor asserts.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_platform_interface
git commit -m "feat: validate player inputs in release builds"
```

### Task 2: Controller state authority and command validation

**Files:**
- Modify: `packages/yl_player/lib/src/player_controller.dart`
- Modify: `packages/yl_player/test/player_controller_test.dart`
- Modify: `packages/yl_player/test/support/fake_player_platform.dart`

**Interfaces:**
- Consumes: all validators from Task 1.
- Produces: synchronous validation before backend calls; command errors propagate unchanged without state/event mutation; player creation errors still call `_reportError` once.

- [ ] **Step 1: Replace the incorrect error test with failing authority tests**

Make the fake support a `createError`, then assert both branches:

```dart
test('command rejection preserves native state and emits no error event', () async {
  const error = YlPlayerError(
    category: YlPlayerErrorCategory.decoderUnsupported,
    code: 'decoder.unsupported',
    message: 'Unsupported stream.',
  );
  backend
    ..currentState = YlPlayerState(status: YlPlaybackStatus.playing)
    ..playError = error;
  final controller = YlPlayerController();
  final events = <YlPlayerEvent>[];
  final subscription = controller.events.listen(events.add);

  await expectLater(controller.play(), throwsA(same(error)));

  expect(controller.state.status, YlPlaybackStatus.playing);
  expect(controller.state.error, isNull);
  expect(events, isEmpty);
  await subscription.cancel();
  await controller.dispose();
});

test('backend creation failure remains terminal', () async {
  const error = YlPlayerError(
    category: YlPlayerErrorCategory.resource,
    code: 'platform.create_failed',
    message: 'Create failed.',
  );
  final controller = YlPlayerController(platform: FakePlayerPlatform(backend)..createError = error);
  final events = <YlPlayerEvent>[];
  final subscription = controller.events.listen(events.add);

  await expectLater(controller.play(), throwsA(same(error)));
  expect(controller.state.status, YlPlaybackStatus.error);
  expect((events.single as YlErrorEvent).error, same(error));
  await subscription.cancel();
  await controller.dispose();
});
```

Add tests proving invalid seek, speed, volume, quality, and constructor configuration do not add fake backend calls.

- [ ] **Step 2: Run the controller suite and verify failure**

Run:

```bash
flutter test packages/yl_player/test/player_controller_test.dart
```

Expected: the command-rejection test observes `error` state and one synthetic event; invalid command values reach the fake backend.

- [ ] **Step 3: Separate creation failure from command failure**

Validate configuration before invoking `createPlayer`, validate each command before `_run`, and replace `_run` with this error boundary:

```dart
Future<YlPlatformPlayer> _getBackendForCommand() async {
  try {
    return await _getBackend();
  } on YlPlayerError catch (error) {
    if (_backend == null && !identical(_state.error, error)) {
      _reportError(error);
    }
    rethrow;
  }
}

Future<void> _run(Future<void> Function(YlPlatformPlayer backend) command) async {
  if (_isDisposed) throw StateError('YlPlayerController has been disposed.');
  final backend = await _getBackendForCommand();
  if (_isDisposed) throw StateError('YlPlayerController has been disposed.');
  await command(backend);
}
```

Do not catch `YlPlayerError` around `await command(backend)`. Keep `_connectForTexture` creation-error reporting and the existing terminal, best-effort disposal behavior.

- [ ] **Step 4: Run and format the controller suite**

Run:

```bash
dart format packages/yl_player/lib/src/player_controller.dart packages/yl_player/test
flutter test packages/yl_player/test/player_controller_test.dart
```

Expected: all controller tests pass, including exactly one terminal creation error.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player/lib/src/player_controller.dart packages/yl_player/test
git commit -m "fix: keep command failures out of player state"
```

### Task 3: Shared versioned channel codec and delta merger

**Files:**
- Create: `packages/yl_player_platform_interface/lib/yl_player_channel.dart`
- Create: `packages/yl_player_platform_interface/lib/src/channel/channel_codec.dart`
- Create: `packages/yl_player_platform_interface/test/channel_codec_test.dart`
- Modify: `packages/yl_player_platform_interface/lib/src/playback_metrics.dart`
- Modify: `packages/yl_player_platform_interface/test/models_test.dart`

**Interfaces:**
- Produces: `const ylChannelProtocolVersion = 1` and `YlChannelWireKeys` constants.
- Produces: `encodeYlConfiguration`, `encodeYlSource`, `encodeYlQualityConstraint`, `decodeYlState`, `mergeYlStateDelta`, `decodeYlEvent`, `decodeYlError`, `decodeYlPlatformException`, and `ylStringMap`.
- `mergeYlStateDelta` signature: `YlPlayerState mergeYlStateDelta(YlPlayerState current, Object? value)`.
- Produces: `YlPlaybackMetrics.copyWith(...)` preserving omitted metrics.

- [ ] **Step 1: Write failing codec, malformed-value, and metric-copy tests**

Cover one complete snapshot and this exact delta:

```dart
final current = YlPlayerState(
  status: YlPlaybackStatus.playing,
  position: const Duration(seconds: 1),
  audioTracks: const <YlMediaTrack>[],
  capabilities: YlPlayerCapabilities(supportedFormats: {YlFormatHint.hls}),
  metrics: const YlPlaybackMetrics(rebufferCount: 2, droppedVideoFrames: 3),
);
final merged = mergeYlStateDelta(current, <String, Object?>{
  'positionMs': 1750,
  'bufferedPositionMs': 5000,
  'liveOffsetMs': null,
  'isAtLiveEdge': true,
  'metrics': <String, Object?>{
    'droppedVideoFrames': 4,
    'bufferedDurationMs': 3250,
  },
});

expect(merged.position, const Duration(milliseconds: 1750));
expect(merged.metrics.rebufferCount, 2);
expect(merged.metrics.droppedVideoFrames, 4);
expect(merged.capabilities, same(current.capabilities));
```

Also assert: non-map state data returns defensive defaults; unknown enum names use documented fallbacks; malformed lists do not throw; `droppedVideoFrames` is the only accepted dropped-frame key; and `YlPlaybackMetrics.copyWith(droppedVideoFrames: 4)` preserves every omitted field.

- [ ] **Step 2: Run the codec tests and verify failure**

Run:

```bash
flutter test packages/yl_player_platform_interface/test/channel_codec_test.dart packages/yl_player_platform_interface/test/models_test.dart
```

Expected: compilation fails because the channel entrypoint, merger, and metrics `copyWith` do not exist.

- [ ] **Step 3: Move the codec once and implement delta merging**

Move the current duplicated codec behavior into the shared file, rename public-by-entrypoint functions with the `Yl` prefix shown above, and centralize keys:

```dart
abstract final class YlChannelWireKeys {
  static const protocolVersion = 'protocolVersion';
  static const generation = 'generation';
  static const state = 'state';
  static const stateDelta = 'stateDelta';
  static const droppedVideoFrames = 'droppedVideoFrames';
}
```

Implement delta fields with presence checks so explicit `null` clears `liveOffset`, while omitted fields preserve the current value. Merge nested metrics through `YlPlaybackMetrics.copyWith`; never replace tracks, video size, decoder identity, capabilities, status, or current error from a delta.

Export only the two new channel source files from `yl_player_channel.dart`; do not modify the ordinary barrel for these symbols.

- [ ] **Step 4: Format and run shared model/codec tests**

Run:

```bash
dart format packages/yl_player_platform_interface/lib packages/yl_player_platform_interface/test
flutter test packages/yl_player_platform_interface/test
```

Expected: all platform-interface tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_platform_interface
git commit -m "feat: add shared versioned player channel codec"
```

### Task 4: Shared channel player and event-stream lifecycle

**Files:**
- Create: `packages/yl_player_platform_interface/lib/src/channel/channel_player.dart`
- Create: `packages/yl_player_platform_interface/test/channel_player_test.dart`
- Modify: `packages/yl_player_platform_interface/lib/yl_player_channel.dart`

**Interfaces:**
- Consumes: Task 1 validators and Task 3 codecs.
- Produces: `YlChannelPlayer({required int playerId, required int initialTextureId, required MethodChannel methods, required Stream<Object?> nativeEvents, required String platform, required YlPlaybackEngine initialEngine})`.
- Produces: `createYlChannelPlayer({required YlPlayerConfiguration configuration, required MethodChannel methods, required Stream<Object?> nativeEvents, required String platform, required YlPlaybackEngine initialEngine})`.
- Error codes: `channel.event_malformed`, `channel.event_stream_error`, and
  `channel.event_stream_done`.

- [ ] **Step 1: Write failing shared-player behavior tests**

Use a mock `MethodChannel` and a synchronous `StreamController<Object?>`. Assert:

```dart
await expectLater(player.play(), throwsA(isA<YlPlayerError>()));
expect(player.state.status, YlPlaybackStatus.playing);
expect(events, isEmpty);
```

Then send a full envelope with `protocolVersion: 1`, `generation: 8`, and `type: 'state'`; send a matching `stateDelta` and assert it merges; send generation 7 and 9 deltas and assert neither changes state; send a delta before any full snapshot and assert no state emission.

Send a native `error` event followed by a full state whose status is `error`
and whose error map has the same stable code. Assert the event is forwarded
exactly once and the full state—not the discrete event—performs the state
transition.

For stream failure, call `nativeEvents.addError(StateError('transport'))`, then assert exactly one `YlErrorEvent` with code `channel.event_stream_error`, one error state, and no uncaught zone error. Close a separate stream normally and assert exactly one `channel.event_stream_done` error. Repeated error/done callbacks must not double-report. Disposal remains idempotent and closes local resources even when native disposal fails.

Send a matching-player envelope with an unknown type and a `state` envelope
whose payload is not a map; assert exactly one `channel.event_malformed` error.
Unknown-player envelopes remain ignored because the stream is multiplexed.

- [ ] **Step 2: Run the shared-player test and verify failure**

Run:

```bash
flutter test packages/yl_player_platform_interface/test/channel_player_test.dart
```

Expected: compilation fails because `YlChannelPlayer` and `createYlChannelPlayer` do not exist.

- [ ] **Step 3: Implement the shared player**

Listen with all callbacks and no synthetic method-call error:

```dart
_nativeSubscription = nativeEvents.listen(
  _handleNativeEvent,
  onError: _handleNativeStreamError,
  onDone: _handleNativeStreamDone,
);

Future<void> _command(String name, [Map<String, Object?> arguments = const {}]) async {
  if (_disposed) throw StateError('The $platform platform player has been disposed.');
  try {
    await methods.invokeMethod<void>('command', {
      'playerId': playerId,
      'name': name,
      'arguments': arguments,
    });
  } on PlatformException catch (error) {
    throw decodeYlPlatformException(error, platform: platform);
  }
}
```

Track `int? _sourceGeneration` and a `_streamFailureReported` guard. A full version-1 state records its generation; a delta applies only when both generations are non-null and equal. Continue decoding legacy full `state` envelopes without version/generation for compatibility, but never apply deltas to a legacy snapshot. Treat matching-player unknown envelope types and invalid required payload shapes as malformed; optional fields inside a valid state map continue using defensive defaults.

Validate configuration inside `createYlChannelPlayer` and command arguments
again for direct platform-interface consumers. For `platform: 'android'`, keep
`android.invalid_create_response` and `android.plugin_unavailable`; for
`platform: 'ios'`, keep `ios.invalid_create_response` and
`ios.plugin_unavailable`.

- [ ] **Step 4: Run and format shared-channel tests**

Run:

```bash
dart format packages/yl_player_platform_interface/lib packages/yl_player_platform_interface/test
flutter test packages/yl_player_platform_interface/test/channel_player_test.dart packages/yl_player_platform_interface/test/channel_codec_test.dart
```

Expected: all shared-channel tests pass with no uncaught async error.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_platform_interface
git commit -m "feat: share channel player lifecycle"
```

### Task 5: Migrate endorsed adapters and remove duplication

**Files:**
- Modify: `packages/yl_player_android/lib/yl_player_android.dart`
- Modify: `packages/yl_player_android/test/yl_player_android_test.dart`
- Delete: `packages/yl_player_android/lib/src/channel_android_player.dart`
- Delete: `packages/yl_player_android/lib/src/channel_codec.dart`
- Modify: `packages/yl_player_ios/lib/yl_player_ios.dart`
- Modify: `packages/yl_player_ios/test/yl_player_ios_test.dart`
- Delete: `packages/yl_player_ios/lib/src/channel_ios_player.dart`
- Delete: `packages/yl_player_ios/lib/src/channel_codec.dart`

**Interfaces:**
- Consumes: `createYlChannelPlayer` from Task 4.
- Produces: unchanged `YlPlayerAndroid` and `YlPlayerIos` public classes and registration behavior.

- [ ] **Step 1: Change platform tests to demand the shared behavior**

Keep registration and command-delegation tests. In both packages, make a
command throw a `PlatformException`, first emit a healthy playing state, and
assert the error Future preserves platform-specific decoding while no
synthetic state/event is emitted. On iOS, use code `network.cancelled` for an
`open` superseded by a second operation and assert the active state remains
playing with no `YlErrorEvent`. Assert create configuration uses
`decoderPolicy: 'hardwareOnly'`. Remove duplicated codec assertions now covered
by the platform-interface suite.

- [ ] **Step 2: Run endorsed-package tests before migration**

Run:

```bash
flutter test packages/yl_player_android/test/yl_player_android_test.dart
flutter test packages/yl_player_ios/test/yl_player_ios_test.dart
```

Expected: new command-authority assertions fail because the duplicated players still synthesize error state and events.

- [ ] **Step 3: Replace both adapters with the shared factory**

Import the explicit entrypoint and delegate:

```dart
import 'package:yl_player_platform_interface/yl_player_channel.dart';

@override
Future<YlPlatformPlayer> createPlayer(YlPlayerConfiguration configuration) =>
    createYlChannelPlayer(
      configuration: configuration,
      methods: _methodChannel,
      nativeEvents: _nativeEvents,
      platform: 'android', // use 'ios' in YlPlayerIos
      initialEngine: YlPlaybackEngine.media3, // use avPlayer on iOS
    );
```

Delete the four now-unused duplicated files. Do not export `yl_player_channel.dart` through either app-facing package.

- [ ] **Step 4: Run every Dart package test and static check**

Run:

```bash
sh tool/check_foundation.sh
```

Expected: analysis, formatting, all seven Dart test groups, and the FFmpeg build-contract test pass.

- [ ] **Step 5: Commit**

```bash
git add packages/yl_player_android packages/yl_player_ios
git commit -m "refactor: unify platform channel adapters"
```

### Task 6: Dart-phase regression audit

**Files:**
- Modify only if a regression test exposes a defect: files changed in Tasks 1–5.

**Interfaces:**
- Produces: a clean Dart foundation on which both native plans depend.

- [ ] **Step 1: Run analyzer and all package tests from a clean process**

Run:

```bash
sh tool/check_foundation.sh
git diff --check
```

Expected: exit 0, no formatting changes, and no whitespace errors.

- [ ] **Step 2: Verify the duplicate implementations are gone**

Run:

```bash
test ! -e packages/yl_player_android/lib/src/channel_codec.dart
test ! -e packages/yl_player_android/lib/src/channel_android_player.dart
test ! -e packages/yl_player_ios/lib/src/channel_codec.dart
test ! -e packages/yl_player_ios/lib/src/channel_ios_player.dart
rg -n "class YlChannelPlayer|droppedVideoFrames|stateDelta" packages/yl_player_platform_interface
```

Expected: all four `test ! -e` checks pass and each shared symbol has one implementation.

- [ ] **Step 3: Commit only if the audit required a correction**

```bash
git add packages
git commit -m "test: close Dart channel regressions"
```

If no files changed, record the passing commands in the execution notes and do not create an empty commit.
