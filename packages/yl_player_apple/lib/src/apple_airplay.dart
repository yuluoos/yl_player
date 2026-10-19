import 'package:flutter/services.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'apple_codec.dart';
import 'pigeon/yl_player_apple.g.dart';

/// Versioned optional transport. Existing Pigeon messages retain their schema.
final class AppleAirPlayChannel {
  AppleAirPlayChannel(String suffix)
    : _requests = BasicMessageChannel<Object?>(
        'dev.ylplayer.airplay.$suffix',
        ApplePlayerHostApi.pigeonChannelCodec,
      ),
      _events = BasicMessageChannel<Object?>(
        'dev.ylplayer.airplay.events.$suffix',
        const StandardMessageCodec(),
      );

  final BasicMessageChannel<Object?> _requests;
  final BasicMessageChannel<Object?> _events;
  bool _closed = false;

  Future<AppleAirPlaySnapshot?> negotiate({
    required void Function(AppleAirPlaySnapshot) onState,
    required void Function(YlPlayerException) onError,
  }) async {
    _events.setMessageHandler((message) async {
      if (_closed) return null;
      try {
        onState(AppleAirPlaySnapshot.decode(message));
      } catch (_) {
        onError(AppleCodec.problem(YlFailureCodes.protocolMismatch));
      }
      return null;
    });
    final reply = await _requests.send({'method': 'state'});
    if (reply == null) {
      close();
      return null;
    }
    return AppleAirPlaySnapshot.decode(_value(reply));
  }

  Object? _value(Object? reply) {
    if (reply is! Map ||
        (reply.containsKey('value') == reply.containsKey('error'))) {
      throw AppleCodec.problem(YlFailureCodes.protocolMismatch);
    }
    if (reply['error'] case final AppleFailureMessage error) {
      throw YlPlayerException(AppleCodec.failure(error));
    }
    if (reply.containsKey('error')) {
      throw AppleCodec.problem(YlFailureCodes.protocolMismatch);
    }
    return reply['value'];
  }

  Future<T> _request<T>(String method, Object request) async {
    if (_closed) throw AppleCodec.problem(YlFailureCodes.playerDisposed);
    final reply = _value(
      await _requests.send({'method': method, 'request': request}),
    );
    if (reply is! T) throw AppleCodec.problem(YlFailureCodes.protocolMismatch);
    return reply;
  }

  Future<AppleAssessmentReply> assess(AppleAssessRequest request) =>
      _request('assess', request);
  Future<AppleLoadReply> load(AppleLoadRequest request) =>
      _request('load', request);

  void close() {
    if (_closed) return;
    _closed = true;
    _events.setMessageHandler(null);
  }
}

final class AppleAirPlaySnapshot {
  const AppleAirPlaySnapshot(this.revision, this.state);
  final int revision;
  final YlAirPlayState state;

  static AppleAirPlaySnapshot decode(Object? value) {
    try {
      if (value is! Map ||
          value['version'] != 1 ||
          value['revision'] is! int ||
          value['enabled'] is! bool ||
          value['active'] is! bool ||
          !value.containsKey('sessionId') ||
          (value['sessionId'] != null && value['sessionId'] is! String)) {
        throw ArgumentError('Invalid AirPlay state.');
      }
      final revision = AppleCodec.integer(value['revision'] as int);
      final session = value['sessionId'] as String?;
      final enabled = value['enabled'] as bool;
      final active = value['active'] as bool;
      if (active && !enabled || enabled && session == null) {
        throw ArgumentError('Invalid AirPlay session.');
      }
      return AppleAirPlaySnapshot(
        revision,
        YlAirPlayState(
          supported: true,
          enabled: enabled,
          active: active,
          sessionId: session == null ? null : AppleCodec.session(session),
        ),
      );
    } catch (_) {
      throw AppleCodec.problem(YlFailureCodes.protocolMismatch);
    }
  }
}
