import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/apple_strict_support.dart';
import 'support/range_media_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'hardwareRequired commits proven hardware or rejects decoder unavailable',
    (tester) async {
      final server = await RangeMediaServer.start(
        asset: 'assets/test_media/h264_aac.mkv',
      );
      addTearDown(server.close);
      final controller = await appleController(tester);
      final states = <YlPlayerState>[];
      final subscription = controller.states.listen(states.add);
      addTearDown(subscription.cancel);
      YlPlaybackSession session;
      try {
        session = await controller.load(
          YlNetworkSource(
            server.mediaUri,
            format: YlMediaFormat.matroska,
            networkPolicy: strictNetwork,
          ),
          options: const YlLoadOptions(
            decoderPolicyOverride: YlDecoderPolicy.hardwareRequired,
          ),
        );
      } on YlPlayerException catch (error) {
        expect(error.failure.code, YlFailureCodes.decoderUnavailable);
        expect(controller.state.sessionId, isNull);
        expect(states.where((s) => s.sessionId != null), isEmpty);
        expect(server.requests, isNotEmpty);
        // This is a tested rejection, never positive hardware evidence or a skip.
        // ignore: avoid_print
        print(
          'APPLE_STRICT_HARDWARE outcome=decoder.unavailable committed=false',
        );
        return;
      }
      expect(controller.state.sessionId, session.id);
      expect(controller.state.decoderMode, YlDecoderMode.hardware);
      await readyAndPlay(controller, session);
      expect(controller.state.decoderMode, YlDecoderMode.hardware);
      expect(
        states
            .where((s) => s.sessionId == session.id)
            .every((s) => s.decoderMode == YlDecoderMode.hardware),
        isTrue,
      );
      // ignore: avoid_print
      print('APPLE_STRICT_HARDWARE outcome=hardware committed=true');
    },
  );
}
