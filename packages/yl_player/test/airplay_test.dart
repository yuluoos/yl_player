import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'support/fake_player_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
  });
  final source = YlNetworkSource(
    Uri.parse('https://fixture.invalid/video.mp4'),
  );
  const options = YlLoadOptions(airPlay: true);

  test('AirPlay is opt-in and part of load option value identity', () {
    expect(const YlLoadOptions().airPlay, isFalse);
    expect(options, isNot(const YlLoadOptions()));
    expect(options, const YlLoadOptions(airPlay: true));
    expect(options.toString(), contains('airPlay: true'));
  });

  test('unsupported AirPlay preserves the pending ordinary load', () async {
    final backend = FakePlatformPlayer();
    final controller = await YlPlayerController.create(
      platform: FakePlayerPlatform(backend),
    );
    final ordinary = controller.load(source);
    final unsupported = throwsA(
      isA<YlPlayerException>().having(
        (e) => e.failure.code,
        'code',
        YlFailureCodes.policyUnsupported,
      ),
    );
    await expectLater(controller.assess(source, options: options), unsupported);
    await expectLater(controller.load(source, options: options), unsupported);
    expect(backend.loads, hasLength(1));
    backend.commit(const YlPlaybackSessionId('ordinary'));
    expect((await ordinary).id, const YlPlaybackSessionId('ordinary'));
    expect(controller.airPlayState.value.supported, isFalse);
    await controller.dispose();
  });

  test(
    'AirPlay calls optional SPI and ordinary calls remain unchanged',
    () async {
      final backend = _AirPlayFake();
      final controller = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
      );
      await controller.assess(source, options: options);
      expect(backend.airPlayAssessments, 1);
      final loading = controller.load(source, options: options);
      backend.commit(const YlPlaybackSessionId('airplay'));
      await loading;
      expect(backend.airPlayLoads, 1);
      await controller.assess(source);
      final ordinary = controller.load(source);
      backend.commit(const YlPlaybackSessionId('ordinary'));
      await ordinary;
      expect(backend.airPlayLoads, 1);
      expect(backend.airPlayAssessments, 1);
      await controller.dispose();
    },
  );

  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    testWidgets('system picker mounts only for admitted session on $platform', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform_views, (
            call,
          ) async {
            calls.add(call);
            return null;
          });
      final backend = _AirPlayFake(platform: platform);
      final controller = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
      );
      final loading = controller.load(source, options: options);
      backend.commit(const YlPlaybackSessionId('one'));
      await loading;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: YlAirPlayButton(
            controller: controller,
            fallback: const Text('unavailable'),
          ),
        ),
      );
      expect(find.text('unavailable'), findsOneWidget);
      backend.airPlayState.value = const YlAirPlayState(
        supported: true,
        enabled: true,
        sessionId: YlPlaybackSessionId('one'),
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.byType(platform == TargetPlatform.iOS ? UiKitView : AppKitView),
        findsOneWidget,
      );
      final args =
          calls.singleWhere((call) => call.method == 'create').arguments as Map;
      expect(args['viewType'], 'yl_player_apple/airplay');
      expect(
        const StandardMessageCodec().decodeMessage(
          ByteData.sublistView(args['params']),
        ),
        {'channelSuffix': 'fake'},
      );
      expect(controller.isCurrentFramePresented, isFalse);
      await tester.runAsync(controller.stop);
      await tester.pump();
      expect(find.byType(UiKitView), findsNothing);
      expect(find.byType(AppKitView), findsNothing);
      expect(find.text('unavailable'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(controller.dispose);
      expect(backend.airPlayState.observed, isFalse);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets(
    'AirPlay button gates native picker on enabled and host platform',
    (tester) async {
      final backend = _AirPlayFake();
      final controller = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: YlAirPlayButton(
            controller: controller,
            fallback: const Text('unavailable'),
          ),
        ),
      );
      expect(find.text('unavailable'), findsOneWidget);
      expect(find.byType(UiKitView), findsNothing);
      backend.airPlayState.value = const YlAirPlayState(
        supported: true,
        enabled: true,
        active: false,
        sessionId: YlPlaybackSessionId('one'),
      );
      await tester.pump();
      backend.emit(sessionId: const YlPlaybackSessionId('one'));
      await tester.pump();
      expect(controller.airPlayState.value.enabled, isTrue);
      // Test host is Android: never mount an Apple factory on another platform.
      expect(find.byType(UiKitView), findsNothing);
      expect(find.byType(AppKitView), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(controller.dispose);
    },
  );
}

class _AirPlayFake extends FakePlatformPlayer
    implements YlAirPlayPlatformPlayer {
  _AirPlayFake({TargetPlatform platform = TargetPlatform.iOS})
    : airPlayRoutePickerSurface = YlAirPlayRoutePickerSurface(
        platform: platform,
        channelSuffix: 'fake',
      );
  @override
  final _RouteNotifier airPlayState = _RouteNotifier(
    const YlAirPlayState(supported: true),
  );
  @override
  final YlAirPlayRoutePickerSurface airPlayRoutePickerSurface;
  int airPlayLoads = 0;
  int airPlayAssessments = 0;
  @override
  Future<YlSourceAssessment> assessForAirPlay(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) {
    airPlayAssessments++;
    return super.assess(source, options: options);
  }

  @override
  Future<YlPlatformLoadResult> loadForAirPlay(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) {
    airPlayLoads++;
    return super.load(source, options: options);
  }
}

class _RouteNotifier extends ValueNotifier<YlAirPlayState> {
  _RouteNotifier(super.value);
  bool get observed => hasListeners;
}
