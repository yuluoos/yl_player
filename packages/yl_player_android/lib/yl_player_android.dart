import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'src/android_player.dart';
import 'src/android_transport.dart';

/// Endorsed Android platform registration for `yl_player`.
final class YlPlayerAndroid extends YlPlayerPlatform {
  static void registerWith() {
    YlPlayerPlatform.instance = YlPlayerAndroid();
  }

  @override
  Future<YlPlatformPlayer> createPlayer(YlPlayerOptions options) =>
      AndroidPlayer.create(
        options,
        factory: PigeonAndroidFactoryTransport(),
        transportForSuffix: PigeonAndroidPlayerTransport.new,
        setupCallbacks: setupAndroidCallbacks,
      );
}
