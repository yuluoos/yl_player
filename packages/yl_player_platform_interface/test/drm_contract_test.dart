import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

Matcher code(String value) => throwsA(
  isA<YlPlayerException>().having((e) => e.failure.code, 'code', value),
);
void main() {
  final endpoint = YlDrmLicenseEndpoint(
    Uri.parse('https://license.test/token?secret=value'),
  );
  test('DRM binary values copy, compare and redact', () {
    final input = Uint8List.fromList([65, 66]);
    final data = YlDrmBytes(input);
    input[0] = 0;
    final returned = data.bytes;
    returned[1] = 0;
    expect(data.bytes, [65, 66]);
    expect(data, YlDrmBytes([65, 66]));
    expect(data.toString(), isNot(contains('65')));
    expect(() => YlDrmBytes([-1]), code(YlFailureCodes.drmConfigInvalid));
    expect(() => YlDrmBytes([256]), code(YlFailureCodes.drmConfigInvalid));
  });
  test('license endpoint validates policy without exposing URI/headers', () {
    expect(endpoint.toString(), isNot(contains('secret')));
    expect(
      () => YlDrmLicenseEndpoint(Uri.parse('http://license.test')),
      code(YlFailureCodes.drmConfigInvalid),
    );
    expect(
      () => YlDrmLicenseEndpoint(Uri.parse('https://u:p@license.test')),
      code(YlFailureCodes.drmConfigInvalid),
    );
    expect(
      () => YlDrmLicenseEndpoint(
        Uri.parse('https://license.test'),
        maxRetries: 1,
      ),
      code(YlFailureCodes.drmConfigInvalid),
    );
    expect(
      () => YlDrmLicenseEndpoint(
        Uri.parse('https://license.test'),
        timeout: Duration.zero,
      ),
      code(YlFailureCodes.drmConfigInvalid),
    );
    expect(
      () => YlDrmLicenseEndpoint(
        Uri.parse('https://license.test'),
        request: YlHttpRequest(headers: {'X-Token': 'secret'}),
      ),
      code(YlFailureCodes.drmConfigInvalid),
    );
  });
  test(
    'DRM configuration requires format, certificate and opaque content id',
    () {
      final widevine = YlWidevineDrm(license: endpoint);
      expect(
        () => validateYlSource(
          YlNetworkSource(Uri.parse('https://media.test/v'), drm: widevine),
        ),
        code(YlFailureCodes.drmConfigInvalid),
      );
      validateYlSource(
        YlNetworkSource(
          Uri.parse('https://media.test/v'),
          format: YlMediaFormat.dash,
          drm: widevine,
        ),
      );
      expect(
        () => YlFairPlayDrm(
          license: endpoint,
          certificate: YlDrmBytes([]),
          contentId: YlDrmBytes([1]),
        ),
        code(YlFailureCodes.drmConfigInvalid),
      );
      final fps = YlFairPlayDrm(
        license: endpoint,
        certificate: YlDrmBytes([1]),
        contentId: YlDrmBytes([2]),
      );
      expect(fps.toString(), isNot(contains('license.test')));
      expect(widevine, YlWidevineDrm(license: endpoint));
      expect(
        YlNetworkSource(Uri.parse('https://m.test/v'), drm: widevine),
        isNot(YlNetworkSource(Uri.parse('https://m.test/v'))),
      );
    },
  );
  test(
    'platform and encryption limits are explicit without changing enums',
    () {
      final config = YlWidevineDrm(
        license: endpoint,
        encryption: YlDrmEncryption.cbcs,
      );
      expect(
        () => validateYlDrmPlatform(config, TargetPlatform.iOS),
        code(YlFailureCodes.drmSchemeMismatch),
      );
      expect(
        () => validateYlDrmPlatform(
          config,
          TargetPlatform.android,
          androidApi: 24,
        ),
        code(YlFailureCodes.drmEncryptionModeUnsupported),
      );
      validateYlDrmPlatform(config, TargetPlatform.android, androidApi: 25);
      expect(
        () => validateYlDrmPlatform(config, TargetPlatform.android),
        code(YlFailureCodes.drmUnsupported),
      );
      expect(YlFailureCategory.values.map((e) => e.name), [
        'cancelled',
        'unsupported',
        'source',
        'network',
        'container',
        'decoder',
        'render',
        'resource',
        'protocol',
        'platform',
        'internal',
      ]);
    },
  );
}
