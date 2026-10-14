import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

/// Same media with controlled HTTP failures, not a weak-network ABR experiment.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final (retries, allFail) in [(1, false), (1, true), (0, false)]) {
    testWidgets('managed DASH candidates retries=$retries allFail=$allFail', (
      tester,
    ) async {
      final manifest = await rootBundle.loadString(
        'assets/test_media/dash_timeline/multiple-base.mpd',
      );
      final server = await DashServer.start(
        timelineMarkers: true,
        manifestOverride: manifest,
        responseStatusByPrefix: {
          '/period0/': 503,
          if (allFail) '/period1/': 503,
        },
      );
      addTearDown(server.close);
      final player = await appleController(tester);
      final source = YlNetworkSource(
        server.automaticUri,
        format: YlMediaFormat.dash,
        networkPolicy: YlNetworkPolicy.managed(
          connectTimeout: const Duration(seconds: 3),
          readTimeout: const Duration(seconds: 3),
          maxRetries: retries,
          baseRetryDelay: const Duration(milliseconds: 30),
          maxRetryDelay: const Duration(milliseconds: 30),
          maxRedirects: 2,
        ),
      );
      if (retries == 1 && !allFail) {
        final session = await player.load(source);
        await readyAndPlay(player, session);
        final completed = await stateWhere(
          player,
          (s) => s.status == YlPlaybackStatus.completed,
        );
        expect(completed.timeline.duration!.inMilliseconds, 4000);
        expect(completed.failure, isNull);
      } else {
        Object? failure;
        try {
          final session = await player.load(source);
          await session.play();
        } catch (error) {
          failure = error;
        }
        if (failure == null) {
          await stateWhere(player, (s) => s.status == YlPlaybackStatus.failed);
        } else {
          expect(failure, isA<YlPlayerException>());
        }
      }
      await player.stop();
      await server.settle();
      final byFile = <String, List<String>>{};
      for (final request in server.childRequests) {
        byFile
            .putIfAbsent(request.path.split('/').last, () => [])
            .add(request.path.split('/')[1]);
      }
      expect(byFile, isNotEmpty);
      for (final requests in byFile.values) {
        expect(requests.first, 'period0');
        if (retries == 0) {
          expect(requests, ['period0']);
        } else if (allFail) {
          expect(requests, ['period0', 'period1']);
        } else {
          expect(requests.length.isEven, isTrue);
          for (var i = 0; i < requests.length; i += 2) {
            expect(requests.sublist(i, i + 2), ['period0', 'period1']);
          }
        }
      }
    });
  }
}
