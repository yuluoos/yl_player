import 'package:flutter/services.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'pigeon/yl_player_apple.g.dart';

/// The schema boundary. Generated values never escape this package.
abstract final class AppleCodec {
  static const schemaMajor = 2;
  static const _maxDurationMs = 9223372036854775;
  static final _metadata = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

  static int integer(int value) {
    if (value < 0 || value > 0x7fffffffffffffff) {
      throw ArgumentError('Invalid native integer.');
    }
    return value;
  }

  static Duration milliseconds(int value, {bool liveOffset = false}) {
    if (liveOffset && value < 0) return Duration.zero;
    if (value < 0 || value > _maxDurationMs) {
      throw ArgumentError('Invalid native time.');
    }
    return Duration(milliseconds: value);
  }

  static Duration? _time(int? value, {bool liveOffset = false}) =>
      value == null ? null : milliseconds(value, liveOffset: liveOffset);

  static YlPlaybackSessionId session(String value) {
    final result = YlPlaybackSessionId(value);
    validateYlPlaybackSessionId(result);
    return result;
  }

  static bool _safe(String value) {
    final match = _metadata.firstMatch(value);
    return match != null && match.end == value.length;
  }

  static String _failureCode(String value) => switch (value) {
    'decoder.video_hardware_unavailable' => YlFailureCodes.decoderUnavailable,
    _ => _safe(value) ? value : YlFailureCodes.platformFailure,
  };

  static YlFailure failure(AppleFailureMessage value) => YlFailure(
    category: _category(value.category),
    code: _failureCode(value.code),
    message: 'Playback operation failed.',
    retryable: value.retryable,
    scope: _scope(value.scope),
    diagnosticId: _safe(value.diagnosticId)
        ? value.diagnosticId
        : 'apple-native-failure',
  );

  static YlPlayerException problem(
    String code, {
    YlFailureCategory category = YlFailureCategory.protocol,
    YlFailureScope scope = YlFailureScope.player,
  }) => YlPlayerException(
    YlFailure(
      category: category,
      code: code,
      message: 'Playback operation failed.',
      retryable: false,
      scope: scope,
      diagnosticId: 'apple-adapter',
    ),
  );

  static YlPlayerException exception(Object error) {
    if (error is YlPlayerException) return error;
    if (error is PlatformException) {
      final details = error.details;
      if (details is AppleFailureMessage) {
        return YlPlayerException(failure(details));
      }
      if (error.code == 'channel-error') {
        return problem(
          YlFailureCodes.platformUnavailable,
          category: YlFailureCategory.platform,
        );
      }
      if (error.code == 'null-error') {
        return problem(YlFailureCodes.protocolMismatch);
      }
    }
    return problem(
      YlFailureCodes.platformFailure,
      category: YlFailureCategory.platform,
    );
  }

  static ApplePlayerOptionsMessage playerOptions(YlPlayerOptions value) {
    validateYlPlayerOptions(value);
    return ApplePlayerOptionsMessage(
      decoderPolicy: _decoderPolicy(value.decoderPolicy),
      audioPolicy: _audioPolicy(value.audioPolicy),
      positionUpdateIntervalMs: value.positionUpdateInterval.inMilliseconds,
    );
  }

  static AppleVideoConstraintsMessage constraints(YlVideoConstraints value) {
    validateYlVideoConstraints(value);
    return AppleVideoConstraintsMessage(
      maxWidth: value.maxWidth,
      maxHeight: value.maxHeight,
      maxBitrate: value.maxBitrate,
    );
  }

