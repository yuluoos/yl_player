import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart'
    show YlPlatformLoadResult;

import 'support/fake_player_platform.dart';

const _s1 = YlPlaybackSessionId('s1');
const _s2 = YlPlaybackSessionId('s2');
const _wideGeometry = YlVideoGeometry(
  encodedSize: YlPixelSize(1920, 1080),
  displaySize: YlPixelSize(1920, 1080),
);
final _source = YlNetworkSource(Uri.parse('https://example.test/video.mp4'));

void main() {
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
}
