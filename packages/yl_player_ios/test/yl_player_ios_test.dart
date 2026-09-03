import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_ios/yl_player_ios.dart';
import 'package:yl_player_ios/yl_player_ios_platform_interface.dart';
import 'package:yl_player_ios/yl_player_ios_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockYlPlayerIosPlatform
    with MockPlatformInterfaceMixin
    implements YlPlayerIosPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final YlPlayerIosPlatform initialPlatform = YlPlayerIosPlatform.instance;

  test('$MethodChannelYlPlayerIos is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelYlPlayerIos>());
  });

  test('getPlatformVersion', () async {
    YlPlayerIos ylPlayerIosPlugin = YlPlayerIos();
    MockYlPlayerIosPlatform fakePlatform = MockYlPlayerIosPlatform();
    YlPlayerIosPlatform.instance = fakePlatform;

    expect(await ylPlayerIosPlugin.getPlatformVersion(), '42');
  });
}