  static AppleSourceMessage source(YlMediaSource value) {
    validateYlSource(value);
    final commonIntent = _intent(value.intent);
    final commonFormat = _format(value.format);
    return switch (value) {
      YlFileSource() => AppleSourceMessage(
        kind: AppleSourceKind.file,
        locator: value.path,
        intent: commonIntent,
        format: commonFormat,
      ),
      YlAndroidContentSource() => AppleSourceMessage(
        kind: AppleSourceKind.content,
        locator: value.uri.toString(),
        intent: commonIntent,
        format: commonFormat,
      ),
      YlNetworkSource() => AppleSourceMessage(
        kind: AppleSourceKind.network,
        locator: value.uri.toString(),
        intent: commonIntent,
        format: commonFormat,
        request: AppleHttpRequestMessage(
          headers: Map.of(value.request.headers),
          credentials: Map.of(value.request.credentials),
        ),
        networkPolicy: AppleNetworkPolicyMessage(
          kind: _networkPolicy(value.networkPolicy.kind),
          connectTimeoutMs: value.networkPolicy.connectTimeout?.inMilliseconds,
          readTimeoutMs: value.networkPolicy.readTimeout?.inMilliseconds,
          maxRetries: value.networkPolicy.maxRetries,
          baseRetryDelayMs: value.networkPolicy.baseRetryDelay?.inMilliseconds,
          maxRetryDelayMs: value.networkPolicy.maxRetryDelay?.inMilliseconds,
          maxRedirects: value.networkPolicy.maxRedirects,
        ),
      ),
    };
  }

  static AppleLoadOptionsMessage loadOptions(YlLoadOptions value) {
    validateYlLoadOptions(value);
    return AppleLoadOptionsMessage(
      autoplay: value.autoplay,
      startPositionMs: value.startPosition?.inMilliseconds,
      bufferStrategy: AppleBufferStrategyMessage(
        kind: _buffer(value.bufferStrategy.kind),
        minDurationMs: value.bufferStrategy.minDuration?.inMilliseconds,
        maxDurationMs: value.bufferStrategy.maxDuration?.inMilliseconds,
        maxManagedBytes: value.bufferStrategy.maxManagedBytes,
      ),
      videoConstraints: constraints(value.videoConstraints),
      decoderPolicyOverride: value.decoderPolicyOverride == null
          ? null
          : _decoderPolicy(value.decoderPolicyOverride!),
    );
  }

  static YlPlayerCapabilities capabilities(AppleCapabilitiesMessage value) =>
      YlPlayerCapabilities(
        deviceProfile: value.deviceProfile,
        availableEngines: value.availableEngines.map(engine).toList(),
        decoderEvidence: _evidence(value.decoderEvidence),
        hardwareVideoCodecs: value.hardwareVideoCodecs,
        supportedOperations: value.supportedOperations.map(_operation).toList(),
        maxConcurrentVideoDecoders: value.maxConcurrentVideoDecoders,
        maxWidth: value.maxWidth,
        maxHeight: value.maxHeight,
      );

  static YlSourceAssessment assessment(AppleAssessmentReply value) =>
      YlSourceAssessment(
        outcome: _outcome(value.outcome),
        candidateEngine: value.candidateEngine == null
            ? null
            : engine(value.candidateEngine!),
        satisfiedRequirements: value.satisfiedRequirements
            .map(YlRequirementId.new)
            .toList(),
        limitations: value.limitations.map(YlLimitationId.new).toList(),
        rejection: value.rejection == null ? null : failure(value.rejection!),
      );

  static YlMediaTrack track(AppleTrackMessage value) {
    final result = YlMediaTrack(
      id: value.id,
      kind: _trackKind(value.kind),
      label: value.label,
      language: value.language,
      codec: value.codec,
      bitrate: value.bitrate,
      width: value.width,
      height: value.height,
      isSelected: value.isSelected,
    );
    validateYlMediaTrack(result);
    return result;
  }

  static YlPlaybackMetrics metrics(AppleMetricsMessage value) {
    final result = YlPlaybackMetrics(
      loadToReady: _time(value.loadToReadyMs),
      loadToFirstFrame: _time(value.loadToFirstFrameMs),
      rebufferCount: value.rebufferCount,
      rebufferDuration: _time(value.rebufferDurationMs),
      droppedVideoFrames: value.droppedVideoFrames,
      audioUnderruns: value.audioUnderruns,
      estimatedBitrate: value.estimatedBitrate,
      managedBufferedDuration: _time(value.managedBufferedDurationMs),
      managedBufferedBytes: value.managedBufferedBytes,
      liveOffset: _time(value.liveOffsetMs, liveOffset: true),
      reconnectCount: value.reconnectCount,
    );
    validateYlPlaybackMetrics(result);
    return result;
  }

