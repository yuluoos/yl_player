import 'package:flutter/services.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'pigeon/yl_player_android.g.dart';

/// The schema boundary. Generated values never escape this package.
abstract final class AndroidCodec {
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

  static YlFailure failure(AndroidFailureMessage value) => YlFailure(
    category: _category(value.category),
    code: _safe(value.code) ? value.code : YlFailureCodes.platformFailure,
    message: 'Playback operation failed.',
    retryable: value.retryable,
    scope: _scope(value.scope),
    diagnosticId: _safe(value.diagnosticId)
        ? value.diagnosticId
        : 'android-native-failure',
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
      diagnosticId: 'android-adapter',
    ),
  );

  static YlPlayerException exception(Object error) {
    if (error is YlPlayerException) return error;
    if (error is PlatformException) {
      final details = error.details;
      if (details is AndroidFailureMessage) {
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

  static AndroidPlayerOptionsMessage playerOptions(YlPlayerOptions value) {
    validateYlPlayerOptions(value);
    return AndroidPlayerOptionsMessage(
      decoderPolicy: _decoderPolicy(value.decoderPolicy),
      audioPolicy: _audioPolicy(value.audioPolicy),
      positionUpdateIntervalMs: value.positionUpdateInterval.inMilliseconds,
    );
  }

  static AndroidVideoConstraintsMessage constraints(YlVideoConstraints value) {
    validateYlVideoConstraints(value);
    return AndroidVideoConstraintsMessage(
      maxWidth: value.maxWidth,
      maxHeight: value.maxHeight,
      maxBitrate: value.maxBitrate,
    );
  }

  static AndroidSourceMessage source(YlMediaSource value) {
    validateYlSource(value);
    final commonIntent = _intent(value.intent);
    final commonFormat = _format(value.format);
    return switch (value) {
      YlFileSource() => AndroidSourceMessage(
        kind: AndroidSourceKind.file,
        locator: value.path,
        intent: commonIntent,
        format: commonFormat,
      ),
      YlAndroidContentSource() => AndroidSourceMessage(
        kind: AndroidSourceKind.content,
        locator: value.uri.toString(),
        intent: commonIntent,
        format: commonFormat,
      ),
      YlNetworkSource() => AndroidSourceMessage(
        kind: AndroidSourceKind.network,
        locator: value.uri.toString(),
        intent: commonIntent,
        format: commonFormat,
        request: AndroidHttpRequestMessage(
          headers: Map.of(value.request.headers),
          credentials: Map.of(value.request.credentials),
        ),
        networkPolicy: AndroidNetworkPolicyMessage(
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

  static AndroidLoadOptionsMessage loadOptions(YlLoadOptions value) {
    validateYlLoadOptions(value);
    return AndroidLoadOptionsMessage(
      autoplay: value.autoplay,
      startPositionMs: value.startPosition?.inMilliseconds,
      bufferStrategy: AndroidBufferStrategyMessage(
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

  static YlPlayerCapabilities capabilities(AndroidCapabilitiesMessage value) =>
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

  static YlSourceAssessment assessment(AndroidAssessmentReply value) =>
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

  static YlMediaTrack track(AndroidTrackMessage value) {
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

  static YlPlaybackMetrics metrics(AndroidMetricsMessage value) {
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
      mediaClockPosition: _time(value.mediaClockPositionMs),
    );
    validateYlPlaybackMetrics(result);
    return result;
  }

  static YlPlayerState state(AndroidStateMessage value) {
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
      decoderMode: _decoderMode(value.decoderMode),
      decoderIdentity: value.decoderIdentity,
      metrics: metrics(value.metrics),
      failure: value.failure == null ? null : failure(value.failure!),
    );
    validateYlPlayerState(result);
    return result;
  }

  static void deltaIdentity(AndroidStateDeltaMessage value) {
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
    AndroidStateDeltaMessage value,
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
              mediaClockPosition: changed.hasMediaClockPositionMs
                  ? _time(changed.mediaClockPositionMs)
                  : old.mediaClockPosition,
              reconnectCount: changed.hasReconnectCount
                  ? changed.reconnectCount
                  : old.reconnectCount,
            ),
    );
    validateYlPlayerState(result);
    return result;
  }

  static AndroidDecoderPolicy _decoderPolicy(
    YlDecoderPolicy value,
  ) => switch (value) {
    YlDecoderPolicy.systemDefault => AndroidDecoderPolicy.systemDefault,
    YlDecoderPolicy.hardwarePreferred => AndroidDecoderPolicy.hardwarePreferred,
    YlDecoderPolicy.hardwareRequired => AndroidDecoderPolicy.hardwareRequired,
  };

  static AndroidAudioPolicy _audioPolicy(YlAudioPolicy value) =>
      switch (value) {
        YlAudioPolicy.appManaged => AndroidAudioPolicy.appManaged,
        YlAudioPolicy.pluginManagedMediaPlayback =>
          AndroidAudioPolicy.pluginManagedMediaPlayback,
      };

  static AndroidStreamIntent _intent(YlStreamIntent value) => switch (value) {
    YlStreamIntent.automatic => AndroidStreamIntent.automatic,
    YlStreamIntent.onDemand => AndroidStreamIntent.onDemand,
    YlStreamIntent.live => AndroidStreamIntent.live,
  };

  static AndroidMediaFormat _format(YlMediaFormat value) => switch (value) {
    YlMediaFormat.automatic => AndroidMediaFormat.automatic,
    YlMediaFormat.hls => AndroidMediaFormat.hls,
    YlMediaFormat.mp4 => AndroidMediaFormat.mp4,
    YlMediaFormat.mov => AndroidMediaFormat.mov,
    YlMediaFormat.matroska => AndroidMediaFormat.matroska,
    YlMediaFormat.webm => AndroidMediaFormat.webm,
    YlMediaFormat.mpegTs => AndroidMediaFormat.mpegTs,
    YlMediaFormat.mpegPs => AndroidMediaFormat.mpegPs,
    YlMediaFormat.flv => AndroidMediaFormat.flv,
    YlMediaFormat.avi => AndroidMediaFormat.avi,
  };

  static AndroidNetworkPolicyKind _networkPolicy(YlNetworkPolicyKind value) =>
      switch (value) {
        YlNetworkPolicyKind.platformDefault =>
          AndroidNetworkPolicyKind.platformDefault,
        YlNetworkPolicyKind.managed => AndroidNetworkPolicyKind.managed,
      };

  static AndroidBufferKind _buffer(YlBufferStrategyKind value) =>
      switch (value) {
        YlBufferStrategyKind.automatic => AndroidBufferKind.automatic,
        YlBufferStrategyKind.lowLatency => AndroidBufferKind.lowLatency,
        YlBufferStrategyKind.smoothPlayback => AndroidBufferKind.smoothPlayback,
        YlBufferStrategyKind.bounded => AndroidBufferKind.bounded,
      };

  static YlPlaybackStatus _status(AndroidPlaybackStatus value) =>
      switch (value) {
        AndroidPlaybackStatus.idle => YlPlaybackStatus.idle,
        AndroidPlaybackStatus.loading => YlPlaybackStatus.loading,
        AndroidPlaybackStatus.ready => YlPlaybackStatus.ready,
        AndroidPlaybackStatus.playing => YlPlaybackStatus.playing,
        AndroidPlaybackStatus.paused => YlPlaybackStatus.paused,
        AndroidPlaybackStatus.buffering => YlPlaybackStatus.buffering,
        AndroidPlaybackStatus.completed => YlPlaybackStatus.completed,
        AndroidPlaybackStatus.failed => YlPlaybackStatus.failed,
      };

  static YlPlaybackEngine engine(AndroidEngine value) => switch (value) {
    AndroidEngine.unknown => YlPlaybackEngine.unknown,
    AndroidEngine.media3 => YlPlaybackEngine.media3,
    AndroidEngine.managedFallback => YlPlaybackEngine.managedFallback,
  };

  static YlDecoderMode _decoderMode(AndroidDecoderMode value) =>
      switch (value) {
        AndroidDecoderMode.unknown => YlDecoderMode.unknown,
        AndroidDecoderMode.hardware => YlDecoderMode.hardware,
        AndroidDecoderMode.software => YlDecoderMode.software,
      };

  static YlDecoderEvidence _evidence(AndroidDecoderEvidence value) =>
      switch (value) {
        AndroidDecoderEvidence.none => YlDecoderEvidence.none,
        AndroidDecoderEvidence.hardwareOnly => YlDecoderEvidence.hardwareOnly,
        AndroidDecoderEvidence.hardwareAndSoftware =>
          YlDecoderEvidence.hardwareAndSoftware,
      };

  static YlTrackKind _trackKind(AndroidTrackKind value) => switch (value) {
    AndroidTrackKind.audio => YlTrackKind.audio,
    AndroidTrackKind.video => YlTrackKind.video,
  };

  static YlPlayerOperation _operation(AndroidPlayerOperation value) =>
      switch (value) {
        AndroidPlayerOperation.seek => YlPlayerOperation.seek,
        AndroidPlayerOperation.seekToLiveEdge =>
          YlPlayerOperation.seekToLiveEdge,
        AndroidPlayerOperation.playbackSpeed => YlPlayerOperation.playbackSpeed,
        AndroidPlayerOperation.audioTrackSelection =>
          YlPlayerOperation.audioTrackSelection,
        AndroidPlayerOperation.videoConstraints =>
          YlPlayerOperation.videoConstraints,
        AndroidPlayerOperation.volume => YlPlayerOperation.volume,
        AndroidPlayerOperation.stop => YlPlayerOperation.stop,
      };

  static YlFailureCategory _category(AndroidFailureCategory value) =>
      switch (value) {
        AndroidFailureCategory.cancelled => YlFailureCategory.cancelled,
        AndroidFailureCategory.unsupported => YlFailureCategory.unsupported,
        AndroidFailureCategory.source => YlFailureCategory.source,
        AndroidFailureCategory.network => YlFailureCategory.network,
        AndroidFailureCategory.container => YlFailureCategory.container,
        AndroidFailureCategory.decoder => YlFailureCategory.decoder,
        AndroidFailureCategory.render => YlFailureCategory.render,
        AndroidFailureCategory.resource => YlFailureCategory.resource,
        AndroidFailureCategory.protocol => YlFailureCategory.protocol,
        AndroidFailureCategory.platform => YlFailureCategory.platform,
        AndroidFailureCategory.internal => YlFailureCategory.internal,
      };

  static YlFailureScope _scope(AndroidFailureScope value) => switch (value) {
    AndroidFailureScope.command => YlFailureScope.command,
    AndroidFailureScope.session => YlFailureScope.session,
    AndroidFailureScope.player => YlFailureScope.player,
  };

  static YlSourceAssessmentOutcome _outcome(AndroidAssessmentOutcome value) =>
      switch (value) {
        AndroidAssessmentOutcome.compatible =>
          YlSourceAssessmentOutcome.compatible,
        AndroidAssessmentOutcome.incompatible =>
          YlSourceAssessmentOutcome.incompatible,
        AndroidAssessmentOutcome.requiresInspection =>
          YlSourceAssessmentOutcome.requiresInspection,
      };
}
