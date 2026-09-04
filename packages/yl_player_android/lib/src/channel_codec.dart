import 'package:flutter/services.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

Map<String, Object?> encodeConfiguration(
  YlPlayerConfiguration configuration,
) => <String, Object?>{
  'bufferMode': configuration.bufferMode.name,
  'decoderPolicy': configuration.decoderPolicy.name,
  'minBufferMs': configuration.minBufferDuration?.inMilliseconds,
  'maxBufferMs': configuration.maxBufferDuration?.inMilliseconds,
  'maxBufferBytes': configuration.maxBufferBytes,
  'positionEventIntervalMs': configuration.positionEventInterval.inMilliseconds,
  'network': <String, Object?>{
    'connectTimeoutMs':
        configuration.networkPolicy.connectTimeout.inMilliseconds,
    'readTimeoutMs': configuration.networkPolicy.readTimeout.inMilliseconds,
    'maxRetries': configuration.networkPolicy.maxRetries,
    'baseRetryDelayMs':
        configuration.networkPolicy.baseRetryDelay.inMilliseconds,
    'maxRetryDelayMs': configuration.networkPolicy.maxRetryDelay.inMilliseconds,
    'maxRedirects': configuration.networkPolicy.maxRedirects,
  },
};

Map<String, Object?> encodeSource(YlMediaSource source) => <String, Object?>{
  'uri': source.uri.toString(),
  'kind': source.kind.name,
  'isLive': source.isLive,
  'formatHint': source.formatHint.name,
  'headers': source.headers,
};

Map<String, Object?> encodeQualityConstraint(YlQualityConstraint constraint) =>
    <String, Object?>{
      'maxWidth': constraint.maxWidth,
      'maxHeight': constraint.maxHeight,
      'maxBitrate': constraint.maxBitrate,
    };

YlPlayerState decodeState(Object? value) {
  final map = _stringMap(value);
  final width = _int(map['videoWidth']);
  final height = _int(map['videoHeight']);
  final durationMs = _int(map['durationMs']);
  final liveOffsetMs = _int(map['liveOffsetMs']);
  final dvrStartMs = _int(map['dvrStartMs']);
  final dvrEndMs = _int(map['dvrEndMs']);
  return YlPlayerState(
    status: _enumByName(
      YlPlaybackStatus.values,
      map['status'],
      YlPlaybackStatus.idle,
    ),
    position: Duration(milliseconds: _int(map['positionMs']) ?? 0),
    duration: durationMs == null ? null : Duration(milliseconds: durationMs),
    bufferedPosition: Duration(
      milliseconds: _int(map['bufferedPositionMs']) ?? 0,
    ),
    isLive: map['isLive'] == true,
    isSeekable: map['isSeekable'] == true,
    isAtLiveEdge: map['isAtLiveEdge'] == true,
    liveOffset: liveOffsetMs == null
        ? null
        : Duration(milliseconds: liveOffsetMs),
    dvrWindow: dvrStartMs == null || dvrEndMs == null
        ? null
        : YlDvrWindow(
            start: Duration(milliseconds: dvrStartMs),
            end: Duration(milliseconds: dvrEndMs),
          ),
    videoSize: width == null || height == null || width <= 0 || height <= 0
        ? null
        : YlVideoSize(width, height),
    engine: _enumByName(
      YlPlaybackEngine.values,
      map['engine'],
      YlPlaybackEngine.unknown,
    ),
    isHardwareDecoding: map['isHardwareDecoding'] == true,
    decoderName: map['decoderName'] as String?,
    audioTracks: _decodeTracks(map['audioTracks'], YlTrackKind.audio),
    videoTracks: _decodeTracks(map['videoTracks'], YlTrackKind.video),
    capabilities: _decodeCapabilities(map['capabilities']),
    metrics: _decodeMetrics(map['metrics']),
    error: map['error'] == null ? null : decodeError(map['error']),
  );
}

YlPlayerEvent? decodeEvent(Map<String, Object?> envelope) {
  switch (envelope['type']) {
    case 'firstFrame':
      return YlFirstFrameEvent(
        width: _int(envelope['width']),
        height: _int(envelope['height']),
      );
    case 'error':
      return YlErrorEvent(decodeError(envelope['error']));
    case 'tracksChanged':
      return YlTracksChangedEvent(
        audioTracks: _decodeTracks(envelope['audioTracks'], YlTrackKind.audio),
        videoTracks: _decodeTracks(envelope['videoTracks'], YlTrackKind.video),
      );
    case 'retry':
      return YlRetryEvent(
        attempt: _int(envelope['attempt']) ?? 0,
        delay: Duration(milliseconds: _int(envelope['delayMs']) ?? 0),
        error: decodeError(envelope['error']),
      );
    case 'fallback':
      return YlFallbackEvent(
        from: _enumByName(
          YlPlaybackEngine.values,
          envelope['from'],
          YlPlaybackEngine.unknown,
        ),
        to: _enumByName(
          YlPlaybackEngine.values,
          envelope['to'],
          YlPlaybackEngine.nativeFallback,
        ),
        reason: decodeError(envelope['error']),
      );
  }
  return null;
}

