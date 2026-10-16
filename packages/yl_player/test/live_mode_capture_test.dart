import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import '../example/integration_test/support/live_mode_series.dart';

void main() {
  Map<String, String> config(String protocol, String url) => {
    'runId': 'live-1',
    'protocol': protocol,
    'url': url,
    'owned': 'true',
    'mediaHash': 'a' * 64,
  };
  for (final pair in [
    ('hls', 'http://127.0.0.1:8001/live.m3u8'),
    ('flv', 'http://127.0.0.1:8002/live.flv'),
    ('rtmp', 'rtmp://127.0.0.1:1935/live/stream'),
  ]) {
    test('accept explicit local ${pair.$1} fixture', () {
      expect(
        parseLiveModeConfig(config(pair.$1, pair.$2))['protocol'],
        pair.$1,
      );
    });
  }
  for (final url in [
    'https://external.invalid/live.m3u8',
    'http://127.0.0.1/live.m3u8',
    'http://secret@127.0.0.1:8000/live.m3u8',
    'http://127.0.0.1:8000/live.m3u8?token=secret',
  ]) {
    test('reject unsafe capture config $url', () {
      expect(
        () => parseLiveModeConfig(config('hls', url)),
        throwsFormatException,
      );
    });
  }
  test('observations bounded and missing metrics remain unknown', () {
    const id = YlPlaybackSessionId('live-1');
    final series = LiveModeSeries(id, limit: 2);
    final state = YlPlayerState(
      sessionId: id,
      revision: 3,
      livePlayback: YlLivePlaybackState(
        mode: YlLivePlaybackMode.lowLatency,
        switchableModes: [],
      ),
    );
    series.add(state.copyWith(sessionId: const YlPlaybackSessionId('old')), 0);
    expect(series.samples, isEmpty);
    series.add(state, 10);
    expect(series.samples.single['endToEndLatencyUs'], isNull);
    expect(series.samples.single['liveOffsetUs'], isNull);
    expect(series.samples.single['mode'], 'lowLatency');
    expect(() => series.add(state, 9), throwsStateError);
    series.add(state, 11);
    expect(() => series.add(state, 12), throwsStateError);
  });
}