  static YlPlayerState state(AppleStateMessage value) {
    integer(value.sequence);
    if ((value.sessionId == null) != (value.loadRequestId == null) ||
        value.loadRequestId != null && value.loadRequestId!.isEmpty) {
      throw ArgumentError('Invalid native Load request identity.');
    }
    final rawTimeline = value.timeline;
    final geometry = value.geometry;
    final result = YlPlayerState(
      revision: integer(value.revision),
      sessionId: value.sessionId == null ? null : session(value.sessionId!),
      status: _status(value.status),
      timeline: YlTimeline(
        position: milliseconds(rawTimeline.positionMs),
        duration: _time(rawTimeline.durationMs),
        bufferedPosition: milliseconds(rawTimeline.bufferedPositionMs),
        isSeekable: rawTimeline.isSeekable,
        isLive: rawTimeline.isLive,
        isAtLiveEdge: rawTimeline.isAtLiveEdge,
        liveOffset: _time(rawTimeline.liveOffsetMs, liveOffset: true),
        dvrWindow: rawTimeline.dvrWindow == null
            ? null
            : YlDvrWindow(
                start: milliseconds(rawTimeline.dvrWindow!.startMs),
                end: milliseconds(rawTimeline.dvrWindow!.endMs),
              ),
      ),
      videoGeometry: geometry == null
          ? null
          : YlVideoGeometry(
              encodedSize: YlPixelSize(
                geometry.encodedSize.width,
                geometry.encodedSize.height,
              ),
              displaySize: YlPixelSize(
                geometry.displaySize.width,
                geometry.displaySize.height,
              ),
              pixelAspectRatio: geometry.pixelAspectRatio,
              rotationDegrees: geometry.rotationDegrees,
            ),
      audioTracks: value.audioTracks.map(track).toList(),
      videoTracks: value.videoTracks.map(track).toList(),
      engine: engine(value.engine),
      decoderMode: value.engine == AppleEngine.avPlayer
          ? YlDecoderMode.unknown
          : _decoderMode(value.decoderMode),
      decoderIdentity: value.decoderIdentity,
      metrics: metrics(value.metrics),
      failure: value.failure == null ? null : failure(value.failure!),
    );
    validateYlPlayerState(result);
    return result;
  }

  static void deltaIdentity(AppleStateDeltaMessage value) {
    session(value.sessionId);
    integer(value.previousRevision);
    integer(value.revision);
    integer(value.sequence);
    if (value.revision <= value.previousRevision) {
      throw ArgumentError('Invalid delta revision.');
    }
  }

  static YlPlayerState delta(
    YlPlayerState state,
    AppleStateDeltaMessage value,
  ) {
    deltaIdentity(value);
    final timeline = state.timeline;
    final old = state.metrics;
    final changed = value.metrics;
    final result = state.copyWith(
      revision: value.revision,
      timeline: timeline.copyWith(
        position: value.positionMs == null
            ? null
            : milliseconds(value.positionMs!),
        bufferedPosition: value.bufferedPositionMs == null
            ? null
            : milliseconds(value.bufferedPositionMs!),
        isAtLiveEdge: value.hasIsAtLiveEdge
            ? value.isAtLiveEdge
            : timeline.isAtLiveEdge,
        liveOffset: value.hasLiveOffsetMs
            ? _time(value.liveOffsetMs, liveOffset: true)
            : timeline.liveOffset,
      ),
      metrics: changed == null
          ? old
          : YlPlaybackMetrics(
              loadToReady: changed.hasLoadToReadyMs
                  ? _time(changed.loadToReadyMs)
                  : old.loadToReady,
              loadToFirstFrame: changed.hasLoadToFirstFrameMs
                  ? _time(changed.loadToFirstFrameMs)
                  : old.loadToFirstFrame,
              rebufferCount: changed.hasRebufferCount
                  ? changed.rebufferCount
                  : old.rebufferCount,
              rebufferDuration: changed.hasRebufferDurationMs
                  ? _time(changed.rebufferDurationMs)
                  : old.rebufferDuration,
              droppedVideoFrames: changed.hasDroppedVideoFrames
                  ? changed.droppedVideoFrames
                  : old.droppedVideoFrames,
              audioUnderruns: changed.hasAudioUnderruns
                  ? changed.audioUnderruns
                  : old.audioUnderruns,
              estimatedBitrate: changed.hasEstimatedBitrate
                  ? changed.estimatedBitrate
                  : old.estimatedBitrate,
              managedBufferedDuration: changed.hasManagedBufferedDurationMs
                  ? _time(changed.managedBufferedDurationMs)
                  : old.managedBufferedDuration,
              managedBufferedBytes: changed.hasManagedBufferedBytes
                  ? changed.managedBufferedBytes
                  : old.managedBufferedBytes,
              liveOffset: changed.hasLiveOffsetMs
                  ? _time(changed.liveOffsetMs, liveOffset: true)
                  : old.liveOffset,
              reconnectCount: changed.hasReconnectCount
                  ? changed.reconnectCount
                  : old.reconnectCount,
            ),
    );
    validateYlPlayerState(result);
    return result;
  }

