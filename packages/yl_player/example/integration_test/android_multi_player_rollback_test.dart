import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/android_test_support.dart';
import 'support/range_media_server.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'A failed candidate on a second Player restores previous playback',
    (tester) async {
      final media = await RangeMediaServer.start(
        asset: 'assets/test_media/network_seek_h264_aac.mkv',
      );
      final broken = await RangeMediaServer.start(
        asset: 'assets/test_media/h264_aac.mkv',
        scriptedResponses: const [RangeMediaResponse.status(404)],
      );
      addTearDown(media.close);
      addTearDown(broken.close);
      final first = await YlPlayerController.create();
      final second = await YlPlayerController.create();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              Expanded(child: YlPlayerView(controller: first)),
              Expanded(child: YlPlayerView(controller: second)),
            ],
          ),
        ),
      );
      final session = await first.load(
        YlNetworkSource(media.mediaUri, format: YlMediaFormat.matroska),
      );
      await session.play();
      await session.firstFrame.timeout(const Duration(seconds: 20));
      await waitForState(
        first,
        (state) => state.timeline.position > const Duration(milliseconds: 250),
      );
      final before = first.state.timeline.position;
      await expectLater(
        second.load(
          YlNetworkSource(
            broken.mediaUri,
            format: YlMediaFormat.matroska,
            networkPolicy: const YlNetworkPolicy.managed(maxRetries: 0),
          ),
        ),
        throwsA(failureCode(YlFailureCodes.networkFailed)),
      );
      expect(first.state.sessionId, session.id);
      await waitForState(
        first,
        (state) =>
            state.timeline.position >
            before + const Duration(milliseconds: 250),
      );
      expect(first.state.status, YlPlaybackStatus.playing);
      expect(second.state.sessionId, isNull);
      expect(broken.requests, hasLength(1));
    },
  );
}
