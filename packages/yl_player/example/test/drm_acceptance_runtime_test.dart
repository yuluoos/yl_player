import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import '../integration_test/support/drm_acceptance_case.dart';
import '../integration_test/support/drm_acceptance_runtime.dart';
import 'drm_acceptance_case_test.dart' as fixtures;

void main() {
  for (final platform in ['android', 'ios', 'macos']) {
    test(
      '$platform fault source isolates license credentials and preserves DRM',
      () {
        final resource = DrmAcceptanceCase.inspect(
          fixtures.valid(platform),
          now: fixtures.now,
        );
        final original = drmAcceptanceSource(resource, now: fixtures.now);
        final override = YlDrmLicenseEndpoint(
          Uri.parse('http://127.0.0.1:12345/license'),
          allowInsecureLoopback: true,
        );
        final fault = drmAcceptanceSource(
          resource,
          now: fixtures.now,
          license: override,
        );
        expect(fault.uri, original.uri);
        expect(fault.format, original.format);
        expect(fault.drm!.license, same(override));
        expect(fault.drm!.license.request.credentials, isEmpty);
        expect(fault.request.credentials, isEmpty);
        expect(
          original.drm!.license.request.credentials['Authorization'],
          'Bearer HEADER_SECRET',
        );
        if (fault.drm case YlFairPlayDrm(
          :final certificate,
          :final contentId,
        )) {
          expect(certificate, (original.drm! as YlFairPlayDrm).certificate);
          expect(contentId, (original.drm! as YlFairPlayDrm).contentId);
        } else {
          expect(fault.drm, isA<YlWidevineDrm>());
        }
      },
    );
  }
  test('fault override cannot bypass expired authorization', () {
    final resource = DrmAcceptanceCase.inspect(
      fixtures.valid('ios'),
      now: fixtures.now,
    );
    expect(
      () => drmAcceptanceSource(
        resource,
        now: DateTime.utc(2026, 10, 2),
        license: YlDrmLicenseEndpoint(Uri.parse('https://fault.test/license')),
      ),
      throwsFormatException,
    );
  });
  test('negative observation rejects success and untyped failure', () async {
    expect(await drmCaptureLoadFailure(Future.value(Object())), isNull);
    expect(
      await drmCaptureLoadFailure(Future.error(StateError('PRIVATE'))),
      isNull,
    );
  });
  test(
    'negative observation preserves typed code for exact matching',
    () async {
      final failure = YlFailure(
        code: YlFailureCodes.drmLicenseDenied,
        category: YlFailureCategory.source,
        scope: YlFailureScope.command,
        message: 'PRIVATE',
        retryable: false,
        diagnosticId: 'private',
      );
      expect(
        await drmCaptureLoadFailure(Future.error(YlPlayerException(failure))),
        YlFailureCodes.drmLicenseDenied,
      );
    },
  );
  test('unexpected native or provider text is never reported', () {
    expect(drmSafeCode(StateError('PRIVATE_LICENSE')), 'drm.acceptance_failed');
  });
}
