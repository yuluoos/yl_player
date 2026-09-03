import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'configuration.dart';
import 'platform_player.dart';

/// Registration point for platform-specific `yl_player` implementations.
abstract class YlPlayerPlatform extends PlatformInterface {
  YlPlayerPlatform() : super(token: _token);

  static final Object _token = Object();
  static YlPlayerPlatform _instance = _UnsupportedPlayerPlatform();

  static YlPlayerPlatform get instance => _instance;

  static set instance(YlPlayerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<YlPlatformPlayer> createPlayer(YlPlayerConfiguration configuration);
}

final class _UnsupportedPlayerPlatform extends YlPlayerPlatform {
  @override
  Future<YlPlatformPlayer> createPlayer(YlPlayerConfiguration configuration) =>
      Future<YlPlatformPlayer>.error(
        UnsupportedError('No yl_player platform implementation is registered.'),
      );
}
