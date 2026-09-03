
import 'yl_player_android_platform_interface.dart';

class YlPlayerAndroid {
  Future<String?> getPlatformVersion() {
    return YlPlayerAndroidPlatform.instance.getPlatformVersion();
  }
}