YlPlayerError decodeError(Object? value) {
  final map = _stringMap(value);
  return YlPlayerError(
    category: _enumByName(
      YlPlayerErrorCategory.values,
      map['category'],
      YlPlayerErrorCategory.internal,
    ),
    code: map['code'] as String? ?? 'platform.unknown',
    message: map['message'] as String? ?? 'Native playback failed.',
    platformDiagnostic: map['platformDiagnostic'] as String?,
  );
}

YlPlayerError decodePlatformException(
  PlatformException exception, {
  required String platform,
}) {
  final details = exception.details;
  if (details is Map) {
    return decodeError(details);
  }
  return YlPlayerError(
    category: YlPlayerErrorCategory.internal,
    code: exception.code.isEmpty ? '$platform.platform_error' : exception.code,
    message: exception.message ?? 'Native playback failed.',
    platformDiagnostic: details?.toString(),
  );
}

Map<String, Object?> stringMap(Object? value) => _stringMap(value);

Map<String, Object?> _stringMap(Object? value) {
  if (value is! Map) {
    return const <String, Object?>{};
  }
  return value.map<String, Object?>((key, item) => MapEntry('$key', item));
}

int? _int(Object? value) => value is num ? value.toInt() : null;

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final value in values) {
    if (value.name == name) {
      return value;
    }
  }
  return fallback;
}

List<YlMediaTrack> _decodeTracks(Object? value, YlTrackKind fallbackKind) {
  if (value is! List) {
    return const <YlMediaTrack>[];
  }
  return value
      .map((item) {
        final map = _stringMap(item);
        return YlMediaTrack(
          id: map['id'] as String? ?? '',
          kind: _enumByName(YlTrackKind.values, map['kind'], fallbackKind),
          label: map['label'] as String?,
          language: map['language'] as String?,
          codec: map['codec'] as String?,
          bitrate: _int(map['bitrate']),
          width: _int(map['width']),
          height: _int(map['height']),
          isSelected: map['isSelected'] == true,
        );
      })
      .toList(growable: false);
}

YlPlayerCapabilities? _decodeCapabilities(Object? value) {
  if (value is! Map) {
    return null;
  }
  final map = _stringMap(value);
  final codecs = map['hardwareVideoCodecs'];
  final formats = map['supportedFormats'];
  return YlPlayerCapabilities(
    hardwareVideoCodecs: codecs is List
        ? codecs.whereType<String>().toSet()
        : const <String>{},
    supportedFormats: formats is List
        ? formats
              .map(
                (name) => _enumByName(
                  YlFormatHint.values,
                  name,
                  YlFormatHint.automatic,
                ),
              )
              .toSet()
        : const <YlFormatHint>{},
    maxConcurrentVideoDecoders: _int(map['maxConcurrentVideoDecoders']) ?? 1,
    maxWidth: _int(map['maxWidth']),
    maxHeight: _int(map['maxHeight']),
  );
}

YlPlaybackMetrics _decodeMetrics(Object? value) {
  final map = _stringMap(value);
  Duration? nullableDuration(String key) {
    final milliseconds = _int(map[key]);
    return milliseconds == null ? null : Duration(milliseconds: milliseconds);
  }

  return YlPlaybackMetrics(
    openDuration: nullableDuration('openDurationMs'),
    firstFrameDuration: nullableDuration('firstFrameDurationMs'),
    rebufferCount: _int(map['rebufferCount']) ?? 0,
    rebufferDuration: Duration(
      milliseconds: _int(map['rebufferDurationMs']) ?? 0,
    ),
    droppedVideoFrames: _int(map['droppedVideoFrames']) ?? 0,
    audioUnderruns: _int(map['audioUnderruns']) ?? 0,
    estimatedBitrate: _int(map['estimatedBitrate']),
    bufferedDuration: Duration(
      milliseconds: _int(map['bufferedDurationMs']) ?? 0,
    ),
    bufferedBytes: _int(map['bufferedBytes']) ?? 0,
    liveOffset: nullableDuration('liveOffsetMs'),
    reconnectCount: _int(map['reconnectCount']) ?? 0,
    androidDeviceTier: map['androidDeviceTier'] as String?,
    targetBufferBytes: _int(map['targetBufferBytes']),
    adaptiveDowngradeCount: _int(map['adaptiveDowngradeCount']),
    surfaceRebuildCount: _int(map['surfaceRebuildCount']),
    selectedVideoBitrate: _int(map['selectedVideoBitrate']),
  );
}