  static AppleDecoderPolicy _decoderPolicy(YlDecoderPolicy value) =>
      switch (value) {
        YlDecoderPolicy.systemDefault => AppleDecoderPolicy.systemDefault,
        YlDecoderPolicy.hardwarePreferred =>
          AppleDecoderPolicy.hardwarePreferred,
        YlDecoderPolicy.hardwareRequired => AppleDecoderPolicy.hardwareRequired,
      };

  static AppleAudioPolicy _audioPolicy(YlAudioPolicy value) => switch (value) {
    YlAudioPolicy.appManaged => AppleAudioPolicy.appManaged,
    YlAudioPolicy.pluginManagedMediaPlayback =>
      AppleAudioPolicy.pluginManagedMediaPlayback,
  };

  static AppleStreamIntent _intent(YlStreamIntent value) => switch (value) {
    YlStreamIntent.automatic => AppleStreamIntent.automatic,
    YlStreamIntent.onDemand => AppleStreamIntent.onDemand,
    YlStreamIntent.live => AppleStreamIntent.live,
  };

  static AppleMediaFormat _format(YlMediaFormat value) => switch (value) {
    YlMediaFormat.automatic => AppleMediaFormat.automatic,
    YlMediaFormat.hls => AppleMediaFormat.hls,
    YlMediaFormat.mp4 => AppleMediaFormat.mp4,
    YlMediaFormat.mov => AppleMediaFormat.mov,
    YlMediaFormat.matroska => AppleMediaFormat.matroska,
    YlMediaFormat.webm => AppleMediaFormat.webm,
    YlMediaFormat.mpegTs => AppleMediaFormat.mpegTs,
    YlMediaFormat.mpegPs => AppleMediaFormat.mpegPs,
    YlMediaFormat.flv => AppleMediaFormat.flv,
    YlMediaFormat.avi => AppleMediaFormat.avi,
  };

  static AppleNetworkPolicyKind _networkPolicy(YlNetworkPolicyKind value) =>
      switch (value) {
        YlNetworkPolicyKind.platformDefault =>
          AppleNetworkPolicyKind.platformDefault,
        YlNetworkPolicyKind.managed => AppleNetworkPolicyKind.managed,
      };

  static AppleBufferKind _buffer(YlBufferStrategyKind value) => switch (value) {
    YlBufferStrategyKind.automatic => AppleBufferKind.automatic,
    YlBufferStrategyKind.lowLatency => AppleBufferKind.lowLatency,
    YlBufferStrategyKind.smoothPlayback => AppleBufferKind.smoothPlayback,
    YlBufferStrategyKind.bounded => AppleBufferKind.bounded,
  };

