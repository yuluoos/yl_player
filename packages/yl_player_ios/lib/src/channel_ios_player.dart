import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'channel_codec.dart';

final class ChannelIosPlayer implements YlPlatformPlayer {
  ChannelIosPlayer({
    required this.playerId,
    required int initialTextureId,
    required this.methods,
    required Stream<Object?> nativeEvents,
  }) : _textureId = ValueNotifier<int?>(initialTextureId) {
    _nativeSubscription = nativeEvents.listen(_handleNativeEvent);
  }

  final int playerId;
  final MethodChannel methods;
  final ValueNotifier<int?> _textureId;
  final StreamController<YlPlayerState> _states =
      StreamController<YlPlayerState>.broadcast(sync: true);
  final StreamController<YlPlayerEvent> _events =
      StreamController<YlPlayerEvent>.broadcast(sync: true);
  late final StreamSubscription<Object?> _nativeSubscription;
  YlPlayerState _state = YlPlayerState(engine: YlPlaybackEngine.avPlayer);
  Future<void>? _disposeFuture;
  bool _disposed = false;

  @override
  Stream<YlPlayerEvent> get events => _events.stream;

  @override
  YlPlayerState get state => _state;

  @override
  Stream<YlPlayerState> get states => _states.stream;

  @override
  ValueListenable<int?> get textureId => _textureId;

  @override
  Future<void> dispose() => _disposeFuture ??= _performDispose();

  @override
  Future<void> open(YlMediaSource source) =>
      _command('open', <String, Object?>{'source': encodeSource(source)});

  @override
  Future<void> pause() => _command('pause');

  @override
  Future<void> play() => _command('play');

  @override
  Future<void> seekTo(Duration position) => _command(
    'seekTo',
    <String, Object?>{'positionMs': position.inMilliseconds},
  );

  @override
  Future<void> seekToLiveEdge() => _command('seekToLiveEdge');

  @override
  Future<void> selectAudioTrack(String trackId) =>
      _command('selectAudioTrack', <String, Object?>{'trackId': trackId});

  @override
  Future<void> setPlaybackSpeed(double speed) =>
      _command('setPlaybackSpeed', <String, Object?>{'speed': speed});

  @override
  Future<void> setQualityConstraint(YlQualityConstraint constraint) => _command(
    'setQualityConstraint',
    <String, Object?>{'constraint': encodeQualityConstraint(constraint)},
  );

  @override
  Future<void> setVolume(double volume) =>
      _command('setVolume', <String, Object?>{'volume': volume});

  Future<void> _command(
    String name, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) async {
    if (_disposed) {
      throw StateError('The iOS platform player has been disposed.');
    }
    try {
      await methods.invokeMethod<void>('command', <String, Object?>{
        'playerId': playerId,
        'name': name,
        'arguments': arguments,
      });
    } on PlatformException catch (error) {
      final playerError = decodePlatformException(error, platform: 'ios');
      _emitError(playerError);
      throw playerError;
    }
  }

  void _handleNativeEvent(Object? value) {
    if (_disposed) {
      return;
    }
    final envelope = stringMap(value);
    final eventPlayerId = envelope['playerId'];
    if (eventPlayerId is! num || eventPlayerId.toInt() != playerId) {
      return;
    }
    if (envelope['type'] == 'state') {
      _state = decodeState(envelope['state']);
      _states.add(_state);
      return;
    }
    final event = decodeEvent(envelope);
    if (event != null) {
      _events.add(event);
    }
  }

  void _emitError(YlPlayerError error) {
    if (_disposed) {
      return;
    }
    _state = _state.copyWith(status: YlPlaybackStatus.error, error: error);
    _states.add(_state);
    _events.add(YlErrorEvent(error));
  }

  Future<void> _performDispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    try {
      await methods.invokeMethod<void>('dispose', <String, Object?>{
        'playerId': playerId,
      });
    } on MissingPluginException {
      // The engine may already be detached during application shutdown.
    }
    await _nativeSubscription.cancel();
    _state = _state.copyWith(status: YlPlaybackStatus.disposed, error: null);
    _textureId.value = null;
    await _states.close();
    await _events.close();
    _textureId.dispose();
  }
}
