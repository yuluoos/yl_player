# yl_player Public Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the publishable federated-plugin workspace and tested public Dart foundation that later Android and iOS playback backends implement.

**Architecture:** The app-facing `yl_player` package owns the controller and texture widget; `yl_player_platform_interface` owns every cross-platform value type and backend contract; endorsed Android and iOS packages register compile-safe placeholder backends until their native playback milestones are implemented. A Dart workspace resolves all four publishable packages and two private platform example apps locally while preserving hosted semantic-version dependencies for eventual pub.dev publication.

**Tech Stack:** Flutter 3.44.0, Dart 3.12.0, Dart pub workspaces, Kotlin, Swift, `plugin_platform_interface`, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-09-02-yl-player-design.md`

## Global Constraints

- Minimum Android version: Android 7.0, API 24.
- Minimum iOS version: iOS 15.0.
- Supported Flutter platforms in this milestone: Android and iOS only.
- Dart and platform channels never carry encoded packets, decoded video frames, or PCM buffers.
- The public API includes no controls UI, subtitles, DRM, source parsing, downloads, or telemetry upload.
- All player disposal is idempotent; stale callbacks from old source generations are ignored.
- No platform package claims functional playback before its native milestone passes acceptance tests.

---

## Planned File Structure

```text
pubspec.yaml                              # private Dart workspace root
analysis_options.yaml                     # shared lints
.gitignore                                # generated and tool output
packages/
  yl_player_platform_interface/
    lib/yl_player_platform_interface.dart # public platform contract exports
    lib/src/configuration.dart             # decoder and buffering policy
    lib/src/capabilities.dart              # device/source support report
    lib/src/media_source.dart              # local/network source model
    lib/src/media_track.dart               # audio/video track metadata
    lib/src/playback_metrics.dart           # local quality-of-experience snapshot
    lib/src/player_error.dart              # stable error categories and codes
    lib/src/player_event.dart              # discrete event hierarchy
    lib/src/player_state.dart              # immutable playback snapshot
    lib/src/player_platform.dart           # singleton platform contract
    lib/src/platform_player.dart           # one native-player contract
    test/models_test.dart
    test/player_platform_test.dart
  yl_player/
    lib/yl_player.dart                     # complete public app-facing exports
    lib/src/player_controller.dart         # lifecycle and state mirroring
    lib/src/player_view.dart               # texture-only Flutter widget
    test/player_controller_test.dart
    test/player_view_test.dart
    test/support/fake_player_platform.dart
    example/lib/main.dart                  # minimal integration shell
  yl_player_android/
    lib/yl_player_android.dart             # endorsed Dart registration
    lib/src/unsupported_android_player.dart
    android/src/main/kotlin/dev/ylplayer/android/YlPlayerAndroidPlugin.kt
    test/yl_player_android_test.dart
  yl_player_ios/
    lib/yl_player_ios.dart                 # endorsed Dart registration
    lib/src/unsupported_ios_player.dart
    ios/yl_player_ios/Sources/yl_player_ios/YlPlayerIosPlugin.swift
    test/yl_player_ios_test.dart
```

The generated package metadata, licenses, changelogs, READMEs, Gradle files, podspec, and example platform shells live beside these files.

---

### Task 1: Federated Workspace Skeleton

**Files:**
- Create: `pubspec.yaml`
- Create: `analysis_options.yaml`
- Create: `.gitignore`
- Create: `packages/yl_player/pubspec.yaml`
- Create: `packages/yl_player_platform_interface/pubspec.yaml`
- Create: `packages/yl_player_android/pubspec.yaml`
- Create: `packages/yl_player_ios/pubspec.yaml`
- Create: package `LICENSE`, `README.md`, and `CHANGELOG.md` files

**Interfaces:**
- Consumes: Flutter 3.44.0 and Dart 3.12.0 installed on the host.
- Produces: A four-package pub workspace in which all local package versions are `0.1.0-dev.1` and resolve through `resolution: workspace`.

- [ ] **Step 1: Prove the empty repository has no workspace**

Run: `dart pub workspace list`

Expected: FAIL because the repository has no root `pubspec.yaml`.

- [ ] **Step 2: Generate mechanical Flutter package shells**

Run:

```bash
flutter create --template=package --project-name=yl_player packages/yl_player
flutter create --template=package --project-name=yl_player_platform_interface packages/yl_player_platform_interface
flutter create --template=plugin --platforms=android --android-language=kotlin --org=dev.ylplayer packages/yl_player_android
flutter create --template=plugin --platforms=ios --ios-language=swift --org=dev.ylplayer packages/yl_player_ios
```

Expected: Four generated packages exist and each package can be recognized by Flutter tooling.

- [ ] **Step 3: Configure the Dart workspace and federated metadata**

Create the root workspace:

```yaml
name: yl_player_workspace
publish_to: none
environment:
  sdk: ^3.12.0
