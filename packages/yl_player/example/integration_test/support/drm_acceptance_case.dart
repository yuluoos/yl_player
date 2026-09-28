import 'dart:convert';

const _invalid = FormatException(
  'DRM acceptance configuration is missing or invalid.',
);
const _fields = {
  'caseId',
  'platform',
  'mediaUrl',
  'licenseUrl',
  'licenseHeaders',
  'licenseCredentials',
  'certificateBase64',
  'contentIdBase64',
  'mediaSha256',
  'authorizationScope',
  'authorizationExpiresAt',
  'deviceId',
  'deviceModel',
  'osVersion',
  'physicalDevice',
  'outputPath',
  'seekPositionMs',
};
const drmCaseIds = {
  'android': 'android-widevine',
  'ios': 'ios-fairplay',
  'macos': 'macos-fairplay',
};

/// Pure Dart: shared by the offline preflight and the on-device test. Never log
/// the private definition; this type's report contains only allowlisted metadata.
final class DrmAcceptanceCase {
  DrmAcceptanceCase._(this._definition, this.missing);
  final Map<String, dynamic> _definition;
  final List<String> missing;
  String get caseId => _definition['caseId'] as String;
  String get platform => _definition['platform'] as String;

  static DrmAcceptanceCase inspect(Object? input, {required DateTime now}) {
    try {
      if (input is! Map<String, dynamic> ||
          input.keys.any((key) => !_fields.contains(key))) {
        throw _invalid;
      }
      final platform = input['platform'];
      if (!drmCaseIds.containsKey(platform) ||
          input['caseId'] != drmCaseIds[platform]) {
        throw _invalid;
      }
      final problems = <String>[];
      void require(String key, bool Function(Object?) accepts) {
        if (!accepts(input[key])) problems.add(key);
      }

      require('mediaUrl', _https);
      require('licenseUrl', _https);
      final seenHeaders = <String>{};
      for (final key in ['licenseHeaders', 'licenseCredentials']) {
        require(key, (value) {
          if (value is! Map<String, dynamic> || value.length > 32) return false;
          for (final entry in value.entries) {
            final lower = entry.key.toLowerCase();
            if (!RegExp(
                  r"^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,128}$",
                ).hasMatch(entry.key) ||
                !seenHeaders.add(lower) ||
                const [
                  'host',
                  'content-length',
                  'connection',
                  'transfer-encoding',
                  'range',
                  'if-range',
                  'content-type',
                  'accept-encoding',
                ].contains(lower) ||
                key == 'licenseHeaders' &&
                    RegExp(
                      'auth|cookie|token|key|secret|credential',
                    ).hasMatch(lower) ||
                entry.value is! String ||
                (entry.value as String).length > 8192 ||
                RegExp(r'[\x00-\x1f\x7f]').hasMatch(entry.value as String)) {
              return false;
            }
          }
          return true;
        });
      }
      if (platform == 'android') {
        require('certificateBase64', (v) => v == '');
        require('contentIdBase64', (v) => v == '');
      } else {
        require('certificateBase64', (v) => _binary(v, 65536));
        require('contentIdBase64', (v) => _binary(v, 8192));
      }
      require(
        'mediaSha256',
        (v) => v is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(v),
      );
      require('authorizationScope', (v) => v == 'drm-playback-testing');
      require('authorizationExpiresAt', (v) {
        if (v is! String ||
            !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$').hasMatch(v)) {
          return false;
        }
        final expires = DateTime.tryParse(v);
        return expires != null &&
            expires.toIso8601String().replaceFirst('.000Z', 'Z') == v &&
            expires.isAfter(now);
      });
      for (final key in ['deviceId', 'deviceModel', 'osVersion']) {
        require(
          key,
          (v) =>
              v is String &&
              v.trim().isNotEmpty &&
              v.length <= 256 &&
              !RegExp(r'[\x00-\x1f\x7f]').hasMatch(v),
        );
      }
      require('physicalDevice', (v) => v == true);
      require('outputPath', (v) => v == 'internal');
      require('seekPositionMs', (v) => v is int && v >= 1000 && v <= 600000);
      final copy = jsonDecode(jsonEncode(input)) as Map<String, dynamic>;
      return DrmAcceptanceCase._(copy, List.unmodifiable(problems));
    } catch (_) {
      throw _invalid;
    }
  }

  static DrmAcceptanceCase forRuntime(
    String encoded, {
    required String platform,
    required DateTime now,
  }) {
    try {
      if (encoded.isEmpty || utf8.encode(encoded).length > 1024 * 1024) {
        throw _invalid;
      }
      final value = inspect(jsonDecode(encoded), now: now);
      if (value.platform != platform || value.missing.isNotEmpty) {
        throw _invalid;
      }
      return value;
    } catch (_) {
      throw _invalid;
    }
  }

  Map<String, dynamic> runtimeDefinition({required DateTime now}) {
    final current = inspect(_definition, now: now);
    if (current.missing.isNotEmpty) throw _invalid;
    return jsonDecode(jsonEncode(_definition)) as Map<String, dynamic>;
  }

  Map<String, Object?> get report => {
    'caseId': caseId,
    'platform': platform,
    'scheme': platform == 'android' ? 'widevine-cenc' : 'fairplay-hls',
    'implementation': 'implemented',
    'verification': missing.isEmpty ? 'not_run' : 'external_missing',
    'physicalAcceptance': 'not_run',
    'declaredMediaSha256': missing.contains('mediaSha256')
        ? null
        : _definition['mediaSha256'],
    'mediaHashVerified': false,
    'missing': missing,
    'manualEvidenceRequired': const [
      'authorization_and_resource_provenance',
      'physical_device_and_build',
      'actual_picture_and_sound',
      'key_rotation_and_expiry',
      'background_recovery',
      'period_transition',
      'negative_license_cases',
      'cancel_inflight_license',
      'subtitles_and_geometry',
      'external_protection',
    ],
  };

  static bool _https(Object? value) {
    if (value is! String ||
        value.length > 8192 ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(value)) {
      return false;
    }
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasFragment &&
        uri.port > 0 &&
        uri.port <= 65535;
  }

  static bool _binary(Object? value, int maxBytes) {
    if (value is! String || value.length > ((maxBytes + 2) ~/ 3) * 4) {
      return false;
    }
    try {
      final bytes = base64Decode(value);
      return bytes.isNotEmpty &&
          bytes.length <= maxBytes &&
          base64Encode(bytes) == value;
    } catch (_) {
      return false;
    }
  }

  @override
  String toString() => 'DrmAcceptanceCase(<redacted>)';
}

List<DrmAcceptanceCase> inspectDrmInventory(
  String encoded, {
  required DateTime now,
}) {
  try {
    if (utf8.encode(encoded).length > 1024 * 1024) throw _invalid;
    final root = jsonDecode(encoded);
    if (root is! Map<String, dynamic> ||
        root.length != 2 ||
        root['schemaVersion'] != 1 ||
        root['cases'] is! List) {
      throw _invalid;
    }
    final cases = root['cases'] as List;
    if (cases.isEmpty || cases.length > 3) throw _invalid;
    final seen = <String>{};
    return List.unmodifiable(
      cases.map((raw) {
        final value = DrmAcceptanceCase.inspect(raw, now: now);
        if (!seen.add(value.caseId)) throw _invalid;
        return value;
      }),
    );
  } catch (_) {
    throw _invalid;
  }
}
