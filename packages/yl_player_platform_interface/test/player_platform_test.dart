import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

final class TestPlayerPlatform extends YlPlayerPlatform {
  @override
  Future<YlPlatformPlayer> createPlayer(YlPlayerConfiguration configuration) {
    throw UnimplementedError();
  }
}

final class UnverifiedPlayerPlatform implements YlPlayerPlatform {
  @override
  Future<YlPlatformPlayer> createPlayer(YlPlayerConfiguration configuration) {
    throw UnimplementedError();
  }
}

void main() {
  test('registered verified platform becomes the singleton instance', () {
    final platform = TestPlayerPlatform();

    YlPlayerPlatform.instance = platform;

    expect(YlPlayerPlatform.instance, same(platform));
  });

  test('unverified implementation cannot replace the singleton', () {
    expect(
      () => YlPlayerPlatform.instance = UnverifiedPlayerPlatform(),
      throwsAssertionError,
    );
  });
}
