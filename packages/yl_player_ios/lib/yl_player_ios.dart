import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'src/unsupported_ios_player.dart';

/// Endorsed iOS platform registration for `yl_player`.
final class YlPlayerIos extends YlPlayerPlatform {
  static void registerWith() {
    YlPlayerPlatform.instance = YlPlayerIos();
  }

  @override
  Future<YlPlatformPlayer> createPlayer(
    YlPlayerConfiguration configuration,
  ) async => UnsupportedIosPlayer();
}
