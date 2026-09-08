import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

/// Shared Apple platform registration while the typed native registry is built.
final class YlPlayerApple extends YlPlayerPlatform {
  static void registerWith() {
    YlPlayerPlatform.instance = YlPlayerApple();
  }

  @override
  Future<YlPlatformPlayer> createPlayer(YlPlayerOptions options) =>
      Future<YlPlatformPlayer>.error(
        const YlPlayerException(
          YlFailure(
            category: YlFailureCategory.platform,
            code: YlFailureCodes.platformUnavailable,
            message:
                'yl_player_apple playback is unavailable until its typed '
                'native registry is connected.',
            retryable: false,
            scope: YlFailureScope.player,
            diagnosticId: 'apple-registration-incomplete',
          ),
        ),
      );
}
