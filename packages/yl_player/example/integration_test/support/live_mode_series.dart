import 'package:yl_player/yl_player.dart';

/// Local owned fixture only. Hashes are declarations until joined with a server
/// receipt; neither this config nor public timeline proves source-clock latency.
Map<String, String> parseLiveModeConfig(Map<String, String> values) {
  const invalid = FormatException('Invalid owned live capture configuration');
  try {
    final protocol = values['protocol'];
    final uri = Uri.parse(values['url'] ?? '');
    if (!{'hls', 'flv', 'rtmp'}.contains(protocol) ||
        !RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$',
        ).hasMatch(values['runId'] ?? '') ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(values['mediaHash'] ?? '') ||
        values['owned'] != 'true' ||
        uri.host != '127.0.0.1' ||
        uri.scheme != (protocol == 'rtmp' ? 'rtmp' : 'http') ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535 ||
        (protocol == 'hls' && !uri.path.endsWith('.m3u8')) ||
        (protocol == 'flv' && !uri.path.endsWith('.flv')) ||
        (protocol == 'rtmp' &&
            uri.pathSegments.where((v) => v.isNotEmpty).length < 2)) {
      throw invalid;
    }
    return Map.unmodifiable(values);
  } catch (_) {
    throw invalid;
  }
}

final class LiveModeSeries {
  LiveModeSeries(this.session, {this.limit = 1024});
  final YlPlaybackSessionId session;
  final int limit;
  final _samples = <Map<String, Object?>>[];
  List<Map<String, Object?>> get samples => List.unmodifiable(_samples);
  void add(YlPlayerState state, int elapsedUs) {
    if (state.sessionId != session) return;
    if (elapsedUs < 0 ||
        _samples.length >= limit ||
        (_samples.isNotEmpty &&
            elapsedUs < (_samples.last['elapsedUs'] as int))) {
      throw StateError('Invalid or overflowing live observations');
    }
    _samples.add(
      Map.unmodifiable({
        'elapsedUs': elapsedUs,
        'revision': state.revision,
        'status': state.status.name,
        'mode': state.livePlayback?.mode.name,
        'positionUs': state.timeline.position.inMicroseconds,
        'mediaClockUs': state.metrics.mediaClockPosition?.inMicroseconds,
        'liveOffsetUs': state.timeline.liveOffset?.inMicroseconds,
        'managedBufferedUs':
            state.metrics.managedBufferedDuration?.inMicroseconds,
        'rebufferCount': state.metrics.rebufferCount,
        'rebufferUs': state.metrics.rebufferDuration?.inMicroseconds,
        'reconnectCount': state.metrics.reconnectCount,
        'failed': state.failure != null,
        'endToEndLatencyUs': null,
      }),
    );
  }
}
