import 'package:flutter/services.dart';
import 'package:yl_player_platform_interface/yl_player_legacy_transport.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

/// Endorsed iOS platform registration for `yl_player`.
final class YlPlayerIos extends YlPlayerPlatform {
  factory YlPlayerIos({
    MethodChannel methodChannel = const MethodChannel(
      'dev.ylplayer.yl_player_ios/methods',
    ),
    EventChannel eventChannel = const EventChannel(
      'dev.ylplayer.yl_player_ios/events',
    ),
    Stream<Object?>? nativeEvents,
  }) => YlPlayerIos._(
    methodChannel,
    nativeEvents ?? eventChannel.receiveBroadcastStream(),
  );

  YlPlayerIos._(this._methodChannel, this._nativeEvents);

  final MethodChannel _methodChannel;
  final Stream<Object?> _nativeEvents;

  static void registerWith() {
    YlPlayerPlatform.instance = YlPlayerIos();
  }

  @override
  Future<YlPlatformPlayer> createPlayer(YlPlayerOptions options) =>
      createYlLegacyChannelPlayer(
        options: options,
        methods: _methodChannel,
        nativeEvents: _nativeEvents,
        platform: 'ios',
        initialEngine: YlPlaybackEngine.avPlayer,
      );
}
