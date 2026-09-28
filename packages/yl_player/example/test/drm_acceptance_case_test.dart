import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/drm_acceptance_case.dart';

final now = DateTime.utc(2026, 9, 28);
Map<String, Object?> valid(String platform) => {
  'caseId': '$platform-${platform == 'android' ? 'widevine' : 'fairplay'}',
  'platform': platform,
  'mediaUrl': 'https://media.test/protected?token=MEDIA_SECRET',
  'licenseUrl': 'https://license.test/exchange?token=LICENSE_SECRET',
  'licenseHeaders': {'Accept': 'application/octet-stream'},
  'licenseCredentials': {'Authorization': 'Bearer HEADER_SECRET'},
  'certificateBase64': platform == 'android' ? '' : base64Encode([1, 2]),
  'contentIdBase64': platform == 'android' ? '' : base64Encode([3]),
  'mediaSha256': List.filled(64, 'a').join(),
  'authorizationScope': 'drm-playback-testing',
  'authorizationExpiresAt': '2026-10-01T00:00:00Z',
  'deviceId': 'PRIVATE_DEVICE',
  'deviceModel': 'PRIVATE_MODEL',
  'osVersion': 'PRIVATE_OS',
  'physicalDevice': true,
  'outputPath': 'internal',
  'seekPositionMs': 5000,
};

void main() {
  for (final platform in ['android', 'ios', 'macos']) {
    test('$platform valid resource declarations remain not_run', () {
      final candidate = DrmAcceptanceCase.inspect(valid(platform), now: now);
      expect(candidate.missing, isEmpty);
      expect(candidate.report['verification'], 'not_run');
      expect(candidate.report['physicalAcceptance'], 'not_run');
      final report = jsonEncode(candidate.report);
      for (final secret in [
        'MEDIA_SECRET',
        'LICENSE_SECRET',
        'HEADER_SECRET',
        'PRIVATE_',
      ]) {
        expect(report, isNot(contains(secret)));
      }
      expect(candidate.runtimeDefinition(now: now)['caseId'], candidate.caseId);
    });
  }
  test(
    'missing resources cannot generate a runtime case or passing evidence',
    () {
      final input = valid('ios')
        ..['mediaUrl'] = ''
        ..['certificateBase64'] = ''
        ..['physicalDevice'] = false;
      final candidate = DrmAcceptanceCase.inspect(input, now: now);
      expect(
        candidate.missing,
        containsAll(['mediaUrl', 'certificateBase64', 'physicalDevice']),
      );
      expect(candidate.report['verification'], 'external_missing');
      expect(
        () => candidate.runtimeDefinition(now: now),
        throwsFormatException,
      );
    },
  );
  test(
    'expired authorization and wrong platform are rejected again at execution',
    () {
      final candidate = DrmAcceptanceCase.inspect(valid('ios'), now: now);
      expect(
        () => candidate.runtimeDefinition(now: DateTime.utc(2026, 10, 2)),
        throwsFormatException,
      );
      expect(
        () => DrmAcceptanceCase.forRuntime(
          jsonEncode(valid('ios')),
          platform: 'android',
          now: now,
        ),
        throwsFormatException,
      );
    },
  );
  test('binary bounds and nonbinary envelopes fail closed', () {
    for (final value in ['not-base64!', base64Encode(List.filled(65537, 1))]) {
      final candidate = DrmAcceptanceCase.inspect(
        valid('ios')..['certificateBase64'] = value,
        now: now,
      );
      expect(candidate.missing, contains('certificateBase64'));
    }
    final candidate = DrmAcceptanceCase.inspect(
      valid('ios')..['contentIdBase64'] = base64Encode(List.filled(8193, 1)),
      now: now,
    );
    expect(candidate.missing, contains('contentIdBase64'));
  });
  test(
    'untrusted URLs credentials and unknown fields never appear in errors',
    () {
      final cases = [
        valid('ios')..['mediaUrl'] = 'http://media.test/SECRET',
        valid('ios')..['licenseUrl'] = 'https://user:SECRET@license.test',
        valid('ios')..['licenseHeaders'] = {'Authorization': 'SECRET'},
        valid('ios')
          ..['licenseCredentials'] = {'Cookie': 'SECRET\r\nInjected: yes'},
        valid('ios')..['authorizationExpiresAt'] = '2026-02-31T00:00:00Z',
        valid('ios')..['mediaSha256'] = 'SECRET',
      ];
      for (final value in cases) {
        final candidate = DrmAcceptanceCase.inspect(value, now: now);
        expect(candidate.missing, isNotEmpty);
        expect(jsonEncode(candidate.report), isNot(contains('SECRET')));
      }
      try {
        DrmAcceptanceCase.inspect(
          valid('ios')..['SECRET'] = 'SECRET',
          now: now,
        );
        fail('Unknown private fields accepted');
      } on FormatException catch (error) {
        expect(error.toString(), isNot(contains('SECRET')));
      }
    },
  );
  test(
    'inventory bounds duplicate owners and malformed data have safe failures',
    () {
      for (final value in [
        '{SECRET',
        jsonEncode({
          'schemaVersion': 1,
          'cases': [valid('ios'), valid('ios')],
        }),
        jsonEncode({
          'schemaVersion': 2,
          'cases': [valid('ios')],
        }),
        jsonEncode({'schemaVersion': 1, 'cases': []}),
        'x' * (1024 * 1024 + 1),
      ]) {
        expect(
          () => inspectDrmInventory(value, now: now),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'missing configuration is an explicit failure rather than a skipped test',
    () {
      expect(
        () => DrmAcceptanceCase.forRuntime('', platform: 'ios', now: now),
        throwsFormatException,
      );
    },
  );
}
