import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'yl_player_android_platform_interface.dart';

/// An implementation of [YlPlayerAndroidPlatform] that uses method channels.
class MethodChannelYlPlayerAndroid extends YlPlayerAndroidPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('yl_player_android');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