workspace:
  - packages/yl_player
  - packages/yl_player_platform_interface
  - packages/yl_player_android
  - packages/yl_player_android/example
  - packages/yl_player_ios
  - packages/yl_player_ios/example
```

Set every member to `version: 0.1.0-dev.1`, `resolution: workspace`, `sdk: ^3.12.0`, and `flutter: '>=3.44.0'`. Configure hosted inter-package constraints as `^0.1.0-dev.1`; do not use path dependencies.

The app-facing plugin endorses both implementations:

```yaml
flutter:
  plugin:
    platforms:
      android:
        default_package: yl_player_android
      ios:
        default_package: yl_player_ios
```

The Android and iOS packages declare `implements: yl_player`, their native `pluginClass`, and their Dart `dartPluginClass`.

- [ ] **Step 4: Resolve and list the workspace**

Run: `flutter pub get`

Expected: PASS with one root lockfile and package configuration.

Run: `dart pub workspace list`

Expected: PASS and list the root, all four publishable packages, and both private platform example apps.

- [ ] **Step 5: Commit the workspace skeleton**

```bash
git add .gitignore analysis_options.yaml pubspec.yaml pubspec.lock packages
git commit -m "build: scaffold yl_player federated workspace"
```

---

### Task 2: Cross-Platform Models and Errors

**Files:**
- Create: `packages/yl_player_platform_interface/lib/src/configuration.dart`
- Create: `packages/yl_player_platform_interface/lib/src/capabilities.dart`
- Create: `packages/yl_player_platform_interface/lib/src/media_source.dart`
- Create: `packages/yl_player_platform_interface/lib/src/media_track.dart`
- Create: `packages/yl_player_platform_interface/lib/src/playback_metrics.dart`
- Create: `packages/yl_player_platform_interface/lib/src/player_error.dart`
- Create: `packages/yl_player_platform_interface/lib/src/player_event.dart`
- Create: `packages/yl_player_platform_interface/lib/src/player_state.dart`
- Modify: `packages/yl_player_platform_interface/lib/yl_player_platform_interface.dart`
- Test: `packages/yl_player_platform_interface/test/models_test.dart`

**Interfaces:**
- Consumes: No project types.
- Produces: `YlPlayerConfiguration`, `YlNetworkPolicy`, `YlQualityConstraint`, `YlMediaSource`, `YlMediaTrack`, `YlPlayerCapabilities`, `YlPlaybackMetrics`, `YlPlayerError`, `YlPlayerEvent`, and `YlPlayerState`.

- [ ] **Step 1: Write failing value-object tests**

Cover these exact behaviors:

```dart
test('network source snapshots and freezes headers', () {
  final headers = <String, String>{'Referer': 'https://example.test'};
  final source = YlMediaSource.network(
    Uri.parse('https://media.test/live.m3u8'),
    isLive: true,
    formatHint: YlFormatHint.hls,
    headers: headers,
  );
  headers['Referer'] = 'changed';
  expect(source.headers['Referer'], 'https://example.test');
  expect(source.kind, YlMediaSourceKind.network);
});

test('player state copyWith preserves fields not supplied', () {
  const initial = YlPlayerState(
    status: YlPlaybackStatus.playing,
    position: Duration(seconds: 4),
    isLive: true,
  );
  final changed = initial.copyWith(position: const Duration(seconds: 5));
  expect(changed.status, YlPlaybackStatus.playing);
  expect(changed.position, const Duration(seconds: 5));
  expect(changed.isLive, isTrue);
});

