import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart'
    show
        YlPlatformLoadResult,
        YlPlatformNativeVideoSurfaceProvider,
        YlPlatformProtectedVideoSurfaceProvider;

import 'support/fake_player_platform.dart';

const _s1 = YlPlaybackSessionId('s1');
const _s2 = YlPlaybackSessionId('s2');
const _wideGeometry = YlVideoGeometry(
  encodedSize: YlPixelSize(1920, 1080),
  displaySize: YlPixelSize(1920, 1080),
);
final _source = YlNetworkSource(Uri.parse('https://example.test/video.mp4'));

void main() {
  final nativeCalls = <MethodCall>[];
  setUp(() {
    nativeCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
          nativeCalls.add(call);
          return null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
  });

  testWidgets(
    'protected Android mounts explicit hybrid before first frame without texture or opacity',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final backend = _ProtectedPlatformPlayer();
      final controller = await _createCommittedController(
        backend,
        sessionId: _s1,
        geometry: _wideGeometry,
      );
      await _pumpView(tester, YlPlayerView(controller: controller));
      await tester.pump();
      expect(find.byType(AndroidViewSurface), findsOneWidget);
      expect(find.byType(Texture), findsNothing);
      expect(find.byType(Opacity), findsNothing);
      final create = nativeCalls.singleWhere((call) => call.method == 'create');
      final args = create.arguments as Map;
      expect(args['hybrid'], isTrue);
      expect(args['viewType'], 'yl_player_android/protected_video');
      expect(
        const StandardMessageCodec().decodeMessage(
          ByteData.sublistView(args['params']),
        ),
        {'playerId': 1, 'surfaceId': 2, 'sessionId': 's1', 'generation': 3},
      );
      expect(backend.attached, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(backend.detached, 1);
      await tester.runAsync(controller.dispose);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    testWidgets('protected Apple view mounts before first frame on $platform', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      final backend = _ProtectedPlatformPlayer(platform: platform);
      final controller = await _createCommittedController(
        backend,
        sessionId: _s1,
        geometry: _wideGeometry,
      );
      await _pumpView(tester, YlPlayerView(controller: controller));
      await tester.pump();
      expect(
        find.byType(platform == TargetPlatform.iOS ? UiKitView : AppKitView),
        findsOneWidget,
      );
      expect(find.byType(Texture), findsNothing);
      expect(find.byType(Opacity), findsNothing);
      final args =
          nativeCalls.singleWhere((call) => call.method == 'create').arguments
              as Map;
      expect(args['viewType'], 'yl_player_apple/protected_video');
      expect(
        const StandardMessageCodec().decodeMessage(
          ByteData.sublistView(args['params']),
        ),
        {'playerId': 1, 'surfaceId': 2, 'sessionId': 's1', 'generation': 3},
      );
      expect(backend.attached, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(backend.detached, 1);
      await tester.runAsync(controller.dispose);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    final nativeWidgetType = platform == TargetPlatform.iOS
        ? UiKitView
        : AppKitView;
    testWidgets(
      'negotiated native view mounts before current FirstFrame and retains identity on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final backend = _NativePlatformPlayer(platform: platform);
        final controller = await _createCommittedController(
          backend,
          sessionId: _s2,
          geometry: _wideGeometry,
        );
        await _pumpView(
          tester,
          YlPlayerView(
            controller: controller,
            placeholder: const Text('waiting'),
          ),
        );
        await tester.pump();
        expect(find.byType(nativeWidgetType), findsOneWidget);
        expect(find.byType(Texture), findsNothing);
        expect(find.text('waiting'), findsOneWidget);
        expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0);
        final create = nativeCalls.singleWhere(
          (call) => call.method == 'create',
        );
        final arguments = create.arguments as Map;
        expect(arguments['viewType'], 'yl_player_apple/video');
        expect(
          const StandardMessageCodec().decodeMessage(
            ByteData.sublistView(arguments['params']),
          ),
          {'textureId': 42},
        );

        backend.emitFirstFrame(_s1);
        await tester.pump();
        expect(find.text('waiting'), findsOneWidget);
        backend.emitFirstFrame(_s2);
        await tester.pump();
        expect(find.text('waiting'), findsNothing);
        expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1);
        _expectRect(
          tester.getRect(find.byType(nativeWidgetType)),
          left: 0,
          top: 65.625,
          width: 300,
          height: 168.75,
        );
        expect(
          nativeCalls.where((call) => call.method == 'create'),
          hasLength(1),
        );

        _publishSession(backend, sessionId: _s1, geometry: _wideGeometry);
        await tester.pump();
        expect(find.text('waiting'), findsOneWidget);
        expect(
          nativeCalls.where((call) => call.method == 'create'),
          hasLength(1),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(backend.disposeCount, 0);
        expect(
          nativeCalls.where((call) => call.method == 'dispose'),
          hasLength(1),
        );
        await tester.runAsync(controller.dispose);
        expect(backend.disposeCount, 1);
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      'native surface applies pixel aspect ratio rotation cover and alignment on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final backend = _NativePlatformPlayer(platform: platform);
        const geometry = YlVideoGeometry(
          encodedSize: YlPixelSize(720, 576),
          displaySize: YlPixelSize(720, 576),
          pixelAspectRatio: 16 / 15,
          rotationDegrees: 90,
        );
        final controller = await _presentedController(
          backend,
          geometry: geometry,
        );
        await _pumpView(
          tester,
          YlPlayerView(
            controller: controller,
            fit: BoxFit.cover,
            alignment: Alignment.topLeft,
          ),
        );
        await tester.pump();
        _expectRect(
          tester.getRect(find.byType(nativeWidgetType)),
          left: 0,
          top: 0,
          width: 300,
          height: 400,
        );
        expect(
          tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns,
          1,
        );
        expect(
          tester.widget<FittedBox>(find.byType(FittedBox)).alignment,
          Alignment.topLeft,
        );
        await _dispose(tester, controller);
      },
    );

    testWidgets(
      'disposed native output unmounts the surface and restores placeholder on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final backend = _NativePlatformPlayer(platform: platform);
        final controller = await _presentedController(
          backend,
          geometry: _wideGeometry,
        );
        await _pumpView(
          tester,
          YlPlayerView(
            controller: controller,
            placeholder: const Text('waiting'),
          ),
        );
        await tester.pump();
        expect(find.byType(nativeWidgetType), findsOneWidget);
        await tester.runAsync(controller.dispose);
        await tester.pump();
        expect(find.byType(nativeWidgetType), findsNothing);
        expect(find.text('waiting'), findsOneWidget);
        expect(backend.disposeCount, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      'native output requires authoritative geometry even after FirstFrame on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final backend = _NativePlatformPlayer(platform: platform);
        final controller = await _createCommittedController(
          backend,
          sessionId: _s1,
        );
        backend.emitFirstFrame(_s1);
        await _pumpView(
          tester,
          YlPlayerView(
            controller: controller,
            placeholder: const Text('waiting'),
          ),
        );
        expect(find.byType(nativeWidgetType), findsNothing);
        expect(find.text('waiting'), findsOneWidget);
        _publishGeometry(backend, _wideGeometry);
        await tester.pump();
        await tester.pump();
        expect(find.byType(nativeWidgetType), findsOneWidget);
        expect(find.text('waiting'), findsNothing);
        await _dispose(tester, controller);
      },
    );
  }

  for (final hasCapability in [false, true]) {
    testWidgets(
      'macOS retains Texture without a matching advertisement: capability=$hasCapability',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        final backend = hasCapability
            ? _NativePlatformPlayer()
            : FakePlatformPlayer();
        final controller = await _presentedController(
          backend,
          geometry: _wideGeometry,
        );
        await _pumpView(
          tester,
          YlPlayerView(
            controller: controller,
            filterQuality: FilterQuality.high,
          ),
        );
        expect(find.byType(UiKitView), findsNothing);
        expect(find.byType(AppKitView), findsNothing);
        expect(tester.widget<Texture>(find.byType(Texture)).textureId, 42);
        expect(
          tester.widget<Texture>(find.byType(Texture)).filterQuality,
          FilterQuality.high,
        );
        await _dispose(tester, controller);
      },
    );
  }

  testWidgets('keeps placeholder until current session first frame', (
    tester,
  ) async {
    final backend = FakePlatformPlayer();
    final controller = await _createCommittedController(
      backend,
      sessionId: _s2,
      geometry: _wideGeometry,
    );

    await _pumpView(
      tester,
      YlPlayerView(controller: controller, placeholder: const Text('waiting')),
    );
    expect(find.text('waiting'), findsOneWidget);
    expect(find.byType(Texture), findsNothing);

    backend.emitFirstFrame(_s1);
    backend.setTextureId(99);
    await tester.pump();
    expect(find.text('waiting'), findsOneWidget);
    expect(find.byType(Texture), findsNothing);

    backend.emitFirstFrame(_s2);
    await tester.pump();
    expect(find.text('waiting'), findsNothing);
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 99);

    await _dispose(tester, controller);
  });

  testWidgets(
    'uses first frame received before load completion and view mount',
    (tester) async {
      final backend = FakePlatformPlayer();
      final controller = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
      );
      final loading = controller.load(_source);
      _publishSession(backend, sessionId: _s1, geometry: _wideGeometry);
      backend.emitFirstFrame(_s1);

      expect(controller.isCurrentFramePresented, isTrue);
      backend.loads.single.complete(const YlPlatformLoadResult(sessionId: _s1));
      await loading;
      await _pumpView(tester, YlPlayerView(controller: controller));
      expect(find.byType(Texture), findsOneWidget);

      await _dispose(tester, controller);
    },
  );

  testWidgets('replacement hides old frame until replacement first frame', (
    tester,
  ) async {
    final backend = FakePlatformPlayer();
    final controller = await _createCommittedController(
      backend,
      sessionId: _s1,
      geometry: _wideGeometry,
    );
    backend.emitFirstFrame(_s1);
    await _pumpView(
      tester,
      YlPlayerView(
        controller: controller,
        placeholder: const Text('replacement waiting'),
      ),
    );
    expect(find.byType(Texture), findsOneWidget);

    _publishSession(backend, sessionId: _s2, geometry: _wideGeometry);
    await tester.pump();
    expect(find.text('replacement waiting'), findsOneWidget);
    expect(find.byType(Texture), findsNothing);

    backend.emitFirstFrame(_s1);
    await tester.pump();
    expect(find.byType(Texture), findsNothing);
    backend.emitFirstFrame(_s2);
    await tester.pump();
    expect(find.byType(Texture), findsOneWidget);

    await _dispose(tester, controller);
  });

  testWidgets('contain uses authoritative display geometry and default bars', (
    tester,
  ) async {
    final backend = FakePlatformPlayer();
    final controller = await _presentedController(
      backend,
      geometry: _wideGeometry,
    );
    await _pumpView(tester, YlPlayerView(controller: controller));

    _expectRect(
      tester.getRect(find.byType(Texture)),
      left: 0,
      top: 65.625,
      width: 300,
      height: 168.75,
    );
    expect(
      tester.widget<ColoredBox>(find.byType(ColoredBox)).color,
      const Color(0xFF000000),
    );
    final fitted = tester.widget<FittedBox>(find.byType(FittedBox));
    expect(fitted.fit, BoxFit.contain);
    expect(fitted.alignment, Alignment.center);
    expect(
      tester.widget<Texture>(find.byType(Texture)).filterQuality,
      FilterQuality.low,
    );

    await _dispose(tester, controller);
  });

  testWidgets('applies pixel aspect ratio exactly once before rotation', (
    tester,
  ) async {
    const geometry = YlVideoGeometry(
      encodedSize: YlPixelSize(720, 576),
      displaySize: YlPixelSize(720, 576),
      pixelAspectRatio: 16 / 15,
    );
    final backend = FakePlatformPlayer();
    final controller = await _presentedController(backend, geometry: geometry);
    await _pumpView(tester, YlPlayerView(controller: controller));

    _expectRect(
      tester.getRect(find.byType(Texture)),
      left: 0,
      top: 37.5,
      width: 300,
      height: 225,
    );

    _publishGeometry(backend, geometry.copyWith(rotationDegrees: 90));
    await tester.pump();
    _expectRect(
      tester.getRect(find.byType(Texture)),
      left: 37.5,
      top: 0,
      width: 225,
      height: 300,
    );
    expect(tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 1);

    await _dispose(tester, controller);
  });

  testWidgets('cover crops and top-left alignment controls placement', (
    tester,
  ) async {
    final backend = FakePlatformPlayer();
    final controller = await _presentedController(
      backend,
      geometry: _wideGeometry,
    );
    await _pumpView(
      tester,
      YlPlayerView(controller: controller, fit: BoxFit.cover),
    );
    _expectRect(
      tester.getRect(find.byType(Texture)),
      left: -116.6666667,
      top: 0,
      width: 533.3333333,
      height: 300,
    );

    await _pumpView(
      tester,
      YlPlayerView(
        controller: controller,
        fit: BoxFit.cover,
        alignment: Alignment.topLeft,
      ),
    );
    _expectRect(
      tester.getRect(find.byType(Texture)),
      left: 0,
      top: 0,
      width: 533.3333333,
      height: 300,
    );

    await _dispose(tester, controller);
  });

  testWidgets('forwards background and texture filter quality', (tester) async {
    final backend = FakePlatformPlayer();
    final controller = await _presentedController(
      backend,
      geometry: _wideGeometry,
    );
    await _pumpView(
      tester,
      YlPlayerView(
        controller: controller,
        backgroundColor: const Color(0xFF123456),
        filterQuality: FilterQuality.high,
      ),
    );

    expect(
      tester.widget<ColoredBox>(find.byType(ColoredBox)).color,
      const Color(0xFF123456),
    );
    expect(
      tester.widget<Texture>(find.byType(Texture)).filterQuality,
      FilterQuality.high,
    );

    await _dispose(tester, controller);
  });

  testWidgets('missing geometry keeps placeholder after first frame signal', (
    tester,
  ) async {
    final backend = FakePlatformPlayer();
    final controller = await _createCommittedController(
      backend,
      sessionId: _s1,
    );
    backend.emitFirstFrame(_s1);
    await _pumpView(
      tester,
      YlPlayerView(
        controller: controller,
        placeholder: const Text('no geometry'),
      ),
    );

    expect(controller.isCurrentFramePresented, isTrue);
    expect(find.text('no geometry'), findsOneWidget);
    expect(find.byType(Texture), findsNothing);

    await _dispose(tester, controller);
  });

  testWidgets('contains rendering only and no interactive or platform views', (
    tester,
  ) async {
    final backend = FakePlatformPlayer();
    final controller = await _presentedController(
      backend,
      geometry: _wideGeometry,
    );
    await _pumpView(tester, YlPlayerView(controller: controller));

    expect(find.byType(GestureDetector), findsNothing);
    expect(find.byType(Listener), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is AndroidView ||
            widget is UiKitView ||
            widget is AppKitView ||
            widget is PlatformViewLink,
      ),
      findsNothing,
    );

    await _dispose(tester, controller);
  });
}

