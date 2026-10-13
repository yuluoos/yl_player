import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/android_test_support.dart';
import 'support/dash_server.dart';

// Existing owned AAC files carry independent 440 Hz / 660 Hz markers. Keeping
// paths distinct verifies actual requests; selection assertions do not measure
// physical speaker output.
Future<String> audioManifest({bool dropCommentary = false}) async {
  final original = await rootBundle.loadString(
    'assets/test_media/dash/manifest.mpd',
  );
  var period = 0;
  return original.replaceAllMapped(
    RegExp(r'<AdaptationSet id="1"[\s\S]*?</AdaptationSet>'),
    (match) {
      final second = period++ == 1;
      String track(int id, String role, int tone) => match[0]!
          .replaceFirst('id="1"', 'id="$id" lang="en"')
          .replaceFirst(
            '<Representation',
            '<Role schemeIdUri="urn:mpeg:dash:role:2011" value="$role"/><Representation',
          )
          .replaceAll(
            'initialization="init-\$RepresentationID\$.m4s"',
            'initialization="../period$tone/init-1.m4s"',
          )
          .replaceAll(
            'media="chunk-\$RepresentationID\$-\$Number%05d\$.m4s"',
            'media="../period$tone/chunk-1-\$Number%05d\$.m4s"',
          )
          .replaceFirst(
            '<Representation id="1"',
            '<Representation id="${second ? 99 : 1}"',
          );
      final main = track(10, 'main', 0);
      final comment = track(20, 'commentary', 1);
      return second ? (dropCommentary ? main : comment + main) : main + comment;
    },
  );
}

Future<YlPlayerController> createPlayer(WidgetTester tester) async {
  final player = await YlPlayerController.create();
  addTearDown(player.dispose);
  await tester.pumpWidget(MaterialApp(home: YlPlayerView(controller: player)));
  return player;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android same-language audio remains selected across reordered Periods, seeks and caps',
    (tester) async {
      final server = await DashServer.start(
        manifestOverride: await audioManifest(),
      );
      addTearDown(server.close);
      final player = await createPlayer(tester);
      final session = await player.load(
        YlNetworkSource(
          server.explicitUri,
          format: YlMediaFormat.dash,
          networkPolicy: const YlNetworkPolicy.managed(),
          request: YlHttpRequest(
            credentials: const {'Authorization': 'owned-audio'},
          ),
        ),
      );
      await session.play();
      await session.firstFrame.timeout(const Duration(seconds: 20));
      await waitForState(player, (s) => s.audioTracks.length == 2);
      await session.pause();
      final tracks = player.state.audioTracks;
      expect(tracks.map((t) => t.id).toSet(), hasLength(2));
      expect(tracks.map((t) => t.language), everyElement('en'));
      final comment = tracks.singleWhere(
        (t) => t.label!.contains('commentary'),
      );
      final main = tracks.singleWhere((t) => !t.label!.contains('commentary'));
      for (final track in [comment, main, comment]) {
        await session.selectAudioTrack(track.id);
        await waitForState(
          player,
          (s) =>
              s.audioTracks.where((t) => t.isSelected).singleOrNull?.id ==
              track.id,
        );
      }
      // Cross the boundary during playback, then explicitly seek both directions.
      for (final position in [3500, 1000, 4500]) {
        await session.seekTo(Duration(milliseconds: position));
        await session.play();
        await waitForState(
          player,
          (s) =>
              s.timeline.position.inMilliseconds >
              (position == 3500 ? 4400 : position + 250),
        );
        await session.pause();
        expect(
          player.state.audioTracks.where((t) => t.isSelected).single.id,
          comment.id,
        );
        expect(
          player.state.audioTracks.map((t) => t.id).toSet(),
          tracks.map((t) => t.id).toSet(),
        );
      }
      await session.setVideoConstraints(
        const YlVideoConstraints(maxWidth: 320, maxHeight: 180),
      );
      await session.play();
      await waitForState(
        player,
        (s) => s.timeline.position.inMilliseconds > 5200,
      );
      await session.pause();
      expect(
        player.state.audioTracks.where((t) => t.isSelected).single.id,
        comment.id,
      );
      await expectLater(
        session.selectAudioTrack('missing-audio'),
        throwsA(failureCode('track.not_found')),
      );
      expect(
        player.state.audioTracks.where((t) => t.isSelected).single.id,
        comment.id,
      );
      expect(player.state.sessionId, session.id);
      expect(player.state.failure, isNull);
      expect(
        server.childRequests.any((r) => r.path.contains('period0/chunk-1')),
        isTrue,
      );
      expect(
        server.childRequests.any((r) => r.path.contains('period1/chunk-1')),
        isTrue,
      );
      for (final request in server.childRequests) {
        expect(request.header('authorization'), 'owned-audio');
      }
    },
  );

  testWidgets(
    'Android reports selected audio missing in prepared next Period',
    (tester) async {
      final server = await DashServer.start(
        manifestOverride: await audioManifest(dropCommentary: true),
      );
      addTearDown(server.close);
      final player = await createPlayer(tester);
      final failed = player.events
          .where((e) => e is YlPlaybackFailedEvent)
          .cast<YlPlaybackFailedEvent>()
          .first;
      final session = await player.load(
        YlNetworkSource(server.explicitUri, format: YlMediaFormat.dash),
      );
      await waitForState(player, (s) => s.audioTracks.length == 2);
      final comment = player.state.audioTracks.singleWhere(
        (t) => t.label!.contains('commentary'),
      );
      await session.selectAudioTrack(comment.id);
      await session.play();
      final error = await failed.timeout(const Duration(seconds: 20));
      expect(error.failure.code, 'track.not_found');
      expect(error.sessionId, session.id);
    },
  );
}
