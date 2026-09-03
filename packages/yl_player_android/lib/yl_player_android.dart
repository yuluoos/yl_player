import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'src/unsupported_android_player.dart';

/// Endorsed Android platform registration for `yl_player`.
final class YlPlayerAndroid extends YlPlayerPlatform {
  static void registerWith() {
    YlPlayerPlatform.instance = YlPlayerAndroid();
  }

  @override
  Future<YlPlatformPlayer> createPlayer(
    YlPlayerConfiguration configuration,
  ) async => UnsupportedAndroidPlayer();
}
