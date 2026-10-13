import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

Future<String> audioManifest() async {
  final original = await rootBundle.loadString(
    'assets/test_media/dash/manifest.mpd',
  );
  var period = 0;
  return original.replaceAllMapped(
    RegExp(r'<AdaptationSet id="1"[\s\S]*?</AdaptationSet>'),
    (match) {
      String track(String id, String role, int tone) => match[0]!
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
          );
      final main = track('main', 'main', 0);
      final commentary = track('commentary', 'commentary', 1);
      return period++ == 0 ? main + commentary : commentary + main;
    },
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'same-language DASH audio identities select, survive seek and quality rebuild',
    (tester) async {
      final server = await DashServer.start(
        manifestOverride: await audioManifest(),
      );
      addTearDown(server.close);
      final player = await appleController(tester);
      final session = await player.load(
        YlNetworkSource(
          server.explicitUri,
          format: YlMediaFormat.dash,
          request: YlHttpRequest(
            credentials: const {'Authorization': 'owned-audio'},
          ),
        ),
      );
      await readyAndPlay(player, session);
      await stateWhere(
        player,
        (s) =>
            s.audioTracks.length == 2 && s.audioTracks.any((t) => t.isSelected),
      );
      await session.pause();
      final tracks = player.state.audioTracks;
      expect(tracks.map((t) => t.id).toSet(), hasLength(2));
      expect(tracks.map((t) => t.language), everyElement('en'));
      expect(tracks.map((t) => t.codec), everyElement('mp4a.40.2'));
      final commentary = tracks.singleWhere(
        (t) => t.label!.contains('commentary'),
      );
      final main = tracks.singleWhere((t) => !t.label!.contains('commentary'));
      for (final track in [commentary, main, commentary]) {
        await session.selectAudioTrack(track.id);
        await stateWhere(
          player,
          (s) =>
              s.audioTracks.where((t) => t.isSelected).singleOrNull?.id ==
              track.id,
        );
      }
      await session.seekTo(const Duration(milliseconds: 4500));
      await session.play();
      await stateWhere(
        player,
        (s) => s.timeline.position > const Duration(milliseconds: 4800),
      );
      await session.pause();
      expect(
        player.state.audioTracks.where((t) => t.isSelected).single.id,
        commentary.id,
      );
      expect(
        player.state.audioTracks.map((t) => t.id).toSet(),
        tracks.map((t) => t.id).toSet(),
      );
      final rebuilding = player.states
          .firstWhere((s) => s.sessionId == session.id && s.audioTracks.isEmpty)
          .timeout(const Duration(seconds: 15));
      await session.setVideoConstraints(
        const YlVideoConstraints(maxWidth: 320, maxHeight: 180),
      );
      await rebuilding;
      await stateWhere(
        player,
        (s) =>
            s.audioTracks.length == 2 && s.audioTracks.any((t) => t.isSelected),
      );
      expect(
        player.state.audioTracks.where((t) => t.isSelected).single.id,
        commentary.id,
      );
      final before = player.state.audioTracks;
      await expectLater(
        session.selectAudioTrack('missing-audio'),
        throwsA(isA<YlPlayerException>()),
      );
      expect(player.state.audioTracks, before);
      expect(player.state.sessionId, session.id);
      expect(player.state.failure, isNull);
      expect(server.childRequests, isNotEmpty);
      for (final request in server.childRequests) {
        expect(request.header('authorization'), 'owned-audio');
      }
    },
  );
}
