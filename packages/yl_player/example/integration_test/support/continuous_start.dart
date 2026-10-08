import 'package:yl_player/yl_player.dart';

/// Preserve a terminal player failure while waiting for warmup progress.
Future<void> waitForContinuousStart({
  required YlPlayerState Function() current,
  required Stream<YlPlayerState> states,
  required YlPlaybackSessionId sessionId,
}) async {
  bool resolved(YlPlayerState state) =>
      state.failure != null ||
      state.status == YlPlaybackStatus.failed ||
      state.sessionId != sessionId ||
      (state.status == YlPlaybackStatus.playing &&
          state.timeline.position >= const Duration(seconds: 2));
  var state = current();
  if (!resolved(state)) {
    state = await states
        .firstWhere(resolved)
        .timeout(const Duration(seconds: 15));
  }
  if (state.failure case final failure?) throw YlPlayerException(failure);
  if (state.sessionId != sessionId ||
      state.status != YlPlaybackStatus.playing) {
    throw StateError('Continuous warmup ended without a playing session');
  }
}
