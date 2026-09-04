import 'package:flutter/services.dart';
import 'package:yl_player_platform_interface/yl_player_channel.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

/// Endorsed macOS platform registration for `yl_player`.
final class YlPlayerMacos extends YlPlayerPlatform {
  factory YlPlayerMacos({
    MethodChannel methodChannel = const MethodChannel(
      'dev.ylplayer.yl_player_macos/methods',
    ),
    EventChannel eventChannel = const EventChannel(
      'dev.ylplayer.yl_player_macos/events',
    ),
    Stream<Object?>? nativeEvents,
  }) => YlPlayerMacos._(
    methodChannel,
    nativeEvents ?? eventChannel.receiveBroadcastStream(),
  );

  YlPlayerMacos._(this._methodChannel, this._nativeEvents);

  final MethodChannel _methodChannel;
  final Stream<Object?> _nativeEvents;

  static void registerWith() {
    YlPlayerPlatform.instance = YlPlayerMacos();
  }

  @override
  Future<YlPlatformPlayer> createPlayer(YlPlayerConfiguration configuration) =>
      createYlChannelPlayer(
        configuration: configuration,
        methods: _methodChannel,
        nativeEvents: _nativeEvents,
        platform: 'macos',
        initialEngine: YlPlaybackEngine.avPlayer,
      );
}
