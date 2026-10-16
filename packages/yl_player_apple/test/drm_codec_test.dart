import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'package:yl_player_apple/src/apple_codec.dart';

void main() {
  test('schema5 keeps FairPlay binary configuration and rejects Widevine', () {
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
    final wire = AppleCodec.source(fps);
    expect(wire.drm!.certificate, [1]);
    expect(wire.drm!.contentId, [2]);
    expect(wire.drm!.timeoutMs, 10000);
    expect(AppleCodec.schemaMajor, 7);
  });
}
