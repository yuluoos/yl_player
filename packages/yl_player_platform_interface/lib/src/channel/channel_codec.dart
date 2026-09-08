import 'package:flutter/services.dart';
import '../../yl_player_platform_interface.dart';

const int ylChannelProtocolVersion = 1;

Map<String, Object?> encodeYlOptions(YlPlayerOptions options) => {
  'audioPolicy': options.audioPolicy.name,
  'decoderPolicy': options.decoderPolicy.name,
  'positionEventIntervalMs': options.positionUpdateInterval.inMilliseconds,
};
Map<String, Object?> encodeYlSource(YlMediaSource source) => {
  'uri': switch (source) {
    YlFileSource(:final path) => Uri.file(path).toString(),
    YlNetworkSource(:final uri) ||
    YlAndroidContentSource(:final uri) => uri.toString(),
  },
  'kind': source is YlFileSource
      ? 'file'
      : source is YlAndroidContentSource
      ? 'content'
      : 'network',
  'isLive': source.intent == YlStreamIntent.live,
  'formatHint': source.format.name,
  if (source is YlNetworkSource) 'headers': source.request.headers,
  if (source is YlNetworkSource) 'credentials': source.request.credentials,
};
Map<String, Object?> encodeYlVideoConstraints(YlVideoConstraints value) => {
  'maxWidth': ?value.maxWidth,
  'maxHeight': ?value.maxHeight,
  'maxBitrate': ?value.maxBitrate,
};
Map<String, Object?> encodeYlLoadOptions(YlLoadOptions value) => {
  'autoplay': value.autoplay,
  'startPositionMs': value.startPosition?.inMilliseconds,
  'videoConstraints': encodeYlVideoConstraints(value.videoConstraints),
  'bufferStrategy': value.bufferStrategy.kind.name,
  'decoderPolicy': value.decoderPolicyOverride?.name,
};

YlPlayerState decodeYlState(
  Object? value, {
  required YlPlaybackSessionId? sessionId,
  required int revision,
}) {
  final map = ylStringMap(value);
  final status = map['status'] == 'opening'
      ? YlPlaybackStatus.loading
      : map['status'] == 'error'
      ? YlPlaybackStatus.failed
      : _enum(YlPlaybackStatus.values, map['status'], YlPlaybackStatus.idle);
  final width = _positive(map['videoWidth']);
  final height = _positive(map['videoHeight']);
  final start = _duration(map['dvrStartMs']);
  final end = _duration(map['dvrEndMs']);
  final size = width != null && height != null
      ? YlPixelSize(width.toDouble(), height.toDouble())
      : null;
  final result = YlPlayerState(
    revision: revision,
    sessionId: status == YlPlaybackStatus.idle ? null : sessionId,
    status: status,
    timeline: YlTimeline(
      position: _duration(map['positionMs']) ?? Duration.zero,
      bufferedPosition: _duration(map['bufferedPositionMs']) ?? Duration.zero,
      duration: _duration(map['durationMs']),
      liveOffset: _duration(map['liveOffsetMs'], clamp: true),
      isLive: map['isLive'] == true,
      isSeekable: map['isSeekable'] == true,
      isAtLiveEdge: map['isAtLiveEdge'] as bool?,
      dvrWindow: start != null && end != null && end >= start
          ? YlDvrWindow(start: start, end: end)
          : null,
    ),
    videoGeometry: size == null
        ? null
        : YlVideoGeometry(encodedSize: size, displaySize: size),
    engine: map['engine'] == 'nativeFallback'
        ? YlPlaybackEngine.managedFallback
        : _enum(
            YlPlaybackEngine.values,
            map['engine'],
            YlPlaybackEngine.unknown,
          ),
    // Legacy booleans/codec-name heuristics carry no initialized-decoder proof.
    decoderMode: YlDecoderMode.unknown,
    decoderIdentity: map['decoderName'] is String
        ? YlSafeDiagnostics.publicMessage(map['decoderName'] as String)
        : null,
    audioTracks: _tracks(map['audioTracks'], YlTrackKind.audio),
    videoTracks: _tracks(map['videoTracks'], YlTrackKind.video),
    metrics: _metrics(map['metrics']),
    failure: status == YlPlaybackStatus.failed
        ? decodeYlFailure(
            map['error'],
            scope: sessionId == null
                ? YlFailureScope.player
                : YlFailureScope.session,
          )
        : null,
  );
  validateYlPlayerState(result);
  return result;
}

YlPlayerState mergeYlStateDelta(
  YlPlayerState state,
  Object? value, {
  required int revision,
}) {
  final map = ylStringMap(value);
  final result = state.copyWith(
    revision: revision,
    timeline: state.timeline.copyWith(
      position: _duration(map['positionMs']),
      bufferedPosition: _duration(map['bufferedPositionMs']),
      liveOffset: map.containsKey('liveOffsetMs')
          ? _duration(map['liveOffsetMs'], clamp: true)
          : state.timeline.liveOffset,
      isAtLiveEdge: map.containsKey('isAtLiveEdge')
          ? map['isAtLiveEdge']
          : state.timeline.isAtLiveEdge,
    ),
    metrics: _metrics(map['metrics'], state.metrics),
  );
  validateYlPlayerState(result);
  return result;
}

YlPlayerCapabilities decodeYlCapabilities(
  Object? value, {
  required String platform,
  required YlPlaybackEngine initialEngine,
}) {
  if (value is! Map) {
    throw legacyException(
      YlFailureCodes.protocolMismatch,
      scope: YlFailureScope.player,
    );
  }
  final map = ylStringMap(value);
  return YlPlayerCapabilities(
    deviceProfile: 'legacy.$platform',
    availableEngines: [
      initialEngine,
      if (platform != 'android') YlPlaybackEngine.managedFallback,
    ],
    supportedOperations: YlPlayerOperation.values,
    maxConcurrentVideoDecoders: _positive(map['maxConcurrentVideoDecoders']),
    maxWidth: _positive(map['maxWidth']),
    maxHeight: _positive(map['maxHeight']),
  );
}

