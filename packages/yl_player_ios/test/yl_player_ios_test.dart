import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_ios/yl_player_ios.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  test('registerWith installs the iOS implementation', () {
    YlPlayerIos.registerWith();

    expect(YlPlayerPlatform.instance, isA<YlPlayerIos>());
  });

  test(
    'placeholder backend fails honestly and disposes idempotently',
    () async {
      final platform = YlPlayerIos();
      final player = await platform.createPlayer(const YlPlayerConfiguration());

      await expectLater(
        player.open(YlMediaSource.file('/video.mp4')),
        throwsA(
          isA<YlPlayerError>().having(
            (error) => error.code,
            'code',
            'ios.not_implemented',
          ),
        ),
      );
      await player.dispose();
      await player.dispose();

      expect(player.state.status, YlPlaybackStatus.disposed);
    },
  );
}
