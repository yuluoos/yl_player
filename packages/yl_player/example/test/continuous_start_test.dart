import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import '../integration_test/support/continuous_start.dart';

void main() {
  const id = YlPlaybackSessionId('continuous');
  const failure = YlFailure(
    category: YlFailureCategory.decoder,
    code: 'decoder.video_decode_failed',
    message: 'Decode failed',
    retryable: false,
    scope: YlFailureScope.session,
    diagnosticId: 'test',
  );
  test('existing decode failure is retained instead of timing out', () async {
    await expectLater(
      waitForContinuousStart(
        current: () => YlPlayerState(
          sessionId: id,
          status: YlPlaybackStatus.failed,
          failure: failure,
        ),
        states: const Stream.empty(),
        sessionId: id,
      ),
      throwsA(
        isA<YlPlayerException>().having(
          (e) => e.failure.code,
          'code',
          failure.code,
        ),
      ),
    );
  });
  test('failure during warmup fails before progress deadline', () async {
    final stream = StreamController<YlPlayerState>();
    addTearDown(stream.close);
    final result = waitForContinuousStart(
      current: () =>
          YlPlayerState(sessionId: id, status: YlPlaybackStatus.playing),
      states: stream.stream,
      sessionId: id,
    );
    final expectation = expectLater(result, throwsA(isA<YlPlayerException>()));
    stream.add(
      YlPlayerState(
        sessionId: id,
        status: YlPlaybackStatus.failed,
        failure: failure,
      ),
    );
    await expectation;
  });
  test('accepts two seconds only in same playing session', () async {
    await waitForContinuousStart(
      current: () => YlPlayerState(
        sessionId: id,
        status: YlPlaybackStatus.playing,
        timeline: const YlTimeline(position: Duration(seconds: 2)),
      ),
      states: const Stream.empty(),
      sessionId: id,
    );
    await expectLater(
      waitForContinuousStart(
        current: () => YlPlayerState(
          sessionId: const YlPlaybackSessionId('other'),
          status: YlPlaybackStatus.playing,
          timeline: const YlTimeline(position: Duration(seconds: 2)),
        ),
        states: const Stream.empty(),
        sessionId: id,
      ),
      throwsStateError,
    );
  });
}
