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

  /// Selects one audio track using its opaque ID from the current session's
  /// audioTracks catalog. IDs must not be inferred from list order or language:
  /// multiple tracks may share a language and differ by role or content.
  /// An unavailable ID rejects the command without selecting a replacement.
  /// Apple static DASH keeps semantic IDs across reordered Periods and video
  /// quality rebuilds; a changing audio identity set is currently unsupported.
  /// Completion acknowledges selection; it does not measure audible output.
  Future<void> selectAudioTrack(String trackId) => _command(() {
    validateYlTrackId(trackId);
    return _player._backend.selectAudioTrack(id, trackId);
  });

  /// Discovers supported text, PGS and VobSub tracks in the committed file or HTTP(S)
  /// Matroska/WebM/MP4 source. Supported codecs depend on the container.
  /// PGS and VobSub bitmap tracks are supported in Matroska only; embedded
  /// VobSub uses CodecPrivate and raw SPU blocks, without external IDX/SUB files.
  /// Matroska accepts up to four zlib/header-stripping stages for blocks,
  /// CodecPrivate or both, decoded in descending encoding order. Stored,
  /// intermediate and final bytes share budgets before codec parsing.
  /// Encrypted and next-encoding scopes reject.
  /// MP4 discovery shares a 200,000-box limit across container structures and
  /// tx3g/WebVTT/TTML configuration and tx3g/WebVTT sample boxes across
  /// tracks and fragments. Font/style records have their own separate limits.
  /// MP4 elng overrides the packed mdhd language with a well-formed BCP 47
  /// tag (up to 128 ASCII characters), preserving spelling. No registry lookup,
  /// canonicalization or automatic language selection is performed. A missing
  /// elng retains mdhd; malformed tags reject discovery atomically. Track IDs
  /// remain independent of language. Existing mdhd validation still applies.
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
