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
  test(
    'device capture permits only an explicitly declared private IPv4 host',
    () {
      for (final address in ['10.1.2.3', '172.16.2.3', '192.168.50.196']) {
        final value = config('flv', 'http://$address:8000/live.flv');
        expect(() => parseLiveModeConfig(value), throwsFormatException);
        value['ownedHost'] = address;
        expect(parseLiveModeConfig(value)['ownedHost'], address);
      }
      for (final address in [
        'example.com',
        '8.8.8.8',
        '172.32.0.1',
        '192.168.1.999',
        '192.168.01.2',
      ]) {
        final value = config('flv', 'http://$address:8000/live.flv')
          ..['ownedHost'] = address;
        expect(() => parseLiveModeConfig(value), throwsFormatException);
      }
      expect(
        () => parseLiveModeConfig(
          config('flv', 'http://192.168.1.2:8000/live.flv')
            ..['ownedHost'] = '192.168.1.3',
        ),
        throwsFormatException,
      );
    },
  );
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
