import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import '../integration_test/support/abr_network_series.dart';

void main() {
  test('capture binds one session and preserves unavailable metrics', () {
    final series = AbrNetworkSeries(const YlPlaybackSessionId('current'));
    series.add(YlPlayerState(sessionId: const YlPlaybackSessionId('old')), 0);
    series.add(
      YlPlayerState(sessionId: const YlPlaybackSessionId('current')),
      1,
    );
    expect(series.samples, hasLength(1));
    expect(series.samples.single['rebufferCount'], isNull);
    expect(series.samples.single['estimatedBitrate'], isNull);
    expect(series.samples.single['height'], isNull);
    expect(jsonEncode(series.samples), isNot(contains('current')));
  });
  test('captures geometry and policy without private track data', () {
    final series = AbrNetworkSeries(const YlPlaybackSessionId('s'));
    series.add(
      YlPlayerState(
        sessionId: const YlPlaybackSessionId('s'),
        status: YlPlaybackStatus.playing,
        videoSelection: const YlVideoSelection(fixedTrackId: 'secret-url'),
        videoTracks: const [
          YlMediaTrack(
            id: 'secret-url',
            kind: YlTrackKind.video,
            isSelected: true,
            width: 640,
            height: 360,
            bitrate: 700000,
          ),
        ],
        videoGeometry: const YlVideoGeometry(
          encodedSize: YlPixelSize(640, 360),
          displaySize: YlPixelSize(640, 360),
        ),
        metrics: const YlPlaybackMetrics(
          estimatedBitrate: 1234567,
          rebufferCount: 2,
          rebufferDuration: Duration(milliseconds: 500),
        ),
      ),
      1000,
    );
    expect(series.samples.single['automatic'], false);
    expect(series.samples.single['height'], 360);
    expect(series.samples.single['selectedBitrate'], 700000);
    expect(series.samples.single['rebufferUs'], 500000);
    expect(series.samples.single['estimatedBitrate'], 1234567);
    expect(jsonEncode(series.samples), isNot(contains('secret-url')));
  });
  test('capture fails on overflow or reversed time instead of truncating', () {
    final series = AbrNetworkSeries(const YlPlaybackSessionId('s'), limit: 2);
    final state = YlPlayerState(sessionId: const YlPlaybackSessionId('s'));
    series.add(state, 2);
    expect(() => series.add(state, 1), throwsStateError);
    series.add(state, 3);
    expect(() => series.add(state, 4), throwsStateError);
    expect(series.samples, hasLength(2));
  });
  test('run configuration rejects unsafe identity and non-loopback URL', () {
    for (final input in [
      {'mode': 'bad'},
      {'runId': 'https://secret.test'},
      {'url': 'http://remote.test/manifest.mpd'},
      {'url': 'http://127.0.0.1:1/manifest.mpd?secret=x'},
      {'profileHash': 'bad'},
    ]) {
      expect(
        () => parseAbrConfig({..._config, ...input}),
        throwsFormatException,
      );
    }
    expect(parseAbrConfig(_config)['mode'], 'fixed');
  });
}

final _config = <String, String>{
  'runId': 'owned-1',
  'mode': 'fixed',
  'url': 'http://127.0.0.1:18779/manifest.mpd',
  'profileId': 'down-and-recover-v1',
  'profileHash': 'a' * 64,
  'mediaHash': 'b' * 64,
};
