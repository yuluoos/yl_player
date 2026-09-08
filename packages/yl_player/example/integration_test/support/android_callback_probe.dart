import 'dart:async';
import 'package:flutter/services.dart';
import 'package:yl_player_android/src/pigeon/yl_player_android.g.dart';

// Test-owned consumer of the actual private Pigeon protocol. Holding a transport
// reply exercises native FIFO acknowledgement without production test hooks.
final class AndroidCallbackProbe {
  AndroidCallbackProbe(this.suffix) {
    for (final method in methods) {
      BasicMessageChannel<Object?>(
        '$prefix.$method.$suffix',
        AndroidPlayerFlutterApi.pigeonChannelCodec,
      ).setMessageHandler((message) async {
        final value = (message! as List<Object?>).single!;
        received.add(value);
        if (hold != null) {
          final current = hold!;
          hold = null;
          entered.complete();
          await current.future;
        }
        return <Object?>[];
      });
    }
  }
  static const prefix =
      'dev.flutter.pigeon.yl_player_android.AndroidPlayerFlutterApi';
  static const methods = [
    'onState',
    'onStateDelta',
    'onFirstFrame',
    'onRetryScheduled',
    'onEngineChanged',
    'onPlaybackFailed',
  ];
  final String suffix;
  final received = <Object>[];
  final entered = Completer<void>();
  Completer<void>? hold;
  void close() {
    for (final method in methods) {
      BasicMessageChannel<Object?>(
        '$prefix.$method.$suffix',
        AndroidPlayerFlutterApi.pigeonChannelCodec,
      ).setMessageHandler(null);
    }
  }
}
