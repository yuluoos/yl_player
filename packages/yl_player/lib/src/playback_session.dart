part of 'player_controller.dart';

/// A handle to one committed source. Replacement or Stop makes commands stale.
final class YlPlaybackSession {
  YlPlaybackSession._(this._player, this.id, this.ready, this.firstFrame);
  final YlPlayerController _player;

  /// Opaque identity of this committed source; compare values rather than inferring order.
  final YlPlaybackSessionId id;

  /// Completes when the session is ready to accept playback, without proving audible output.
  final Future<void> ready;

  /// Completes on the native first-frame event for this session.
  /// This is not a screenshot or a measurement of physical display/audio synchronization.
  final Future<void> firstFrame;
  Future<void> _command(Future<void> Function() action) async {
    _player._checkSession(id);
    await action();
  }

  /// Requests playback for this session; completion acknowledges the command.
  Future<void> play() => _command(() => _player._backend.play(id));

  /// Pauses this session without discarding its source or selected tracks.
  Future<void> pause() => _command(() => _player._backend.pause(id));

  /// Seeks to a nonnegative programme position. Completion acknowledges the seek;
  /// callers observing output must still wait for the corresponding rendered frame.
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
  /// quality rebuilds. Its programme path supports added or removed tracks;
  /// missing explicitly selected content reports `track.not_found`.
  /// Android publishes one content choice per audio group and retains explicit
  /// selection across Periods and restoration while its semantic identity exists.
  /// Declared blank programme intervals retain the last content catalog and
  /// selection intent; internal timing silence is not exposed as an audio track.
  /// Missing selected content reports `track.not_found`; it does not silently
  /// select another language or role. IDs remain platform-specific.
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
  /// Container HTTP discovery requires byte ranges and a stable strong ETag.
  /// Explicit DASH or automatic .mpd sources discover clear static MPD text,
  /// wvtt and stpp tracks without fetching their media until selection. DASH
  /// uses bounded whole subtitle resources or exact ranges with strong ETags;
  /// MPD, initialization and segments retain the source managed network policy.
  /// Selected windows share the 4 MiB/10,000 cue catalog budget with external
  /// subtitles. Cross-Period identity preserves selection, and Period/PTO
  /// mapping clips cues to their half-open programme windows.
  /// Protected media and other explicit containers reject without I/O.
  /// Protected view overlay support applies only to separate clear resources.
  Future<void> discoverEmbeddedSubtitles() => _command(() {
    final runtime = _player._textSubtitles;
    final source = _player._subtitleSource;
    if (runtime == null ||
        source == null ||
        _player._subtitleProtectedSource ||
        _player.protectedVideoSurface != null) {
      throw _exception(YlFailureCodes.policyUnsupported);
    }
    return _textSubtitleCommand(() => runtime.discover(source));
  });

  /// Atomically replaces external subtitles; [] clears external entries.
  /// Backends without explicit support reject rather than ignoring resources.
  /// Clear external resources may overlay a protected native view only when its
  /// descriptor explicitly supports subtitle overlays. Resource loading keeps
  /// its own managed network policy; it never reads protected video pixels.
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

  /// Null turns subtitles off and cancels pending segment requests. Does not
  /// select a same-language replacement. For DASH, awaits the selected current
  /// and next window; malformed subtitle data rejects only this command.
  Future<void> selectSubtitleTrack(String? trackId) => _command(() {
    if (trackId != null) validateYlSubtitleTrackId(trackId);
    if (_player._textSubtitles case final runtime?) {
      return _textSubtitleCommand(
        () => runtime.selectAt(trackId, _player.state.timeline.position),
      );
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
