import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_android/yl_player_android.dart';
import 'package:yl_player_android/yl_player_android_platform_interface.dart';
import 'package:yl_player_android/yl_player_android_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockYlPlayerAndroidPlatform
    with MockPlatformInterfaceMixin
    implements YlPlayerAndroidPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final YlPlayerAndroidPlatform initialPlatform = YlPlayerAndroidPlatform.instance;

  test('$MethodChannelYlPlayerAndroid is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelYlPlayerAndroid>());
  });

  test('getPlatformVersion', () async {
    YlPlayerAndroid ylPlayerAndroidPlugin = YlPlayerAndroid();
    MockYlPlayerAndroidPlatform fakePlatform = MockYlPlayerAndroidPlatform();
    YlPlayerAndroidPlatform.instance = fakePlatform;

    expect(await ylPlayerAndroidPlugin.getPlatformVersion(), '42');
  });
}
