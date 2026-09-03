import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'yl_player_android_method_channel.dart';

abstract class YlPlayerAndroidPlatform extends PlatformInterface {
  /// Constructs a YlPlayerAndroidPlatform.
  YlPlayerAndroidPlatform() : super(token: _token);

  static final Object _token = Object();

  static YlPlayerAndroidPlatform _instance = MethodChannelYlPlayerAndroid();

  /// The default instance of [YlPlayerAndroidPlatform] to use.
  ///
  /// Defaults to [MethodChannelYlPlayerAndroid].
  static YlPlayerAndroidPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [YlPlayerAndroidPlatform] when
  /// they register themselves.
  static set instance(YlPlayerAndroidPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
