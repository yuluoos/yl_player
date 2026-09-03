import 'package:flutter/services.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'src/channel_codec.dart';
import 'src/channel_ios_player.dart';

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
          code: 'ios.invalid_create_response',
          message: 'The iOS backend returned an invalid create response.',
        );
      }
      return ChannelIosPlayer(
        playerId: (response['playerId']! as num).toInt(),
        initialTextureId: (response['textureId']! as num).toInt(),
        methods: _methodChannel,
        nativeEvents: _nativeEvents,
      );
    } on PlatformException catch (error) {
      throw decodePlatformException(error, platform: 'ios');
    } on MissingPluginException catch (error) {
      throw YlPlayerError(
        category: YlPlayerErrorCategory.internal,
        code: 'ios.plugin_unavailable',
        message: 'The iOS yl_player plugin is not registered.',
        platformDiagnostic: error.message,
      );
    }
  }
}