int _diagnosticSerial = 0;
YlPlayerException legacyException(
  String code, {
  YlFailureScope scope = YlFailureScope.command,
}) => YlPlayerException(
  YlFailure(
    category: code.startsWith('decoder.')
        ? YlFailureCategory.decoder
        : code.startsWith('network.')
        ? YlFailureCategory.network
        : code.startsWith('container.')
        ? YlFailureCategory.container
        : code == YlFailureCodes.policyUnsupported
        ? YlFailureCategory.unsupported
        : code == YlFailureCodes.protocolMismatch
        ? YlFailureCategory.protocol
        : code == YlFailureCodes.loadCancelled
        ? YlFailureCategory.cancelled
        : YlFailureCategory.platform,
    code: code,
    message: 'Playback operation failed.',
    retryable: false,
    scope: scope,
    diagnosticId: 'legacy-${++_diagnosticSerial}',
  ),
);
YlFailure decodeYlFailure(
  Object? value, {
  YlFailureScope scope = YlFailureScope.session,
}) {
  final map = ylStringMap(value);
  // Never copy native messages, arbitrary codes, diagnostics, paths or stacks.
  final code = switch (map['code']) {
    'decoder.video_hardware_unavailable' ||
    'decoder.unavailable' => YlFailureCodes.decoderUnavailable,
    'decoder.unsupported' => YlFailureCodes.decoderUnsupported,
    'network.failed' => YlFailureCodes.networkFailed,
    'network.range_not_supported' => 'network.range_not_supported',
    'network.http_status' => 'network.http_status',
    'container.network_mkv_live_unsupported' =>
      'container.network_mkv_live_unsupported',
    'source.missing' => YlFailureCodes.sourceMissing,
    'source.invalid' => YlFailureCodes.sourceInvalid,
    'container.unsupported' => YlFailureCodes.containerUnsupported,
    'load.cancelled' => YlFailureCodes.loadCancelled,
    _ => YlFailureCodes.platformFailure,
  };
  final base = legacyException(code, scope: scope).failure;
  final category = switch (map['category']) {
    'network' => YlFailureCategory.network,
    'source' => YlFailureCategory.source,
    'container' => YlFailureCategory.container,
    'decoder' || 'decoderUnsupported' => YlFailureCategory.decoder,
    'resource' => YlFailureCategory.resource,
    _ => base.category,
  };
  return YlFailure(
    category: category,
    code: base.code,
    message: base.message,
    retryable: base.retryable,
    scope: scope,
    diagnosticId: base.diagnosticId,
  );
}

YlPlayerException decodeYlPlatformException(PlatformException error) =>
    YlPlayerException(
      decodeYlFailure(
        error.details is Map ? error.details : {'code': error.code},
        scope: YlFailureScope.command,
      ),
    );
Map<String, Object?> ylStringMap(Object? value) => value is Map
    ? Map.fromEntries(
        value.entries
            .where((entry) => entry.key is String)
            .map((entry) => MapEntry(entry.key as String, entry.value)),
      )
    : {};
int? ylWireInt(Object? value) =>
    value is int && value >= 0 && value <= 0x7fffffffffffffff ? value : null;
int? _positive(Object? value) {
  final n = ylWireInt(value);
  return n != null && n > 0 ? n : null;
}

Duration? _duration(Object? value, {bool clamp = false}) {
  if (clamp && value is int && value < 0) return Duration.zero;
  final n = ylWireInt(value);
  if (n == null || n > 0x7fffffffffffffff ~/ 1000) return null;
  return Duration(milliseconds: n);
}

T _enum<T extends Enum>(List<T> values, Object? name, T fallback) =>
    values.where((v) => v.name == name).firstOrNull ?? fallback;
List<YlMediaTrack> _tracks(Object? value, YlTrackKind kind) => value is List
    ? value
          .whereType<Map>()
          .map(
            (item) => YlMediaTrack(
              id: item['id'] as String,
              kind: kind,
              label: item['label'] as String?,
              language: item['language'] as String?,
              codec: item['codec'] as String?,
              isSelected: item['isSelected'] == true,
              bitrate: _positive(item['bitrate']),
              width: _positive(item['width']),
              height: _positive(item['height']),
            ),
          )
          .toList()
    : [];
YlPlaybackMetrics _metrics(
  Object? value, [
  YlPlaybackMetrics base = const YlPlaybackMetrics(),
]) {
  final map = ylStringMap(value);
  Duration? time(String key, Duration? old) =>
      map.containsKey(key) ? _duration(map[key]) : old;
  int? count(String key, int? old) =>
      map.containsKey(key) ? ylWireInt(map[key]) : old;
  return YlPlaybackMetrics(
    loadToReady: time('openDurationMs', base.loadToReady),
    loadToFirstFrame: time('firstFrameDurationMs', base.loadToFirstFrame),
    rebufferCount: count('rebufferCount', base.rebufferCount),
    rebufferDuration: time('rebufferDurationMs', base.rebufferDuration),
    droppedVideoFrames: count('droppedVideoFrames', base.droppedVideoFrames),
    audioUnderruns: count('audioUnderruns', base.audioUnderruns),
    estimatedBitrate: count('estimatedBitrate', base.estimatedBitrate),
    liveOffset: time('liveOffsetMs', base.liveOffset),
    reconnectCount: count('reconnectCount', base.reconnectCount),
  );
}