Future<YlPlayerController> _createCommittedController(
  FakePlatformPlayer backend, {
  required YlPlaybackSessionId sessionId,
  YlVideoGeometry? geometry,
}) async {
  final controller = await YlPlayerController.create(
    platform: FakePlayerPlatform(backend),
  );
  final loading = controller.load(_source);
  _publishSession(backend, sessionId: sessionId, geometry: geometry);
  backend.loads.single.complete(YlPlatformLoadResult(sessionId: sessionId));
  await loading;
  return controller;
}

Future<YlPlayerController> _presentedController(
  FakePlatformPlayer backend, {
  required YlVideoGeometry geometry,
}) async {
  final controller = await _createCommittedController(
    backend,
    sessionId: _s1,
    geometry: geometry,
  );
  backend.emitFirstFrame(_s1);
  return controller;
}

void _publishSession(
  FakePlatformPlayer backend, {
  required YlPlaybackSessionId sessionId,
  YlVideoGeometry? geometry,
}) {
  backend.emitState(
    YlPlayerState(
      revision: backend.state.revision + 1,
      sessionId: sessionId,
      status: YlPlaybackStatus.loading,
      videoGeometry: geometry,
    ),
  );
}

void _publishGeometry(FakePlatformPlayer backend, YlVideoGeometry geometry) {
  backend.emitState(
    backend.state.copyWith(
      revision: backend.state.revision + 1,
      videoGeometry: geometry,
    ),
  );
}

