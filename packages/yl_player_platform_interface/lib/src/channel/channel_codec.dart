import 'package:flutter/services.dart';

import '../capabilities.dart';
import '../configuration.dart';
import '../media_source.dart';
import '../media_track.dart';
import '../playback_metrics.dart';
import '../player_error.dart';
import '../player_event.dart';
import '../player_state.dart';

const int ylChannelProtocolVersion = 1;

/// Stable wire keys used by both endorsed native implementations.
abstract final class YlChannelWireKeys {
  static const String protocolVersion = 'protocolVersion';
  static const String generation = 'generation';
  static const String type = 'type';
  static const String state = 'state';
  static const String delta = 'delta';
  static const String stateDelta = 'stateDelta';
  static const String droppedVideoFrames = 'droppedVideoFrames';
}

Map<String, Object?> encodeYlConfiguration(
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

Map<String, Object?> encodeYlSource(YlMediaSource source) => <String, Object?>{
  'uri': source.uri.toString(),
  'kind': source.kind.name,
  'isLive': source.isLive,
  'formatHint': source.formatHint.name,
  'headers': source.headers,
};

Map<String, Object?> encodeYlQualityConstraint(
  YlQualityConstraint constraint,
) => <String, Object?>{
  'maxWidth': constraint.maxWidth,
  'maxHeight': constraint.maxHeight,
  'maxBitrate': constraint.maxBitrate,
};

YlPlayerState decodeYlState(Object? value) {
  final map = ylStringMap(value);
  final width = _positiveInt(map['videoWidth']);
  final height = _positiveInt(map['videoHeight']);
  final durationMs = _nonnegativeInt(map['durationMs']);
  final liveOffsetMs = _nonnegativeInt(map['liveOffsetMs']);
  final dvrStartMs = _nonnegativeInt(map['dvrStartMs']);
  final dvrEndMs = _nonnegativeInt(map['dvrEndMs']);
  final hasValidDvr =
      dvrStartMs != null && dvrEndMs != null && dvrEndMs >= dvrStartMs;
  return YlPlayerState(
    status: _enumByName(
      YlPlaybackStatus.values,
      map['status'],
      YlPlaybackStatus.idle,
    ),
    position: Duration(milliseconds: _nonnegativeInt(map['positionMs']) ?? 0),
    duration: durationMs == null ? null : Duration(milliseconds: durationMs),
    bufferedPosition: Duration(
      milliseconds: _nonnegativeInt(map['bufferedPositionMs']) ?? 0,
    ),
    isLive: map['isLive'] == true,
    isSeekable: map['isSeekable'] == true,
    isAtLiveEdge: map['isAtLiveEdge'] == true,
    liveOffset: liveOffsetMs == null
        ? null
        : Duration(milliseconds: liveOffsetMs),
    dvrWindow: hasValidDvr
        ? YlDvrWindow(
            start: Duration(milliseconds: dvrStartMs),
            end: Duration(milliseconds: dvrEndMs),
          )
        : null,
    videoSize: width == null || height == null
        ? null
        : YlVideoSize(width, height),
    engine: _enumByName(
      YlPlaybackEngine.values,
      map['engine'],
      YlPlaybackEngine.unknown,
    ),
    isHardwareDecoding: map['isHardwareDecoding'] == true,
    decoderName: _string(map['decoderName']),
    audioTracks: _decodeTracks(map['audioTracks'], YlTrackKind.audio),
    videoTracks: _decodeTracks(map['videoTracks'], YlTrackKind.video),
    capabilities: _decodeCapabilities(map['capabilities']),
    metrics: _decodeMetrics(map['metrics']),
    error: map['error'] == null ? null : decodeYlError(map['error']),
  );
}

YlPlayerState mergeYlStateDelta(YlPlayerState current, Object? value) {
  final map = ylStringMap(value);
  final positionMs = _nonnegativeInt(map['positionMs']);
  final bufferedPositionMs = _nonnegativeInt(map['bufferedPositionMs']);
  final hasLiveOffset = map.containsKey('liveOffsetMs');
  final liveOffsetMs = _nonnegativeInt(map['liveOffsetMs']);
  return current.copyWith(
    position: positionMs == null
        ? current.position
        : Duration(milliseconds: positionMs),
    bufferedPosition: bufferedPositionMs == null
        ? current.bufferedPosition
        : Duration(milliseconds: bufferedPositionMs),
    isAtLiveEdge: map['isAtLiveEdge'] is bool
        ? map['isAtLiveEdge']! as bool
        : current.isAtLiveEdge,
    liveOffset: hasLiveOffset
        ? liveOffsetMs == null
              ? null
              : Duration(milliseconds: liveOffsetMs)
        : current.liveOffset,
    metrics: map['metrics'] is Map
        ? _decodeMetrics(map['metrics'], base: current.metrics)
        : current.metrics,
  );
}

YlPlayerEvent? decodeYlEvent(Map<String, Object?> envelope) {
  switch (envelope[YlChannelWireKeys.type]) {
    case 'firstFrame':
      return YlFirstFrameEvent(
        width: _positiveInt(envelope['width']),
        height: _positiveInt(envelope['height']),
      );
    case 'error':
      return YlErrorEvent(decodeYlError(envelope['error']));
    case 'tracksChanged':
      return YlTracksChangedEvent(
        audioTracks: _decodeTracks(envelope['audioTracks'], YlTrackKind.audio),
        videoTracks: _decodeTracks(envelope['videoTracks'], YlTrackKind.video),
      );
    case 'retry':
      return YlRetryEvent(
        attempt: _nonnegativeInt(envelope['attempt']) ?? 0,
        delay: Duration(
          milliseconds: _nonnegativeInt(envelope['delayMs']) ?? 0,
        ),
        error: decodeYlError(envelope['error']),
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
        reason: decodeYlError(envelope['error']),
      );
  }
  return null;
}

YlPlayerError decodeYlError(Object? value) {
  final map = ylStringMap(value);
  return YlPlayerError(
    category: _enumByName(
      YlPlayerErrorCategory.values,
      map['category'],
      YlPlayerErrorCategory.internal,
    ),
    code: _string(map['code']) ?? 'platform.unknown',
    message: _string(map['message']) ?? 'Native playback failed.',
    platformDiagnostic: _string(map['platformDiagnostic']),
  );
}

YlPlayerError decodeYlPlatformException(
  PlatformException exception, {
  required String platform,
}) {
  if (exception.details is Map) {
    return decodeYlError(exception.details);
  }
  return YlPlayerError(
    category: YlPlayerErrorCategory.internal,
    code: exception.code.isEmpty ? '$platform.platform_error' : exception.code,
    message: exception.message ?? 'Native playback failed.',
    platformDiagnostic: exception.details?.toString(),
  );
}

Map<String, Object?> ylStringMap(Object? value) {
  if (value is! Map) {
    return const <String, Object?>{};
  }
  return value.map<String, Object?>((key, item) => MapEntry('$key', item));
}

int? _int(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is double && value.isFinite) {
    return value.toInt();
  }
  return null;
}

