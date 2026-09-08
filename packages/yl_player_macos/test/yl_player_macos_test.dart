import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_macos/yl_player_macos.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('registerWith installs v2 implementation', () {
    YlPlayerMacos.registerWith();
    expect(YlPlayerPlatform.instance, isA<YlPlayerMacos>());
  });
  test('injected channels create and load a session before commands', () async {
    const methods = MethodChannel('registration-macos');
    final wire = StreamController<Object?>.broadcast(sync: true);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
          calls.add(call);
          if (call.method == 'create') return {'playerId': 7, 'textureId': 42};
          if (call.method == 'command') {
            final args = call.arguments as Map;
            if (args['name'] == 'requestState' || args['name'] == 'open') {
              final source = (args['arguments'] as Map)['source'] as Map?;
              wire.add({
                'playerId': 7,
                'type': 'state',
                'protocolVersion': 1,
                'generation': source == null ? 0 : 3,
                'loadToken': source?['loadToken'],
                'state': {
                  'status': source == null ? 'idle' : 'opening',
                  'engine': 'avPlayer',
                  'capabilities': <String, Object?>{},
                },
              });
              if (source != null) return {'loadToken': source['loadToken']};
            }
          }
          return null;
        });
    final player = await YlPlayerMacos(
      methodChannel: methods,
      nativeEvents: wire.stream,
    ).createPlayer(const YlPlayerOptions());
    expect(player.textureId.value, 42);
    expect(calls.first.arguments['configuration']['audioPolicy'], 'appManaged');
    final load = await player.load(
      YlNetworkSource(Uri.parse('https://example.test/a.mp4')),
    );
    await player.play(load.sessionId);
    await player.pause(load.sessionId);
    await player.seekTo(load.sessionId, const Duration(seconds: 1));
    await player.seekToLiveEdge(load.sessionId);
    await player.setPlaybackSpeed(load.sessionId, 1.25);
    await player.selectAudioTrack(load.sessionId, 'a');
    await player.setVideoConstraints(
      load.sessionId,
      const YlVideoConstraints(maxWidth: 1280),
    );
    await player.setVolume(.5);
    await player.stop();
    await player.dispose();
    await player.dispose();
    expect(calls.where((call) => call.method == 'dispose'), hasLength(1));
    expect(player.textureId.value, isNull);
    await wire.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, null);
  });
}