Future<void> _pumpView(WidgetTester tester, YlPlayerView view) =>
    tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 300, height: 300, child: view),
        ),
      ),
    );

void _expectRect(
  Rect actual, {
  required double left,
  required double top,
  required double width,
  required double height,
}) {
  expect(actual.left, moreOrLessEquals(left, epsilon: 0.001));
  expect(actual.top, moreOrLessEquals(top, epsilon: 0.001));
  expect(actual.width, moreOrLessEquals(width, epsilon: 0.001));
  expect(actual.height, moreOrLessEquals(height, epsilon: 0.001));
}

Future<void> _dispose(
  WidgetTester tester,
  YlPlayerController controller,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(controller.dispose);
  debugDefaultTargetPlatformOverride = null;
}

final class _NativePlatformPlayer extends FakePlatformPlayer
    implements YlPlatformNativeVideoSurfaceProvider {
  _NativePlatformPlayer({this.platform = TargetPlatform.iOS});
  final TargetPlatform platform;
  @override
  YlNativeVideoSurface? get nativeVideoSurface => YlNativeVideoSurface(
    viewType: 'yl_player_apple/video',
    platform: platform,
  );
}

final class _ProtectedPlatformPlayer extends FakePlatformPlayer
    implements YlPlatformProtectedVideoSurfaceProvider {
  _ProtectedPlatformPlayer({this.platform = TargetPlatform.android});
  final TargetPlatform platform;
  int attached = 0, detached = 0;
  @override
  YlProtectedVideoSurface? get protectedVideoSurface => YlProtectedVideoSurface(
    playerId: 1,
    surfaceId: 2,
    sessionId: 's1',
    generation: 3,
    viewType: platform == TargetPlatform.android
        ? 'yl_player_android/protected_video'
        : 'yl_player_apple/protected_video',
    platform: platform,
  );
  @override
  Future<void> attachProtectedView(
    YlProtectedVideoSurface surface,
    int viewId,
  ) async {
    attached++;
  }

  @override
  Future<void> detachProtectedView(
    YlProtectedVideoSurface surface,
    int viewId,
  ) async {
    detached++;
  }
}
