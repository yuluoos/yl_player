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
    return _player._backend.seekTo(id, position);
  });
  Future<void> seekToLiveEdge() =>
      _command(() => _player._backend.seekToLiveEdge(id));
  Future<void> setPlaybackSpeed(double speed) => _command(() {
    validateYlPlaybackSpeed(speed);
    return _player._backend.setPlaybackSpeed(id, speed);
  });
  Future<void> selectAudioTrack(String trackId) => _command(() {
    validateYlTrackId(trackId);
    return _player._backend.selectAudioTrack(id, trackId);
  });
  Future<void> setVideoConstraints(YlVideoConstraints constraints) =>
      _command(() {
        validateYlVideoConstraints(constraints);
        return _player._backend.setVideoConstraints(id, constraints);
      });
}
