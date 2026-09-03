
import 'yl_player_ios_platform_interface.dart';

class YlPlayerIos {
  Future<String?> getPlatformVersion() {
    return YlPlayerIosPlatform.instance.getPlatformVersion();
  }
}
