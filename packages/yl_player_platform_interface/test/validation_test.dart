import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

void main() {
  test('public input validation runs in release-compatible functions', () {
    expect(
      () => validateYlSource(YlNetworkSource(Uri.parse('file:///a'))),
      throwsArgumentError,
    );
    for (final timeout in [
      Duration.zero,
      const Duration(milliseconds: -1),
      const Duration(milliseconds: 0x80000000),
    ]) {
      expect(
        () => validateYlSource(
          YlNetworkSource(
            Uri.parse('https://example.test/a'),
            networkPolicy: YlNetworkPolicy.managed(connectTimeout: timeout),
          ),
        ),
        throwsArgumentError,
      );
    }
    for (final volume in [-1.0, 2.0, double.nan, double.infinity]) {
      expect(() => validateYlVolume(volume), throwsArgumentError);
    }
    expect(
      () => validateYlPlayerOptions(
        const YlPlayerOptions(positionUpdateInterval: Duration.zero),
      ),
      throwsArgumentError,
    );
    expect(
      () => validateYlVideoConstraints(const YlVideoConstraints(maxWidth: 0)),
      throwsArgumentError,
    );
    expect(
      () => validateYlSeekPosition(const Duration(milliseconds: -1)),
      throwsArgumentError,
    );
  });
}
