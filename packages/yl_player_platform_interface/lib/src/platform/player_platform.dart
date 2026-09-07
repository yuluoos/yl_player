import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../model/failure.dart';
import '../options/player_options.dart';
import 'platform_player.dart';

/// Registration point for v2 implementations. The controller verifies each
/// created player's implementation SPI major before exposing it to callers.
abstract class YlPlayerPlatform extends PlatformInterface {
  YlPlayerPlatform() : super(token: _token);
  static final Object _token = Object();
  static YlPlayerPlatform _instance = _UnsupportedPlayerPlatform();
  static YlPlayerPlatform get instance => _instance;
  static set instance(YlPlayerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<YlPlatformPlayer> createPlayer(YlPlayerOptions options);
}

final class _UnsupportedPlayerPlatform extends YlPlayerPlatform {
  @override
  Future<YlPlatformPlayer> createPlayer(YlPlayerOptions options) =>
      Future.error(
        const YlPlayerException(
          YlFailure(
            category: YlFailureCategory.platform,
            code: YlFailureCodes.platformUnavailable,
            message: 'No yl_player platform implementation is registered.',
            retryable: false,
            scope: YlFailureScope.player,
            diagnosticId: 'platform-unavailable',
          ),
        ),
      );
}
