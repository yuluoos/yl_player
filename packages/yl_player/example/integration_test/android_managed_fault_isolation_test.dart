import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';
import 'support/range_media_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'forbidden DASH manifest consumes one request even with retries',
    (tester) async {
      final server = await DashServer.start(rootStatusCode: 403);
      addTearDown(server.close);
      final player = await appleController(tester);
      await expectLater(
        player.load(
          YlNetworkSource(
            server.automaticUri,
            format: YlMediaFormat.dash,
            networkPolicy: strictNetwork,
          ),
        ),
        failureCode(YlFailureCodes.networkHttpForbidden),
      );
      await server.settle();
      expect(server.requests.map((r) => r.path), ['/manifest.mpd']);
      expect(player.state.sessionId, isNull);
    },
  );

  testWidgets('managed redirect budget prevents a third manifest request', (
    tester,
  ) async {
    final server = await DashServer.start();
    addTearDown(server.close);
    final player = await appleController(tester);
    await expectLater(
      player.load(
        YlNetworkSource(
          server.redirectUri,
          format: YlMediaFormat.dash,
          networkPolicy: const YlNetworkPolicy.managed(maxRedirects: 1),
        ),
      ),
      failureCode('network.redirect_limit'),
    );
    await server.settle();
    expect(server.requests.map((r) => r.path), [
      '/redirect.mpd',
      '/redirect-hop.mpd',
    ]);
    expect(player.state.sessionId, isNull);
  });

  testWidgets(
    'malformed external subtitle preserves the advancing video session',
    (tester) async {
      final media = await RangeMediaServer.start(
        asset: 'assets/test_media/network_seek_h264_aac.mkv',
      );
      addTearDown(media.close);
      final dir = await Directory.systemTemp.createTemp('malformed-cue-');
      addTearDown(() => dir.delete(recursive: true));
      final file = await File(
        '${dir.path}/bad.srt',
      ).writeAsString('invalid subtitle');
      final player = await YlPlayerController.create(enableTextSubtitles: true);
      addTearDown(player.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: YlPlayerView(controller: player),
        ),
      );
      final session = await player.load(
        YlNetworkSource(media.mediaUri, format: YlMediaFormat.matroska),
      );
      await readyAndPlay(player, session);
      await expectLater(
        session.replaceExternalSubtitles([
          YlExternalSubtitle(
            id: 'broken',
            source: YlFileSource(file.path),
            format: YlSubtitleFormat.srt,
          ),
        ]),
        failureCode(YlFailureCodes.subtitleMalformed),
      );
      final before = player.state.timeline.position;
      final state = await stateWhere(
        player,
        (s) => s.timeline.position > before + const Duration(seconds: 1),
      );
      expect(state.sessionId, session.id);
      expect(state.status, YlPlaybackStatus.playing);
      expect(state.failure, isNull);
      expect(state.subtitles.tracks, isEmpty);
    },
  );
}
