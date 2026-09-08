import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  test('network source snapshots request headers and records live intent', () {
    final headers = {'Referer': 'https://example.test'};
    final source = YlNetworkSource(
      Uri.parse('https://media.test/live.m3u8'),
      intent: YlStreamIntent.live,
      format: YlMediaFormat.hls,
      request: YlHttpRequest(headers: headers),
    );
    headers.clear();
    expect(source.request.headers, hasLength(1));
    expect(source.intent, YlStreamIntent.live);
    expect(() => source.request.headers.clear(), throwsUnsupportedError);
  });
  test('file and content sources retain their distinct identities', () {
    expect(const YlFileSource('/media/video.mp4').path, '/media/video.mp4');
    expect(
      YlAndroidContentSource(Uri.parse('content://media/1')).uri.scheme,
      'content',
    );
  });
  test('state copy preserves fields and explicitly clears nullable values', () {
    final state = YlPlayerState(
      sessionId: const YlPlaybackSessionId('s'),
      status: YlPlaybackStatus.playing,
      timeline: const YlTimeline(
        position: Duration(seconds: 4),
        duration: Duration(minutes: 1),
      ),
    );
    final changed = state.copyWith(
      timeline: state.timeline.copyWith(
        position: const Duration(seconds: 5),
        duration: null,
      ),
    );
    expect(changed.status, state.status);
    expect(changed.timeline.duration, isNull);
    expect(changed.timeline.position, const Duration(seconds: 5));
  });
  test('track and capability lists are immutable snapshots', () {
    final tracks = [const YlMediaTrack(id: 'a', kind: YlTrackKind.audio)];
    final state = YlPlayerState(audioTracks: tracks);
    tracks.clear();
    expect(state.audioTracks, hasLength(1));
    expect(() => state.audioTracks.clear(), throwsUnsupportedError);
    final codecs = ['h264'];
    final cap = YlPlayerCapabilities(
      deviceProfile: 'test',
      hardwareVideoCodecs: codecs,
    );
    codecs.clear();
    expect(cap.hardwareVideoCodecs, ['h264']);
  });
  test('metrics preserve omitted and clear explicit nullable values', () {
    const metrics = YlPlaybackMetrics(
      loadToFirstFrame: Duration(milliseconds: 40),
      rebufferCount: 2,
      estimatedBitrate: 10,
    );
    final changed = metrics.copyWith(estimatedBitrate: null);
    expect(changed.loadToFirstFrame, metrics.loadToFirstFrame);
    expect(changed.rebufferCount, 2);
    expect(changed.estimatedBitrate, isNull);
  });
}
