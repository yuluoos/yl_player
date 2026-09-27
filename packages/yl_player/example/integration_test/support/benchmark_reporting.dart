import 'dart:async';
import 'dart:convert';

const _conditions = {
  'schemaVersion',
  'runId',
  'caseId',
  'commit',
  'sourceHash',
  'dependencyHash',
  'artifactHash',
  'mediaHash',
  'platform',
  'device',
  'os',
  'architecture',
  'deviceKind',
  'buildMode',
  'power',
  'thermal',
  'output',
  'networkProfile',
  'cacheState',
  'measurement',
  'purpose',
  'baselineComparable',
  'plannedAttempts',
};

/// Reject unsafe inputs before any assertions or logging can echo their values.
Map<String, Object?> parseBenchmarkContext(
  String raw, {
  required String platform,
  required String buildMode,
}) {
  const invalid = FormatException('Invalid benchmark context');
  try {
    if (raw.length > 16384) throw invalid;
    final parsed = jsonDecode(raw);
    if (parsed is! Map<String, dynamic> ||
        parsed.length != _conditions.length ||
        !parsed.keys.every(_conditions.contains)) {
      throw invalid;
    }
    final token = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
    for (final field in _conditions.difference({
      'schemaVersion',
      'baselineComparable',
      'plannedAttempts',
    })) {
      final value = parsed[field];
      if (value is! String || !token.hasMatch(value)) throw invalid;
    }
    for (final field in [
      'sourceHash',
      'dependencyHash',
      'artifactHash',
      'mediaHash',
    ]) {
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(parsed[field] as String)) {
        throw invalid;
      }
    }
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(parsed['commit'] as String)) {
      throw invalid;
    }
    final attempts = parsed['plannedAttempts'];
    if (parsed['schemaVersion'] is! int ||
        parsed['schemaVersion'] != 1 ||
        parsed['baselineComparable'] is! bool ||
        attempts is! int ||
        attempts < 1 ||
        attempts > 100) {
      throw invalid;
    }
    final required = <String, String>{
      'platform': platform,
      'buildMode': buildMode,
      'purpose': 'smoke',
      'caseId': 'local-avc-aac-mkv',
      'cacheState': 'os-cache-uncontrolled',
      'measurement': 'load-to-public-first-frame-event',
      'networkProfile': 'local-file',
    };
    for (final entry in required.entries) {
      if (parsed[entry.key] != entry.value) throw invalid;
    }
    if (!['physical', 'simulator', 'emulator'].contains(parsed['deviceKind']) ||
        !['ac', 'battery', 'unknown'].contains(parsed['power']) ||
        ![
          'nominal',
          'fair',
          'serious',
          'critical',
          'unknown',
        ].contains(parsed['thermal'])) {
      throw invalid;
    }
    return Map<String, Object?>.unmodifiable(parsed);
  } catch (_) {
    throw invalid; // No decoder source text or supplied value reaches logs.
  }
}

/// Preserve the observation synchronously, then give cleanup a finite deadline.
/// On cleanup failure the final row cannot retain a successful outcome. The
/// caller must abort further playback attempts (late cleanup may still run).
Future<bool> recordBenchmarkTrial({
  required Map<String, Object?> row,
  required void Function(Map<String, Object?>) observe,
  required void Function(Map<String, Object?>) record,
  required Future<void> Function() cleanup,
  Duration cleanupTimeout = const Duration(seconds: 5),
}) async {
  observe(Map<String, Object?>.unmodifiable(row));
  var cleaned = false;
  try {
    await cleanup().timeout(cleanupTimeout);
    cleaned = true;
  } catch (_) {
    // Timing/exception details are intentionally not logged.
  }
  record({
    ...row,
    if (!cleaned && row['outcome'] == 'passed') 'outcome': 'failed',
  });
  return cleaned;
}
