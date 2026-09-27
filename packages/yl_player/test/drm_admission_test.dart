import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'support/fake_player_platform.dart';

Matcher unsupported() => throwsA(
  isA<YlPlayerException>().having(
    (e) => e.failure.code,
    'code',
    YlFailureCodes.drmUnsupported,
  ),
);
void main() {
  final protected = YlNetworkSource(
    Uri.parse('https://owned.test/manifest.mpd'),
    format: YlMediaFormat.dash,
    drm: YlWidevineDrm(
      license: YlDrmLicenseEndpoint(Uri.parse('https://license.test')),
    ),
  );
  test('old SPI adapter cannot silently assess DRM as clear media', () async {
    final backend = FakePlatformPlayer();
    final player = await YlPlayerController.create(
      platform: FakePlayerPlatform(backend),
    );
    addTearDown(player.dispose);
    await expectLater(player.assess(protected), unsupported());
  });
  test(
    'DRM rejection must happen before native load and cancellation of a pending clear load',
    () async {
      final backend = FakePlatformPlayer();
      final player = await YlPlayerController.create(
        platform: FakePlayerPlatform(backend),
      );
      addTearDown(player.dispose);
      final clear = player.load(
        YlNetworkSource(Uri.parse('https://owned.test/clear.mp4')),
      );
      // Attach before the candidate: an erroneous cancel must be observed too.
      Object? clearError;
      final clearResult = clear.then<YlPlaybackSession?>(
        (s) => s,
        onError: (Object e) {
          clearError = e;
          return null;
        },
      );
      await expectLater(
        player.load(protected).timeout(const Duration(milliseconds: 100)),
        unsupported(),
      );
      expect(backend.loads, hasLength(1));
      expect(clearError, isNull);
      backend.commit(const YlPlaybackSessionId('kept'));
      expect((await clearResult)?.id, const YlPlaybackSessionId('kept'));
    },
  );
}