int? _nonnegativeInt(Object? value) {
  final decoded = _int(value);
  return decoded != null && decoded >= 0 ? decoded : null;
}

int? _positiveInt(Object? value) {
  final decoded = _int(value);
  return decoded != null && decoded > 0 ? decoded : null;
}

String? _string(Object? value) => value is String ? value : null;

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
      .whereType<Map>()
      .map((item) {
        final map = ylStringMap(item);
        return YlMediaTrack(
          id: _string(map['id']) ?? '',
          kind: _enumByName(YlTrackKind.values, map['kind'], fallbackKind),
          label: _string(map['label']),
          language: _string(map['language']),
          codec: _string(map['codec']),
          bitrate: _positiveInt(map['bitrate']),
          width: _positiveInt(map['width']),
          height: _positiveInt(map['height']),
          isSelected: map['isSelected'] == true,
        );
      })
      .toList(growable: false);
}

YlPlayerCapabilities? _decodeCapabilities(Object? value) {
  if (value is! Map) {
    return null;
  }
  final map = ylStringMap(value);
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
    maxConcurrentVideoDecoders:
        _positiveInt(map['maxConcurrentVideoDecoders']) ?? 1,
    maxWidth: _positiveInt(map['maxWidth']),
    maxHeight: _positiveInt(map['maxHeight']),
  );
}

YlPlaybackMetrics _decodeMetrics(
  Object? value, {
  YlPlaybackMetrics base = const YlPlaybackMetrics(),
}) {
  final map = ylStringMap(value);
  Duration? nullableDuration(String key, Duration? current) {
    if (!map.containsKey(key)) {
      return current;
    }
    final milliseconds = _nonnegativeInt(map[key]);
    return milliseconds == null ? null : Duration(milliseconds: milliseconds);
  }

  int? nullableInt(String key, int? current) {
    if (!map.containsKey(key)) {
      return current;
    }
    return _nonnegativeInt(map[key]);
  }

  String? nullableString(String key, String? current) {
    if (!map.containsKey(key)) {
      return current;
    }
    return _string(map[key]);
  }

  return base.copyWith(
    openDuration: nullableDuration('openDurationMs', base.openDuration),
    firstFrameDuration: nullableDuration(
      'firstFrameDurationMs',
      base.firstFrameDuration,
    ),
    rebufferCount: _nonnegativeInt(map['rebufferCount']),
    rebufferDuration:
        nullableDuration('rebufferDurationMs', base.rebufferDuration) ??
        base.rebufferDuration,
    droppedVideoFrames: _nonnegativeInt(
      map[YlChannelWireKeys.droppedVideoFrames],
    ),
    audioUnderruns: _nonnegativeInt(map['audioUnderruns']),
    estimatedBitrate: nullableInt('estimatedBitrate', base.estimatedBitrate),
    bufferedDuration:
        nullableDuration('bufferedDurationMs', base.bufferedDuration) ??
        base.bufferedDuration,
    bufferedBytes: _nonnegativeInt(map['bufferedBytes']),
    liveOffset: nullableDuration('liveOffsetMs', base.liveOffset),
    reconnectCount: _nonnegativeInt(map['reconnectCount']),
    androidDeviceTier: nullableString(
      'androidDeviceTier',
      base.androidDeviceTier,
    ),
    targetBufferBytes: nullableInt('targetBufferBytes', base.targetBufferBytes),
    adaptiveDowngradeCount: nullableInt(
      'adaptiveDowngradeCount',
      base.adaptiveDowngradeCount,
    ),
    surfaceRebuildCount: nullableInt(
      'surfaceRebuildCount',
      base.surfaceRebuildCount,
    ),
    selectedVideoBitrate: nullableInt(
      'selectedVideoBitrate',
      base.selectedVideoBitrate,
    ),
  );
}
