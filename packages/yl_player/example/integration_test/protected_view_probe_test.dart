import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const channel = MethodChannel('yl_player_example/protected_probe');
const viewType = 'yl_player_example/protected_probe_view';
Widget nativeView(int id) {
  final args = <String, Object>{'id': id};
  if (Platform.isMacOS) {
    return AppKitView(
      viewType: viewType,
      creationParams: args,
      creationParamsCodec: const StandardMessageCodec(),
    );
  }
  if (Platform.isIOS) {
    return UiKitView(
      viewType: viewType,
      creationParams: args,
      creationParamsCodec: const StandardMessageCodec(),
    );
  }
  return PlatformViewLink(
    viewType: viewType,
    surfaceFactory: (context, controller) => AndroidViewSurface(
      controller: controller as AndroidViewController,
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
    ),
    onCreatePlatformView: (params) =>
        PlatformViewsService.initExpensiveAndroidView(
            id: params.id,
            viewType: viewType,
            layoutDirection: TextDirection.ltr,
            creationParams: args,
            creationParamsCodec: const StandardMessageCodec(),
            onFocus: () => params.onFocusChanged(true),
          )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create(),
  );
}

Future<Map<Object?, Object?>> snapshot(int id) async =>
    (await channel.invokeMapMethod<Object?, Object?>('snapshot', {'id': id}))!;
Future<Map<Object?, Object?>> waitFor(
  WidgetTester tester,
  int id,
  bool Function(Map<Object?, Object?>) predicate,
) async {
  final end = DateTime.now().add(const Duration(seconds: 15));
  var state = <Object?, Object?>{};
  do {
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    state = await snapshot(id);
    if (predicate(state)) return state;
  } while (DateTime.now().isBefore(end));
  fail('Prototype did not converge: $state');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'clear native prototype isolates players, resize, replacement and release',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp('yl-clear-view-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/clear.mp4');
      final sink = file.openWrite();
      for (final name in [
        'init-0.m4s',
        for (var i = 1; i <= 4; i++)
          'chunk-0-${i.toString().padLeft(5, '0')}.m4s',
      ]) {
        final data = await rootBundle.load(
          'assets/test_media/dash_timeline/period0/$name',
        );
        sink.add(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      }
      await sink.close();
      // Clear AVC bytes: a secure view request is not proof of DRM security.
      for (final id in [71, 72]) {
        await channel.invokeMethod<void>('create', {
          'id': id,
          'path': file.path,
        });
      }
      addTearDown(() async {
        await channel.invokeMethod<void>('reset');
      });
      Widget layout(double width, double height) => MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(
                key: const ValueKey('one'),
                width: width,
                height: height,
                child: nativeView(71),
              ),
              SizedBox(
                key: const ValueKey('two'),
                width: 160,
                height: 90,
                child: nativeView(72),
              ),
              const Text('Subtitle placement reference'),
            ],
          ),
        ),
      );
      await tester.pumpWidget(layout(240, 135));
      final one = await waitFor(
        tester,
        71,
        (s) => s['readyEpoch'] == 1 && (s['positionMs'] as num) > 100,
      );
      final two = await waitFor(tester, 72, (s) => s['readyEpoch'] == 1);
      expect(one['id'], 71);
      expect(two['id'], 72);
      expect(one['pixelReadback'], false);
      expect(one['protectionVerified'], false);
      expect(one['width'], closeTo(240, 1));
      expect(one['height'], closeTo(135, 1));
      if (Platform.isAndroid) expect(one['secureRequested'], true);
      await tester.pumpWidget(layout(180, 220));
      await waitFor(
        tester,
        71,
        (s) =>
            ((s['width'] as num) - 180).abs() <= 1 &&
            ((s['height'] as num) - 220).abs() <= 1,
      );
      await channel.invokeMethod<void>('replace', {
        'id': 71,
        'path': file.path,
      });
      final replaced = await waitFor(
        tester,
        71,
        (s) => s['readyEpoch'] == 2 && (s['positionMs'] as num) > 100,
      );
      expect(replaced['epoch'], 2);
      expect((await snapshot(72))['epoch'], 1);
      await channel.invokeMethod<void>('dispose', {'id': 71});
      await expectLater(
        snapshot(71),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'probe.missing',
          ),
        ),
      );
      expect((await snapshot(72))['readyEpoch'], 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      await channel.invokeMethod<void>('reset');
      expect(await channel.invokeMethod<int>('count'), 0);
    },
  );
}
