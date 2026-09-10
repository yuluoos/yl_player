import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/range_media_server.dart';
import 'support/live_flv_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final (format, extension) in [
    (YlMediaFormat.matroska, 'mkv'),
    (YlMediaFormat.flv, 'flv'),
  ]) {
    testWidgets(
      'bounded $extension positively plays and never exceeds assigned ledger limits',
      (tester) async {
        final rangeServer = extension == 'mkv'
            ? await RangeMediaServer.start(
                asset: 'assets/test_media/h264_aac.mkv',
              )
            : null;
        final liveServer = extension == 'flv'
            ? await LiveFlvServer.start(
                asset: 'assets/test_media/h264_aac.flv',
                repeat: false,
                chunkDelay: const Duration(milliseconds: 8),
              )
            : null;
        addTearDown(() async {
          await rangeServer?.close();
          await liveServer?.close();
        });
        final controller = await appleController(tester);
        final samples = <YlPlaybackMetrics>[];
        final subscription = controller.states.listen((s) {
          if (s.metrics.managedBufferedBytes != null) samples.add(s.metrics);
        });
        addTearDown(subscription.cancel);
        final session = await controller.load(
          YlNetworkSource(
            rangeServer?.mediaUri ?? liveServer!.streamUri,
            format: format,
            networkPolicy: strictNetwork,
          ),
          options: const YlLoadOptions(bufferStrategy: strictBuffer),
        );
        await readyAndPlay(controller, session);
        await stateWhere(
          controller,
          (s) => extension == 'mkv'
              ? s.status == YlPlaybackStatus.completed
              : s.timeline.position > const Duration(milliseconds: 700),
        );
        expect(controller.state.engine, YlPlaybackEngine.managedFallback);
        expect(samples, isNotEmpty);
        expect(samples.any((m) => m.managedBufferedBytes! > 0), isTrue);
        for (final sample in samples) {
          expect(
            sample.managedBufferedBytes,
            inInclusiveRange(0, 16 * 1024 * 1024),
          );
          expect(sample.managedBufferedDuration, isNotNull);
          expect(
            sample.managedBufferedDuration!.inMilliseconds,
            inInclusiveRange(0, 2000),
          );
        }
        expect(
          rangeServer?.requests.length ?? liveServer!.connectionCount,
          greaterThan(0),
        );
        expect(controller.state.metrics.loadToReady, isNotNull);
        expect(controller.state.metrics.loadToFirstFrame, isNotNull);
      },
    );
  }
}
