import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_android/yl_player_android.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('yl_player_android_test/methods');
  late StreamController<Object?> nativeEvents;
  late List<MethodCall> calls;
  late bool failDispose;

  setUp(() {
    nativeEvents = StreamController<Object?>.broadcast(sync: true);
    calls = <MethodCall>[];
    failDispose = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
          calls.add(call);
          if (call.method == 'create') {
            return <String, Object?>{'playerId': 7, 'textureId': 42};
          }
          if (call.method == 'dispose' && failDispose) {
            throw PlatformException(code: 'dispose.failed');
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, null);
    await nativeEvents.close();
  });

  test('registerWith installs the Android implementation', () {
    YlPlayerAndroid.registerWith();
    expect(YlPlayerPlatform.instance, isA<YlPlayerAndroid>());
  });

  test('creates a texture player and delegates the command surface', () async {
    final platform = YlPlayerAndroid(
      methodChannel: methods,
      nativeEvents: nativeEvents.stream,
    );
    final player = await platform.createPlayer(const YlPlayerConfiguration());

    expect(player.textureId.value, 42);
    await player.open(
      YlMediaSource.network(
        Uri.parse('https://media.test/live.flv'),
        isLive: true,
        formatHint: YlFormatHint.httpFlv,
        headers: const {'Referer': 'https://media.test/'},
      ),
    );
    await player.play();
    await player.pause();
    await player.seekTo(const Duration(seconds: 3));
    await player.seekToLiveEdge();
    await player.setPlaybackSpeed(1.25);
    await player.setVolume(0.5);
    await player.selectAudioTrack('audio-1');
    await player.setQualityConstraint(
      const YlQualityConstraint(maxWidth: 1280, maxBitrate: 2500000),
    );
    await player.dispose();
    await player.dispose();

    expect(calls.first.method, 'create');
    expect(calls.where((call) => call.method == 'command').length, 9);
    expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
  });

  test('mirrors multiplexed native state and errors', () async {
    final platform = YlPlayerAndroid(
      methodChannel: methods,
      nativeEvents: nativeEvents.stream,
    );
    final player = await platform.createPlayer(const YlPlayerConfiguration());
    final states = <YlPlayerState>[];
    final events = <YlPlayerEvent>[];
    final stateSubscription = player.states.listen(states.add);
    final eventSubscription = player.events.listen(events.add);

    nativeEvents.add(<String, Object?>{
      'playerId': 7,
      'type': 'state',
      'state': <String, Object?>{
        'status': 'playing',
        'positionMs': 1500,
        'durationMs': 10000,
        'bufferedPositionMs': 4000,
        'isLive': true,
        'isSeekable': true,
        'isAtLiveEdge': false,
        'liveOffsetMs': 3000,
        'videoWidth': 1920,
        'videoHeight': 1080,
        'engine': 'media3',
        'isHardwareDecoding': true,
        'decoderName': 'c2.android.avc.decoder',
        'metrics': <String, Object?>{
          'androidDeviceTier': 'constrained',
          'targetBufferBytes': 24 * 1024 * 1024,
          'adaptiveDowngradeCount': 1,
          'surfaceRebuildCount': 2,
          'selectedVideoBitrate': 2500000,
        },
      },
    });
    nativeEvents.add(<String, Object?>{
      'playerId': 7,
      'type': 'error',
      'error': <String, Object?>{
        'category': 'network',
        'code': 'network.io',
        'message': 'Connection failed.',
        'platformDiagnostic': 'timeout',
      },
    });

    expect(states.single.status, YlPlaybackStatus.playing);
    expect(states.single.videoSize?.width, 1920);
    expect(states.single.engine, YlPlaybackEngine.media3);
    expect(states.single.metrics.androidDeviceTier, 'constrained');
    expect(states.single.metrics.targetBufferBytes, 24 * 1024 * 1024);
    expect(states.single.metrics.adaptiveDowngradeCount, 1);
    expect(states.single.metrics.surfaceRebuildCount, 2);
    expect(states.single.metrics.selectedVideoBitrate, 2500000);
    expect(events.single, isA<YlErrorEvent>());

    await stateSubscription.cancel();
    await eventSubscription.cancel();
    await player.dispose();
  });

  test('cleans up locally when native disposal reports an error', () async {
    final platform = YlPlayerAndroid(
      methodChannel: methods,
      nativeEvents: nativeEvents.stream,
    );
    final player = await platform.createPlayer(const YlPlayerConfiguration());
    failDispose = true;

    await player.dispose();

    expect(player.state.status, YlPlaybackStatus.disposed);
    expect(player.textureId.value, isNull);
  });
}
