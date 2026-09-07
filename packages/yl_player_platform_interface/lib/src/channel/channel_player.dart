import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../configuration.dart';
import '../media_source.dart';
import '../platform_player.dart';
import '../player_error.dart';
import '../player_event.dart';
import '../player_state.dart';
import '../validation.dart';
import 'channel_codec.dart';

/// Shared MethodChannel/EventChannel-backed player used by endorsed platforms.
final class YlChannelPlayer implements YlPlatformPlayer {
  YlChannelPlayer({
    required this.playerId,
    required int initialTextureId,
    required this.methods,
    required Stream<Object?> nativeEvents,
    required this.platform,
    required YlPlaybackEngine initialEngine,
  }) : _textureId = ValueNotifier<int?>(initialTextureId),
       _state = YlPlayerState(engine: initialEngine) {
    _nativeSubscription = nativeEvents.listen(
      _handleNativeEvent,
      onError: _handleNativeStreamError,
      onDone: _handleNativeStreamDone,
    );
  }

  final int playerId;
  final MethodChannel methods;
  final String platform;
  final ValueNotifier<int?> _textureId;
  final StreamController<YlPlayerState> _states =
      StreamController<YlPlayerState>.broadcast(sync: true);
  final StreamController<YlPlayerEvent> _events =
      StreamController<YlPlayerEvent>.broadcast(sync: true);
  late final StreamSubscription<Object?> _nativeSubscription;
  YlPlayerState _state;
  Future<void>? _disposeFuture;
  int? _sourceGeneration;
  bool _streamFailureReported = false;
  bool _malformedEventReported = false;
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
      _command('open', <String, Object?>{'source': encodeYlSource(source)});

  @override
  Future<void> pause() => _command('pause');

  @override
  Future<void> play() => _command('play');

  @override
  Future<void> seekTo(Duration position) {
    validateYlSeekPosition(position);
    return _command('seekTo', <String, Object?>{
      'positionMs': position.inMilliseconds,
    });
  }

  @override
  Future<void> seekToLiveEdge() => _command('seekToLiveEdge');

  @override
  Future<void> selectAudioTrack(String trackId) =>
      _command('selectAudioTrack', <String, Object?>{'trackId': trackId});

  @override
  Future<void> setPlaybackSpeed(double speed) {
    validateYlPlaybackSpeed(speed);
    return _command('setPlaybackSpeed', <String, Object?>{'speed': speed});
  }

  @override
  Future<void> setQualityConstraint(YlQualityConstraint constraint) {
    validateYlQualityConstraint(constraint);
    return _command('setQualityConstraint', <String, Object?>{
      'constraint': encodeYlQualityConstraint(constraint),
    });
  }

  @override
  Future<void> setVolume(double volume) {
    validateYlVolume(volume);
    return _command('setVolume', <String, Object?>{'volume': volume});
  }

  Future<void> _command(
    String name, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) async {
    if (_disposed) {
      throw StateError('The $platform platform player has been disposed.');
    }
    try {
      await methods.invokeMethod<void>('command', <String, Object?>{
        'playerId': playerId,
        'name': name,
        'arguments': arguments,
      });
    } on PlatformException catch (error) {
      throw decodeYlPlatformException(error, platform: platform);
    }
  }

  void _handleNativeEvent(Object? value) {
    if (_disposed || value is! Map) {
      return;
    }
    final envelope = ylStringMap(value);
    final eventPlayerId = _wireInt(envelope['playerId']);
    if (eventPlayerId != playerId) {
      return;
    }

    switch (envelope[YlChannelWireKeys.type]) {
      case 'state':
        _handleState(envelope);
      case YlChannelWireKeys.stateDelta:
        _handleStateDelta(envelope);
      case 'firstFrame':
      case 'tracksChanged':
        _emitDecodedEvent(envelope);
      case 'fallbackActivated':
        // Native fallback activation is followed by an authoritative state
        // snapshot whose engine is nativeFallback. This marker is informational
        // and is not part of the public YlPlayerEvent wire contract.
        return;
      case 'error':
      case 'retry':
      case 'fallback':
        if (envelope['error'] is! Map) {
          _reportMalformedEvent();
          return;
        }
        _emitDecodedEvent(envelope);
      default:
        _reportMalformedEvent();
    }
  }

