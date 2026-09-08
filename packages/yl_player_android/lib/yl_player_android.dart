import 'package:flutter/services.dart';
import 'package:yl_player_platform_interface/yl_player_legacy_transport.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

/// Endorsed Android platform registration for `yl_player`.
final class YlPlayerAndroid extends YlPlayerPlatform {
  factory YlPlayerAndroid({
    MethodChannel methodChannel = const MethodChannel(
      'dev.ylplayer.yl_player_android/methods',
    ),
    EventChannel eventChannel = const EventChannel(
      'dev.ylplayer.yl_player_android/events',
    ),
    Stream<Object?>? nativeEvents,
  }) => YlPlayerAndroid._(
    methodChannel,
    nativeEvents ?? eventChannel.receiveBroadcastStream(),
  );

  YlPlayerAndroid._(this._methodChannel, this._nativeEvents);

  final MethodChannel _methodChannel;
  final Stream<Object?> _nativeEvents;

  static void registerWith() {
    YlPlayerPlatform.instance = YlPlayerAndroid();
  }

  @override
  Future<YlPlatformPlayer> createPlayer(YlPlayerOptions options) =>
      createYlLegacyChannelPlayer(
        options: options,
        methods: _methodChannel,
        nativeEvents: _nativeEvents,
        platform: 'android',
        initialEngine: YlPlaybackEngine.media3,
      );
}
