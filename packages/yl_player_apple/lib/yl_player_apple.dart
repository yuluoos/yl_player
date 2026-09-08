import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'src/apple_player.dart';
import 'src/apple_transport.dart';

/// Shared iOS and macOS platform registration for `yl_player`.
final class YlPlayerApple extends YlPlayerPlatform {
  static void registerWith() {
    YlPlayerPlatform.instance = YlPlayerApple();
  }

  @override
  Future<YlPlatformPlayer> createPlayer(YlPlayerOptions options) =>
      ApplePlayer.create(
        options,
        factory: PigeonAppleFactoryTransport(),
        transportForSuffix: PigeonApplePlayerTransport.new,
        setupCallbacks: setupAppleCallbacks,
      );
}
