part of 'player_controller.dart';

/// A handle to one committed source. Replacement or Stop makes commands stale.
final class YlPlaybackSession {
  YlPlaybackSession._(this._player, this.id, this.ready, this.firstFrame);
  final YlPlayerController _player;
  final YlPlaybackSessionId id;
  final Future<void> ready;
  final Future<void> firstFrame;
  Future<void> _command(Future<void> Function() action) async {
    _player._checkSession(id);
    await action();
  }

  Future<void> play() => _command(() => _player._backend.play(id));
  Future<void> pause() => _command(() => _player._backend.pause(id));
  Future<void> seekTo(Duration position) => _command(() {
    validateYlSeekPosition(position);
    return _player._seekWithSubtitles(
      () => _player._backend.seekTo(id, position),
    );
  });
  Future<void> seekToLiveEdge() => _command(
    () => _player._seekWithSubtitles(() => _player._backend.seekToLiveEdge(id)),
  );
  Future<void> setPlaybackSpeed(double speed) => _command(() {
    validateYlPlaybackSpeed(speed);
    return _player._backend.setPlaybackSpeed(id, speed);
  });
  Future<void> selectAudioTrack(String trackId) => _command(() {
    validateYlTrackId(trackId);
    return _player._backend.selectAudioTrack(id, trackId);
  });

  /// Discovers supported text and PGS tracks in the committed file or HTTP(S)
  /// Matroska/WebM/MP4 source. Supported codecs depend on the container.
  /// Explicit Matroska/WebM format declarations must match the file DocType.
  /// Requires enableTextSubtitles. Discovery is atomic, preserves external
  /// entries and a still-present selection. New sessions start off.
  /// HTTP requires byte ranges and a stable strong ETag; source policy applies.
  /// Other containers reject without I/O.
  Future<void> discoverEmbeddedSubtitles() => _command(() {
    final runtime = _player._textSubtitles;
    final source = _player._subtitleSource;
    if (runtime == null || source == null) {
      throw _exception(YlFailureCodes.policyUnsupported);
    }
    return _textSubtitleCommand(() => runtime.discover(source));
  });

  /// Atomically replaces external subtitles; [] clears external entries.
  /// Backends without explicit support reject rather than ignoring resources.
  Future<void> replaceExternalSubtitles(List<YlExternalSubtitle> subtitles) =>
      _command(() {
        validateYlExternalSubtitles(subtitles);
        final snapshot = List<YlExternalSubtitle>.unmodifiable(subtitles);
        if (_player._textSubtitles case final runtime?) {
          return _textSubtitleCommand(() => runtime.replace(snapshot));
        }
        return _subtitleCommand(
          YlPlayerOperation.externalSubtitles,
          (backend) => backend.replaceExternalSubtitles(id, snapshot),
        );
      });

  /// Null turns subtitles off. Does not select a same-language replacement.
  Future<void> selectSubtitleTrack(String? trackId) => _command(() {
    if (trackId != null) validateYlSubtitleTrackId(trackId);
    if (_player._textSubtitles case final runtime?) {
      return _textSubtitleCommand(() async => runtime.select(trackId));
    }
    return _subtitleCommand(
      YlPlayerOperation.subtitleTrackSelection,
      (backend) => backend.selectSubtitleTrack(id, trackId),
    );
  });

  /// Positive values delay display. Offset must be whole milliseconds ±7 days.
  Future<void> setSubtitleOffset(Duration offset) => _command(() {
    validateYlSubtitleOffset(offset);
    if (_player._textSubtitles case final runtime?) {
      return _textSubtitleCommand(() async => runtime.offset(offset));
    }
    return _subtitleCommand(
      YlPlayerOperation.subtitleOffset,
      (backend) => backend.setSubtitleOffset(id, offset),
    );
  });

  Future<void> _textSubtitleCommand(Future<void> Function() action) async {
    _player._checkTextSubtitleAdmission();
    try {
      await action();
    } catch (_) {
      _player._checkSession(id);
      rethrow;
    }
    _player._checkSession(id);
    _player._publishSubtitles();
  }

  Future<void> _subtitleCommand(
    YlPlayerOperation operation,
    Future<void> Function(YlSubtitlePlatformPlayer backend) action,
  ) async {
    final backend = _player._backend;
    if (backend is! YlSubtitlePlatformPlayer ||
        !backend.capabilities.supportedOperations.contains(operation)) {
      throw _exception(YlFailureCodes.policyUnsupported);
    }
    try {
      await action(backend as YlSubtitlePlatformPlayer);
    } catch (_) {
      _player._checkSession(id);
      rethrow;
    }
    _player._checkSession(id);
  }

  /// Switches an explicitly supported live session's playback goal.
  /// Success acknowledges the backend's committed state barrier, not measured
  /// latency, first frame or drained buffers. Old adapters reject this command.
  Future<void> setLivePlaybackMode(YlLivePlaybackMode mode) =>
      _command(() async {
        final backend = _player._backend;
        final state = _player.state;
        if (backend is! YlLivePlaybackPlatformPlayer ||
            !backend.capabilities.supportedOperations.contains(
              YlPlayerOperation.livePlaybackMode,
            ) ||
            !state.timeline.isLive ||
            !(state.livePlayback?.switchableModes.contains(mode) ?? false)) {
          throw _exception(YlFailureCodes.policyUnsupported);
        }
        if (_player._pendingLivePlaybackCommands >= 32) {
          throw _exception(YlFailureCodes.resourceExhausted);
        }
        _player._pendingLivePlaybackCommands++;
        try {
          try {
            await (backend as YlLivePlaybackPlatformPlayer).setLivePlaybackMode(
              id,
              mode,
            );
          } catch (_) {
            _player._checkSession(id, allowFailed: true);
            rethrow;
          }
          _player._checkSession(id, allowFailed: true);
        } finally {
          _player._pendingLivePlaybackCommands--;
        }
      });

  Future<void> selectVideoTrack(String? trackId) => _command(() {
    if (trackId != null) validateYlTrackId(trackId);
    final backend = _player._backend;
    if (backend is! YlVideoTrackSelectionPlatformPlayer ||
        !backend.capabilities.supportedOperations.contains(
          YlPlayerOperation.videoTrackSelection,
        )) {
      throw _exception(YlFailureCodes.policyUnsupported);
    }
    return (backend as YlVideoTrackSelectionPlatformPlayer).selectVideoTrack(
      id,
      trackId,
    );
  });
  Future<void> setVideoConstraints(YlVideoConstraints constraints) =>
      _command(() {
        validateYlVideoConstraints(constraints);
        return _player._backend.setVideoConstraints(id, constraints);
      });
}
