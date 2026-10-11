import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  test(
    'live state snapshots are immutable and nullable without inventing defaults',
    () {
      final modes = [
        YlLivePlaybackMode.smoothPlayback,
        YlLivePlaybackMode.lowLatency,
      ];
      final live = YlLivePlaybackState(
        mode: modes.first,
        switchableModes: modes,
      );
      modes.clear();
      expect(live.switchableModes, hasLength(2));
      expect(() => live.switchableModes.clear(), throwsUnsupportedError);
      final state = YlPlayerState(
        sessionId: const YlPlaybackSessionId('s'),
        status: YlPlaybackStatus.ready,
        timeline: const YlTimeline(isLive: true),
        livePlayback: live,
      );
      validateYlPlayerState(state);
      expect(state.copyWith(), state);
      expect(state.copyWith().hashCode, state.hashCode);
      expect(state.copyWith(livePlayback: null).livePlayback, isNull);
      expect(state.copyWith(livePlayback: null), isNot(state));
      expect(() => state.copyWith(livePlayback: 1), throwsArgumentError);
      expect(YlPlayerState().livePlayback, isNull);
      expect(
        const YlLoadOptions().bufferStrategy.kind,
        YlBufferStrategyKind.automatic,
      );
      expect(
        live,
        YlLivePlaybackState(
          mode: YlLivePlaybackMode.smoothPlayback,
          switchableModes: [
            YlLivePlaybackMode.smoothPlayback,
            YlLivePlaybackMode.lowLatency,
          ],
        ),
      );
    },
  );

  test(
    'duplicate modes are rejected but a known non-switchable mode is valid',
    () {
      expect(
        () => YlLivePlaybackState(
          mode: YlLivePlaybackMode.lowLatency,
          switchableModes: [
            YlLivePlaybackMode.lowLatency,
            YlLivePlaybackMode.lowLatency,
          ],
        ),
        throwsArgumentError,
      );
      final live = YlLivePlaybackState(
        mode: YlLivePlaybackMode.smoothPlayback,
        switchableModes: [],
      );
      validateYlPlayerState(
        YlPlayerState(
          sessionId: const YlPlaybackSessionId('s'),
          status: YlPlaybackStatus.playing,
          timeline: const YlTimeline(isLive: true),
          livePlayback: live,
        ),
      );
    },
  );

  test('idle and non-live snapshots cannot claim a committed live mode', () {
    final live = YlLivePlaybackState(
      mode: YlLivePlaybackMode.lowLatency,
      switchableModes: [],
    );
    for (final state in [
      YlPlayerState(livePlayback: live),
      YlPlayerState(
        sessionId: const YlPlaybackSessionId('s'),
        status: YlPlaybackStatus.ready,
        livePlayback: live,
      ),
    ]) {
      expect(() => validateYlPlayerState(state), throwsArgumentError);
    }
  });
}
