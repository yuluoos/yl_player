import 'package:flutter/services.dart';

/// Talks only to the example's debug-source-set observer. No production hook.
final class AndroidFrameObservation {
  static const _channel = MethodChannel(
    'yl_player_example/debug/frame_observation',
  );
  Future<Map<Object?, Object?>> install(String previousSession) async =>
      (await _channel
          .invokeMapMethod<Object?, Object?>('install', {
            'previousSession': previousSession,
          })
          .timeout(const Duration(seconds: 5)))!;
  Future<List<Map<Object?, Object?>>> read() async =>
      (await _channel
              .invokeListMethod<Object?>('read')
              .timeout(const Duration(seconds: 5)))!
          .cast<Map<Object?, Object?>>();
  Future<void> remove() =>
      _channel.invokeMethod<void>('remove').timeout(const Duration(seconds: 5));
}