  static YlPlaybackStatus _status(ApplePlaybackStatus value) => switch (value) {
    ApplePlaybackStatus.idle => YlPlaybackStatus.idle,
    ApplePlaybackStatus.loading => YlPlaybackStatus.loading,
    ApplePlaybackStatus.ready => YlPlaybackStatus.ready,
    ApplePlaybackStatus.playing => YlPlaybackStatus.playing,
    ApplePlaybackStatus.paused => YlPlaybackStatus.paused,
    ApplePlaybackStatus.buffering => YlPlaybackStatus.buffering,
    ApplePlaybackStatus.completed => YlPlaybackStatus.completed,
    ApplePlaybackStatus.failed => YlPlaybackStatus.failed,
  };

  static YlPlaybackEngine engine(AppleEngine value) => switch (value) {
    AppleEngine.unknown => YlPlaybackEngine.unknown,
    AppleEngine.avPlayer => YlPlaybackEngine.avPlayer,
    AppleEngine.managedFallback => YlPlaybackEngine.managedFallback,
  };

  static YlDecoderMode _decoderMode(AppleDecoderMode value) => switch (value) {
    AppleDecoderMode.unknown => YlDecoderMode.unknown,
    AppleDecoderMode.hardware => YlDecoderMode.hardware,
    AppleDecoderMode.software => YlDecoderMode.software,
  };

  static YlDecoderEvidence _evidence(AppleDecoderEvidence value) =>
      switch (value) {
        AppleDecoderEvidence.none => YlDecoderEvidence.none,
        AppleDecoderEvidence.hardwareOnly => YlDecoderEvidence.hardwareOnly,
        AppleDecoderEvidence.hardwareAndSoftware =>
          YlDecoderEvidence.hardwareAndSoftware,
      };

  static YlTrackKind _trackKind(AppleTrackKind value) => switch (value) {
    AppleTrackKind.audio => YlTrackKind.audio,
    AppleTrackKind.video => YlTrackKind.video,
  };

  static YlPlayerOperation _operation(ApplePlayerOperation value) =>
      switch (value) {
        ApplePlayerOperation.seek => YlPlayerOperation.seek,
        ApplePlayerOperation.seekToLiveEdge => YlPlayerOperation.seekToLiveEdge,
        ApplePlayerOperation.playbackSpeed => YlPlayerOperation.playbackSpeed,
        ApplePlayerOperation.audioTrackSelection =>
          YlPlayerOperation.audioTrackSelection,
        ApplePlayerOperation.videoConstraints =>
          YlPlayerOperation.videoConstraints,
        ApplePlayerOperation.volume => YlPlayerOperation.volume,
        ApplePlayerOperation.stop => YlPlayerOperation.stop,
      };

  static YlFailureCategory _category(AppleFailureCategory value) =>
      switch (value) {
        AppleFailureCategory.cancelled => YlFailureCategory.cancelled,
        AppleFailureCategory.unsupported => YlFailureCategory.unsupported,
        AppleFailureCategory.source => YlFailureCategory.source,
        AppleFailureCategory.network => YlFailureCategory.network,
        AppleFailureCategory.container => YlFailureCategory.container,
        AppleFailureCategory.decoder => YlFailureCategory.decoder,
        AppleFailureCategory.render => YlFailureCategory.render,
        AppleFailureCategory.resource => YlFailureCategory.resource,
        AppleFailureCategory.protocolFailure => YlFailureCategory.protocol,
        AppleFailureCategory.platform => YlFailureCategory.platform,
        AppleFailureCategory.internalFailure => YlFailureCategory.internal,
      };

  static YlFailureScope _scope(AppleFailureScope value) => switch (value) {
    AppleFailureScope.command => YlFailureScope.command,
    AppleFailureScope.session => YlFailureScope.session,
    AppleFailureScope.player => YlFailureScope.player,
  };

  static YlSourceAssessmentOutcome _outcome(AppleAssessmentOutcome value) =>
      switch (value) {
        AppleAssessmentOutcome.compatible =>
          YlSourceAssessmentOutcome.compatible,
        AppleAssessmentOutcome.incompatible =>
          YlSourceAssessmentOutcome.incompatible,
        AppleAssessmentOutcome.requiresInspection =>
          YlSourceAssessmentOutcome.requiresInspection,
      };
}