  void _handleState(Map<String, Object?> envelope) {
    if (envelope[YlChannelWireKeys.state] is! Map) {
      _reportMalformedEvent();
      return;
    }
    final version = envelope[YlChannelWireKeys.protocolVersion];
    if (version == null) {
      _sourceGeneration = null;
    } else {
      final generation = _wireInt(envelope[YlChannelWireKeys.generation]);
      if (_wireInt(version) != ylChannelProtocolVersion ||
          generation == null ||
          generation < 0) {
        _reportMalformedEvent();
        return;
      }
      _sourceGeneration = generation;
    }
    _state = decodeYlState(envelope[YlChannelWireKeys.state]);
    _states.add(_state);
  }

  void _handleStateDelta(Map<String, Object?> envelope) {
    final generation = _wireInt(envelope[YlChannelWireKeys.generation]);
    if (_wireInt(envelope[YlChannelWireKeys.protocolVersion]) !=
            ylChannelProtocolVersion ||
        generation == null ||
        generation < 0 ||
        envelope[YlChannelWireKeys.delta] is! Map) {
      _reportMalformedEvent();
      return;
    }
    if (_sourceGeneration == null || generation != _sourceGeneration) {
      return;
    }
    _state = mergeYlStateDelta(_state, envelope[YlChannelWireKeys.delta]);
    _states.add(_state);
  }

  void _emitDecodedEvent(Map<String, Object?> envelope) {
    final event = decodeYlEvent(envelope);
    if (event == null) {
      _reportMalformedEvent();
      return;
    }
    _events.add(event);
  }

  void _handleNativeStreamError(Object error, [StackTrace? stackTrace]) {
    _reportStreamFailure(
      code: 'channel.event_stream_error',
      message: 'The $platform player event stream failed.',
    );
  }

  void _handleNativeStreamDone() {
    _reportStreamFailure(
      code: 'channel.event_stream_done',
      message: 'The $platform player event stream closed unexpectedly.',
    );
  }

  void _reportMalformedEvent() {
    if (_disposed || _malformedEventReported) {
      return;
    }
    _malformedEventReported = true;
    _emitTerminalError(
      YlPlayerError(
        category: YlPlayerErrorCategory.internal,
        code: 'channel.event_malformed',
        message: 'The $platform backend sent a malformed player event.',
      ),
    );
  }

  void _reportStreamFailure({required String code, required String message}) {
    if (_disposed || _streamFailureReported) {
      return;
    }
    _streamFailureReported = true;
    _emitTerminalError(
      YlPlayerError(
        category: YlPlayerErrorCategory.internal,
        code: code,
        message: message,
      ),
    );
  }

  void _emitTerminalError(YlPlayerError error) {
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
    } on Object {
      // Native teardown is best effort; local resources must always close.
    }
    await _nativeSubscription.cancel();
    _state = _state.copyWith(status: YlPlaybackStatus.disposed, error: null);
    _textureId.value = null;
    await _states.close();
    await _events.close();
    _textureId.dispose();
  }
}

/// Creates and wires a shared channel player for an endorsed platform package.
Future<YlChannelPlayer> createYlChannelPlayer({
  required YlPlayerConfiguration configuration,
  required MethodChannel methods,
  required Stream<Object?> nativeEvents,
  required String platform,
  required YlPlaybackEngine initialEngine,
}) async {
  validateYlPlayerConfiguration(configuration);
  try {
    final response = await methods.invokeMapMethod<String, Object?>(
      'create',
      <String, Object?>{'configuration': encodeYlConfiguration(configuration)},
    );
    final playerId = _wireInt(response?['playerId']);
    final textureId = _wireInt(response?['textureId']);
    if (playerId == null ||
        playerId < 0 ||
        textureId == null ||
        textureId < 0) {
      throw YlPlayerError(
        category: YlPlayerErrorCategory.internal,
        code: '$platform.invalid_create_response',
        message: 'The $platform backend returned an invalid create response.',
      );
    }
    return YlChannelPlayer(
      playerId: playerId,
      initialTextureId: textureId,
      methods: methods,
      nativeEvents: nativeEvents,
      platform: platform,
      initialEngine: initialEngine,
    );
  } on PlatformException catch (error) {
    throw decodeYlPlatformException(error, platform: platform);
  } on MissingPluginException catch (error) {
    throw YlPlayerError(
      category: YlPlayerErrorCategory.internal,
      code: '$platform.plugin_unavailable',
      message: 'The $platform yl_player plugin is not registered.',
      platformDiagnostic: error.message,
    );
  }
}

int? _wireInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is double && value.isFinite) {
    return value.toInt();
  }
  return null;
}
