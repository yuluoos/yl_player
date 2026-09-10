// Test-only wrapper of the generated Pigeon messenger. No new channel or
// production hook: every call still traverses the actual native plugin.
// ignore_for_file: implementation_imports
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:yl_player_apple/src/apple_player.dart';
import 'package:yl_player_apple/src/apple_transport.dart';
import 'package:yl_player_apple/src/pigeon/yl_player_apple.g.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

final class AppleCallbackProbe extends YlPlayerPlatform {
  final messenger = _AcknowledgementMessenger();
  @override
  Future<YlPlatformPlayer> createPlayer(YlPlayerOptions options) =>
      ApplePlayer.create(
        options,
        factory: PigeonAppleFactoryTransport(),
        transportForSuffix: PigeonApplePlayerTransport.new,
        setupCallbacks: (suffix, callbacks) => ApplePlayerFlutterApi.setUp(
          callbacks,
          binaryMessenger: messenger,
          messageChannelSuffix: suffix,
        ),
      );
}

final class _AcknowledgementMessenger implements BinaryMessenger {
  final BinaryMessenger _delegate =
      ServicesBinding.instance.defaultBinaryMessenger;
  Completer<void>? hold;
  Completer<void> entered = Completer<void>();
  int received = 0;
  @override
  Future<ByteData?>? send(String channel, ByteData? message) =>
      _delegate.send(channel, message);
  @override
  void setMessageHandler(String channel, MessageHandler? handler) {
    _delegate.setMessageHandler(
      channel,
      handler == null
          ? null
          : (message) async {
              received++;
              final reply = await handler(message);
              final gate = hold;
              if (gate != null) {
                hold = null;
                entered.complete();
                await gate.future;
              }
              return reply;
            },
    );
  }

  @override
  // ignore: deprecated_member_use
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    PlatformMessageResponseCallback? callback,
  ) =>
      // ignore: deprecated_member_use
      _delegate.handlePlatformMessage(channel, data, callback);
}