test('player error keeps a stable category and code', () {
  const error = YlPlayerError(
    category: YlPlayerErrorCategory.decoderUnsupported,
    code: 'decoder.profile_unsupported',
    message: 'The selected stream is not supported.',
  );
  expect(error.category, YlPlayerErrorCategory.decoderUnsupported);
  expect(error.toString(), contains('decoder.profile_unsupported'));
});
```

- [ ] **Step 2: Run tests and verify the API is absent**

Run: `flutter test packages/yl_player_platform_interface/test/models_test.dart`

Expected: FAIL with missing type/import errors.

- [ ] **Step 3: Implement immutable public models**

Define the exact enums:

```dart
enum YlBufferMode { automatic, lowLatency, balanced, stable, custom }
enum YlDecoderPolicy { preferHardware, hardwareOnly }
enum YlMediaSourceKind { file, network, content }
enum YlFormatHint { automatic, hls, httpFlv, mp4, mov, matroska, webm, mpegTs, mpegPs, flv, avi }
enum YlTrackKind { audio, video }
enum YlPlaybackStatus { idle, opening, ready, playing, paused, buffering, completed, error, disposed }
enum YlPlayerErrorCategory { source, network, container, decoderUnsupported, decoderFailure, render, resource, cancelled, internal }
enum YlPlaybackEngine { unknown, media3, avPlayer, nativeFallback }
```

`YlMediaSource` has `Uri uri`, `YlMediaSourceKind kind`, `bool isLive`, `YlFormatHint formatHint`, and an unmodifiable `Map<String, String> headers`. It provides `file`, `content`, and `network` factories and rejects a non-HTTP(S) URI passed to `network`.

`YlPlayerConfiguration` contains buffer mode, decoder policy, `YlNetworkPolicy`, optional custom duration/byte buffer ceilings, and position-event interval. `YlNetworkPolicy` contains connect/read timeout, retry count, base/max backoff, and redirect limit. `YlQualityConstraint` contains optional maximum width, height, and bitrate.

`YlPlayerCapabilities` records available hardware video codecs, supported source hints, maximum concurrent video decoders, and optional maximum dimensions without claiming that a decoder will initialize. `YlPlaybackMetrics` records open/first-frame durations, rebuffer count/duration, dropped frames, audio underruns, bitrate, buffered duration/bytes, live offset, and reconnect count. Both are immutable snapshots and perform no collection or upload themselves.

`YlPlayerState` includes status, position, optional duration, buffered position, live flags/offset/DVR range, optional video size, selected engine, hardware-decode flag, decoder name, tracks, capabilities, metrics, and optional error. Implement `copyWith` with a private sentinel so optional values can be explicitly cleared.

Use sealed `YlPlayerEvent` subclasses for `YlFirstFrameEvent`, `YlRetryEvent`, `YlFallbackEvent`, `YlTracksChangedEvent`, and `YlErrorEvent`.

- [ ] **Step 4: Run model tests**

Run: `flutter test packages/yl_player_platform_interface/test/models_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit the model layer**

```bash
git add packages/yl_player_platform_interface
git commit -m "feat: define yl_player cross-platform models"
```

---

### Task 3: Platform and Player Contracts

**Files:**
- Create: `packages/yl_player_platform_interface/lib/src/player_platform.dart`
- Create: `packages/yl_player_platform_interface/lib/src/platform_player.dart`
- Modify: `packages/yl_player_platform_interface/lib/yl_player_platform_interface.dart`
- Modify: `packages/yl_player_platform_interface/pubspec.yaml`
- Test: `packages/yl_player_platform_interface/test/player_platform_test.dart`

**Interfaces:**
- Consumes: All Task 2 value types.
- Produces: `YlPlayerPlatform.instance`, `Future<YlPlatformPlayer> createPlayer(YlPlayerConfiguration)`, and the complete `YlPlatformPlayer` command/event contract.

- [ ] **Step 1: Write a failing singleton-verification test**

```dart
final class TestPlatform extends YlPlayerPlatform {
  TestPlatform() : super(token: _token);
  static final Object _token = Object();

  @override
  Future<YlPlatformPlayer> createPlayer(YlPlayerConfiguration configuration) {
    throw UnimplementedError();
  }
}

test('registered platform becomes the singleton instance', () {
  final platform = TestPlatform();
  YlPlayerPlatform.instance = platform;
  expect(YlPlayerPlatform.instance, same(platform));
});
```

