import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_source_resolver/yl_player_source_resolver.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'owned header-free JS RTMP result renders matching public firstFrame',
    (tester) async {
      const host = String.fromEnvironment(
        'YL_RTMP_HOST',
        defaultValue: '127.0.0.1',
      );
      final resolver = YlScriptResolver();
      addTearDown(resolver.dispose);
      final resolved = await resolver
          .resolveSource(
            'function main(){return {url:${jsonEncode('rtmp://$host:19351/live/owned')}}}',
          )
          .result;
      final source = resolved.toNetworkSource();
      expect(source.request.headers, isEmpty);
      expect(source.request.credentials, isEmpty);
      final player = await YlPlayerController.create(
        options: const YlPlayerOptions(
          decoderPolicy: YlDecoderPolicy.systemDefault,
          audioPolicy: YlAudioPolicy.appManaged,
        ),
      );
      addTearDown(player.dispose);
      await tester.pumpWidget(
        MaterialApp(home: YlPlayerView(controller: player)),
      );
      final frames = <YlFirstFrameEvent>[];
      final sub = player.events
          .where((e) => e is YlFirstFrameEvent)
          .cast<YlFirstFrameEvent>()
          .listen(frames.add);
      addTearDown(sub.cancel);
      final session = await player.load(source);
      await session.ready.timeout(const Duration(seconds: 15));
      await session.play();
      await session.firstFrame.timeout(const Duration(seconds: 15));
      expect(frames.any((e) => e.sessionId == session.id), isTrue);
      expect(player.state.sessionId, session.id);
      expect(player.state.timeline.isLive, isTrue);
      expect(player.state.audioTracks, isNotEmpty);
      await player.stop();
    },
  );
}
