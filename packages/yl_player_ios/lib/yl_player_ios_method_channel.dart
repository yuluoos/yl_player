import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'yl_player_ios_platform_interface.dart';

/// An implementation of [YlPlayerIosPlatform] that uses method channels.
class MethodChannelYlPlayerIos extends YlPlayerIosPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('yl_player_ios');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
