import 'package:yl_player/yl_player.dart';

Map<String, String> parseAbrConfig(Map<String, String> values) {
  const keys = {
    'runId',
    'mode',
    'url',
    'profileId',
    'profileHash',
    'mediaHash',
  };
  const invalid = FormatException('Invalid owned ABR capture configuration');
  try {
    if (values.length != keys.length ||
        !values.keys.every(keys.contains) ||
        !{'auto', 'caps', 'fixed'}.contains(values['mode'])) {
      throw invalid;
    }
    final token = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$');
    if (!token.hasMatch(values['runId']!) ||
        !token.hasMatch(values['profileId']!)) {
      throw invalid;
    }
    for (final key in ['profileHash', 'mediaHash']) {
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(values[key]!)) throw invalid;
    }
    final uri = Uri.parse(values['url']!);
    if (uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path != '/manifest.mpd' ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw invalid;
    }
    return Map.unmodifiable(values);
  } catch (_) {
    throw invalid;
  }
}

/// Test-owned polling records. Missing native metrics stay null; geometry is
/// public state, not an independent image readback or physical-output signal.
final class AbrNetworkSeries {
  AbrNetworkSeries(this.session, {this.limit = 1024});
  final YlPlaybackSessionId session;
  final int limit;
  final _samples = <Map<String, Object?>>[];
  List<Map<String, Object?>> get samples => List.unmodifiable(_samples);

  void add(YlPlayerState state, int elapsedUs) {
    if (state.sessionId != session) return;
    if (elapsedUs < 0 ||
        (_samples.isNotEmpty &&
            elapsedUs < (_samples.last['elapsedUs'] as int)) ||
        _samples.length >= limit) {
      throw StateError('Invalid or overflowing ABR observations');
    }
    final selected = state.videoTracks.where((t) => t.isSelected).toList();
    final track = selected.length == 1 ? selected.single : null;
    _samples.add(
      Map.unmodifiable({
        'elapsedUs': elapsedUs,
        'positionUs': state.timeline.position.inMicroseconds,
        'bufferedPositionUs': state.timeline.bufferedPosition.inMicroseconds,
        'status': state.status.name,
        'automatic': state.videoSelection.isAutomatic,
        'selectionReason': state.videoSelection.reason.name,
        'width': state.videoGeometry?.encodedSize.width,
        'height': state.videoGeometry?.encodedSize.height,
        'selectedWidth': track?.width,
        'selectedHeight': track?.height,
        'selectedBitrate': track?.bitrate,
        'estimatedBitrate': state.metrics.estimatedBitrate,
        'rebufferCount': state.metrics.rebufferCount,
        'rebufferUs': state.metrics.rebufferDuration?.inMicroseconds,
        'droppedFrames': state.metrics.droppedVideoFrames,
        'audioSelected': state.audioTracks.any((t) => t.isSelected),
        'engine': state.engine.name,
        'decoder': state.decoderMode.name,
        'failed': state.failure != null,
      }),
    );
  }
}
