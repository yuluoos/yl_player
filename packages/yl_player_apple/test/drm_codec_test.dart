import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'package:yl_player_apple/src/apple_codec.dart';

void main() {
  test('schema4 codec rejects DRM instead of dropping its configuration', () {
    final endpoint = YlDrmLicenseEndpoint(Uri.parse('https://license.test'));
    final widevine = YlNetworkSource(
      Uri.parse('https://media.test/v'),
      format: YlMediaFormat.dash,
      drm: YlWidevineDrm(license: endpoint),
    );
    final fps = YlNetworkSource(
      Uri.parse('https://media.test/v'),
      format: YlMediaFormat.hls,
      drm: YlFairPlayDrm(
        license: endpoint,
        certificate: YlDrmBytes([1]),
        contentId: YlDrmBytes([2]),
      ),
    );
    expect(
      () => AppleCodec.source(widevine),
      throwsA(
        isA<YlPlayerException>().having(
          (e) => e.failure.code,
          'code',
          YlFailureCodes.drmSchemeMismatch,
        ),
      ),
    );
    expect(
      () => AppleCodec.source(fps),
      throwsA(
        isA<YlPlayerException>().having(
          (e) => e.failure.code,
          'code',
          YlFailureCodes.drmUnsupported,
        ),
      ),
    );
    expect(AppleCodec.schemaMajor, 4);
  });
}