Use the official `plugin_platform_interface` token pattern rather than the illustrative private token above in the final implementation.

- [ ] **Step 2: Run the contract test and verify failure**

Run: `flutter test packages/yl_player_platform_interface/test/player_platform_test.dart`

Expected: FAIL because `YlPlayerPlatform` and `YlPlatformPlayer` do not exist.

- [ ] **Step 3: Implement the contracts**

`YlPlatformPlayer` exposes:

```dart
ValueListenable<int?> get textureId;
YlPlayerState get state;
Stream<YlPlayerState> get states;
Stream<YlPlayerEvent> get events;
Future<void> open(YlMediaSource source);
Future<void> play();
Future<void> pause();
Future<void> seekTo(Duration position);
Future<void> seekToLiveEdge();
Future<void> setPlaybackSpeed(double speed);
Future<void> setVolume(double volume);
Future<void> selectAudioTrack(String trackId);
Future<void> setQualityConstraint(YlQualityConstraint constraint);
Future<void> dispose();
```

`YlPlayerPlatform` extends `PlatformInterface`, starts with a private unsupported implementation, verifies assigned instances, and defines `createPlayer`.

- [ ] **Step 4: Run all platform-interface tests**

Run: `flutter test packages/yl_player_platform_interface`

Expected: PASS.

- [ ] **Step 5: Commit the platform contract**

```bash
git add packages/yl_player_platform_interface
git commit -m "feat: add yl_player platform contracts"
```

---

### Task 4: Controller Lifecycle and State Mirroring

**Files:**
- Create: `packages/yl_player/lib/src/player_controller.dart`
- Modify: `packages/yl_player/lib/yl_player.dart`
- Create: `packages/yl_player/test/support/fake_player_platform.dart`
- Replace: `packages/yl_player/test/yl_player_test.dart` with `packages/yl_player/test/player_controller_test.dart`

**Interfaces:**
- Consumes: `YlPlayerPlatform.createPlayer` and `YlPlatformPlayer` from Task 3.
- Produces: `YlPlayerController`, with the command surface approved in the architecture spec.

- [ ] **Step 1: Write failing controller tests**

Test these concrete behaviors:

```dart
test('mirrors backend state and delegates commands', () async {
  final backend = FakePlatformPlayer();
  YlPlayerPlatform.instance = FakePlayerPlatform(backend);
  final controller = YlPlayerController();

  await controller.open(YlMediaSource.file('/video.mp4'));
  backend.emitState(const YlPlayerState(status: YlPlaybackStatus.ready));
  await pumpEventQueue();

  expect(controller.state.status, YlPlaybackStatus.ready);
  expect(backend.openedSource?.uri.path, '/video.mp4');
});

test('dispose is idempotent and rejects later commands', () async {
  final backend = FakePlatformPlayer();
  YlPlayerPlatform.instance = FakePlayerPlatform(backend);
  final controller = YlPlayerController();

  await controller.dispose();
  await controller.dispose();

  expect(backend.disposeCount, 1);
  expect(controller.play, throwsA(isA<StateError>()));
});
```

Also test forwarding for play, pause, seek, live edge, speed, volume, audio track, and quality constraint; backend errors must become `YlErrorEvent`/error state without closing the public streams.

- [ ] **Step 2: Verify controller tests fail**

Run: `flutter test packages/yl_player/test/player_controller_test.dart`

Expected: FAIL because the controller and fake backend are absent.

- [ ] **Step 3: Implement the minimal controller**

Construct the backend once through a private `Future<YlPlatformPlayer>`. Attach state/event/texture listeners exactly once, mirror the latest immutable state, forward commands, and make `dispose` share one completion future. Every public command checks the disposed flag before awaiting the backend.

Keep source-generation cancellation authoritative in native backends; the controller guarantees only that it does not emit values after its own disposal.

- [ ] **Step 4: Run controller tests**

