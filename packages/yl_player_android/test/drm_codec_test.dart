import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'package:yl_player_android/src/android_codec.dart';

void main() {
  test('Widevine configuration survives encoding without license endpoint secrets', () {
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
    final dynamic encoded = AndroidCodec.source(widevine);
    expect(encoded.drm.cbcs, isFalse);
    expect(encoded.drm.timeoutMs, 10000);
    // Endpoint and credentials never cross into native media requests.
    expect(encoded.request?.credentials ?? {}, isEmpty);
    expect(
      () => AndroidCodec.source(fps),
      throwsA(
        isA<YlPlayerException>().having(
          (e) => e.failure.code,
          'code',
          YlFailureCodes.drmSchemeMismatch,
        ),
      ),
    );
    expect(AndroidCodec.schemaMajor, 5);
  });
}
