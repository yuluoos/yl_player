import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'yl_player_ios_method_channel.dart';

abstract class YlPlayerIosPlatform extends PlatformInterface {
  /// Constructs a YlPlayerIosPlatform.
  YlPlayerIosPlatform() : super(token: _token);

  static final Object _token = Object();

  static YlPlayerIosPlatform _instance = MethodChannelYlPlayerIos();

  /// The default instance of [YlPlayerIosPlatform] to use.
  ///
  /// Defaults to [MethodChannelYlPlayerIos].
  static YlPlayerIosPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [YlPlayerIosPlatform] when
  /// they register themselves.
  static set instance(YlPlayerIosPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