Run: `flutter test packages/yl_player/test/player_controller_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit the controller**

```bash
git add packages/yl_player
git commit -m "feat: implement yl_player controller lifecycle"
```

---

### Task 5: Texture-Only Player View

**Files:**
- Create: `packages/yl_player/lib/src/player_view.dart`
- Modify: `packages/yl_player/lib/yl_player.dart`
- Create: `packages/yl_player/test/player_view_test.dart`

**Interfaces:**
- Consumes: `YlPlayerController.textureId`.
- Produces: `YlPlayerView({required YlPlayerController controller, Widget? placeholder, FilterQuality filterQuality})`.

- [ ] **Step 1: Write failing widget tests**

```dart
testWidgets('shows placeholder until a texture is available', (tester) async {
  final backend = FakePlatformPlayer();
  YlPlayerPlatform.instance = FakePlayerPlatform(backend);
  final controller = YlPlayerController();

  await tester.pumpWidget(MaterialApp(
    home: YlPlayerView(
      controller: controller,
      placeholder: const Text('waiting'),
    ),
  ));
  expect(find.text('waiting'), findsOneWidget);

  backend.setTextureId(42);
  await tester.pump();
  expect(find.byType(Texture), findsOneWidget);
});
```

Also verify that changing the controller detaches the old texture listener and that disposal leaves no pending callbacks.

- [ ] **Step 2: Verify widget tests fail**

Run: `flutter test packages/yl_player/test/player_view_test.dart`

Expected: FAIL because `YlPlayerView` is absent.

- [ ] **Step 3: Implement the texture widget**

Use `ValueListenableBuilder<int?>` over the controller's texture ID. Render the supplied placeholder or `SizedBox.shrink()` for `null`; otherwise render Flutter's `Texture` with the selected `FilterQuality`. Do not add controls, gestures, aspect-ratio policy, or platform views.

- [ ] **Step 4: Run all app-facing package tests**

Run: `flutter test packages/yl_player`

Expected: PASS.

- [ ] **Step 5: Commit the view**

```bash
git add packages/yl_player
git commit -m "feat: add texture-only yl_player view"
```

---

### Task 6: Endorsed Android Registration Shell

**Files:**
- Modify: `packages/yl_player_android/lib/yl_player_android.dart`
- Create: `packages/yl_player_android/lib/src/unsupported_android_player.dart`
- Modify: `packages/yl_player_android/android/build.gradle.kts`
- Modify: `packages/yl_player_android/android/src/main/AndroidManifest.xml`
- Modify: `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/android/YlPlayerAndroidPlugin.kt`
- Replace: generated test with `packages/yl_player_android/test/yl_player_android_test.dart`

**Interfaces:**
- Consumes: `YlPlayerPlatform` and `YlPlatformPlayer`.
- Produces: `YlPlayerAndroid.registerWith()` and a clearly unsupported placeholder backend.

- [ ] **Step 1: Write the failing registration test**

```dart
test('registerWith installs the Android implementation', () {
  YlPlayerAndroid.registerWith();
  expect(YlPlayerPlatform.instance, isA<YlPlayerAndroid>());
});
```

- [ ] **Step 2: Verify the test fails**

Run: `flutter test packages/yl_player_android/test/yl_player_android_test.dart`

Expected: FAIL because the class does not implement the shared platform contract.

- [ ] **Step 3: Implement registration and the native shell**

`YlPlayerAndroid.createPlayer` returns a placeholder `YlPlatformPlayer` whose initial state is `idle` and whose playback commands complete with `YlPlayerError(category: internal, code: 'android.not_implemented', ...)`. It must still support idempotent disposal and closed streams. This prevents a scaffold from pretending playback works.

Set `minSdk = 24`. The Kotlin plugin stores no global state and only implements Flutter plugin attach/detach lifecycle; Media3 is not introduced until the Android plan.

- [ ] **Step 4: Run Dart and Android compile checks**

Run: `flutter test packages/yl_player_android`

Expected: PASS.

Run from the generated Android package example: `flutter build apk --debug`

Expected: PASS with API 24 as the minimum SDK.

- [ ] **Step 5: Commit the Android shell**

```bash
git add packages/yl_player_android
git commit -m "feat: register yl_player Android platform shell"
```

---

### Task 7: Endorsed iOS Registration Shell

**Files:**
- Modify: `packages/yl_player_ios/lib/yl_player_ios.dart`
- Create: `packages/yl_player_ios/lib/src/unsupported_ios_player.dart`
- Modify: `packages/yl_player_ios/ios/yl_player_ios.podspec`
- Modify: `packages/yl_player_ios/ios/yl_player_ios/Sources/yl_player_ios/YlPlayerIosPlugin.swift`
- Replace: generated test with `packages/yl_player_ios/test/yl_player_ios_test.dart`

**Interfaces:**
- Consumes: `YlPlayerPlatform` and `YlPlatformPlayer`.
- Produces: `YlPlayerIos.registerWith()` and a clearly unsupported placeholder backend.

- [ ] **Step 1: Write the failing registration test**

```dart
test('registerWith installs the iOS implementation', () {
  YlPlayerIos.registerWith();
  expect(YlPlayerPlatform.instance, isA<YlPlayerIos>());
});
```

- [ ] **Step 2: Verify the test fails**

Run: `flutter test packages/yl_player_ios/test/yl_player_ios_test.dart`

Expected: FAIL because the class does not implement the shared platform contract.

- [ ] **Step 3: Implement registration and the native shell**

Mirror the Android placeholder behavior with error code `ios.not_implemented`. Set the podspec deployment target to `15.0`. The Swift plugin stores no global state and implements registration only; AVPlayer is introduced in the iOS main-path plan.

- [ ] **Step 4: Run Dart and iOS compile checks**

Run: `flutter test packages/yl_player_ios`

Expected: PASS.

Run from the generated iOS package example: `flutter build ios --simulator --no-codesign`

Expected: PASS with iOS 15 as the deployment target.

- [ ] **Step 5: Commit the iOS shell**

```bash
git add packages/yl_player_ios
git commit -m "feat: register yl_player iOS platform shell"
```

---

### Task 8: Example, Documentation, and Foundation Gate

**Files:**
- Create: `packages/yl_player/example/lib/main.dart`
- Modify: `packages/yl_player/README.md`
- Modify: `packages/yl_player/CHANGELOG.md`
- Modify: `packages/yl_player_platform_interface/README.md`
- Modify: `packages/yl_player_android/README.md`
- Modify: `packages/yl_player_ios/README.md`
- Create: `tool/check_foundation.sh`

**Interfaces:**
- Consumes: Public controller/view API and all four packages.
- Produces: A runnable API example, honest milestone documentation, and one repeatable verification entry point.

- [ ] **Step 1: Add a compile-time example test target**

The example creates one controller, displays `YlPlayerView`, shows the current status as text, opens a user-entered resolved URL with optional headers, and disposes the controller. Its copy must explicitly say native playback backends are not present in milestone 1.

- [ ] **Step 2: Document exact supported and unsupported behavior**

The main README links the design spec, shows the approved API, lists Android 7/iOS 15, and labels playback as unavailable until the respective backend milestone. Platform READMEs describe registration only. No README claims broad format playback at this stage.

- [ ] **Step 3: Add the repeatable foundation check**

`tool/check_foundation.sh` runs, in order:

```bash
flutter pub get
flutter analyze
flutter test packages/yl_player_platform_interface
flutter test packages/yl_player
flutter test packages/yl_player_android
flutter test packages/yl_player_ios
dart format --output=none --set-exit-if-changed packages
```

- [ ] **Step 4: Run the complete gate**

Run: `sh tool/check_foundation.sh`

Expected: every command exits zero with no analyzer errors or formatting changes.

- [ ] **Step 5: Check publication payloads without publishing**

Run once per package:

```bash
dart pub -C packages/yl_player_platform_interface publish --dry-run
dart pub -C packages/yl_player_android publish --dry-run
dart pub -C packages/yl_player_ios publish --dry-run
dart pub -C packages/yl_player publish --dry-run
```

Expected: package contents are enumerated. Dependency-availability warnings for unpublished `0.1.0-dev.1` sibling packages are recorded as expected until the first coordinated release; no secret, missing-license, or oversized-package error is permitted.

- [ ] **Step 6: Commit the completed foundation**

```bash
git add packages tool pubspec.yaml pubspec.lock analysis_options.yaml .gitignore
git commit -m "docs: complete yl_player foundation milestone"
```

---

## Completion Boundary

This plan completes only Milestone 1 from the architecture specification. Its definition of done is a tested, compile-safe, documented federated public API with honest unsupported native shells. Functional Android playback begins in a separate Media3 plan; functional iOS playback begins in a separate AVPlayer plan; FFmpeg fallback begins only after both main paths are stable.
