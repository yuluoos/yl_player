import 'package:flutter/services.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'src/channel_android_player.dart';
import 'src/channel_codec.dart';

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
  Future<YlPlatformPlayer> createPlayer(
    YlPlayerConfiguration configuration,
  ) async {
    try {
      final response = await _methodChannel.invokeMapMethod<String, Object?>(
        'create',
        <String, Object?>{'configuration': encodeConfiguration(configuration)},
      );
      if (response == null ||
          response['playerId'] is! num ||
          response['textureId'] is! num) {
        throw const YlPlayerError(
          category: YlPlayerErrorCategory.internal,
          code: 'android.invalid_create_response',
          message: 'The Android backend returned an invalid create response.',
        );
      }
      return ChannelAndroidPlayer(
        playerId: (response['playerId']! as num).toInt(),
        initialTextureId: (response['textureId']! as num).toInt(),
        methods: _methodChannel,
        nativeEvents: _nativeEvents,
      );
    } on PlatformException catch (error) {
      throw decodePlatformException(error, platform: 'android');
    } on MissingPluginException catch (error) {
      throw YlPlayerError(
        category: YlPlayerErrorCategory.internal,
        code: 'android.plugin_unavailable',
        message: 'The Android yl_player plugin is not registered.',
        platformDiagnostic: error.message,
      );
    }
  }
}
