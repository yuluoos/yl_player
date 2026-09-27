import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/benchmark_reporting.dart';

Map<String, Object?> context() => {
  'schemaVersion': 1,
  'runId': 'run-1',
  'caseId': 'local-avc-aac-mkv',
  'commit': 'a' * 40,
  'sourceHash': 'b' * 64,
  'dependencyHash': 'c' * 64,
  'artifactHash': 'd' * 64,
  'mediaHash': 'e' * 64,
  'platform': 'macos',
  'device': 'MacBookPro17-1',
  'os': 'macOS-27',
  'architecture': 'arm64',
  'deviceKind': 'physical',
  'buildMode': 'debug',
  'power': 'unknown',
  'thermal': 'unknown',
  'output': 'unverified',
  'networkProfile': 'local-file',
  'cacheState': 'os-cache-uncontrolled',
  'measurement': 'load-to-public-first-frame-event',
  'purpose': 'smoke',
  'baselineComparable': true,
  'plannedAttempts': 3,
};

void main() {
  test('rejects extra secret fields and unsafe values before logging', () {
    for (final changes in [
      {'url': 'https://host.test/private-token'},
      {'device': 'https://host.test/private-token'},
      {'buildMode': 'private-token'},
      {'plannedAttempts': 0},
    ]) {
      try {
        parseBenchmarkContext(
          jsonEncode({...context(), ...changes}),
          platform: 'macos',
          buildMode: 'debug',
        );
        fail('Invalid context accepted');
      } on FormatException catch (error) {
        expect(error.toString(), isNot(contains('private-token')));
        expect(error.toString(), isNot(contains('host.test')));
      }
    }
    final result = parseBenchmarkContext(
      jsonEncode(context()),
      platform: 'macos',
      buildMode: 'debug',
    );
    expect(result['plannedAttempts'], 3);
    expect(() => result['url'] = 'unsafe', throwsUnsupportedError);
  });
  test(
    'persists observation before cleanup and records timeout as failure',
    () async {
      final observations = <Map<String, Object?>>[];
      final records = <Map<String, Object?>>[];
      final cleanup = Completer<void>();
      final result = recordBenchmarkTrial(
        row: {'outcome': 'passed', 'firstFrameUs': 100},
        observe: observations.add,
        record: records.add,
        cleanup: () => cleanup.future,
        cleanupTimeout: const Duration(milliseconds: 10),
      );
      expect(observations.single['firstFrameUs'], 100);
      expect(records, isEmpty);
      expect(await result, isFalse);
      expect(records.single['outcome'], 'failed');
      expect(records.single['firstFrameUs'], 100);
      cleanup.complete();
      await Future<void>.delayed(Duration.zero);
      expect(records, hasLength(1));
    },
  );
  test(
    'cleanup exceptions cannot erase an observed playback timeout',
    () async {
      final observations = <Map<String, Object?>>[];
      final records = <Map<String, Object?>>[];
      expect(
        await recordBenchmarkTrial(
          row: {'outcome': 'timeout', 'firstFrameUs': null},
          observe: observations.add,
          record: records.add,
          cleanup: () async => throw StateError('native secret'),
        ),
        isFalse,
      );
      expect(observations.single['outcome'], 'timeout');
      expect(records.single['outcome'], 'timeout');
      expect(jsonEncode(records), isNot(contains('native secret')));
    },
  );
  test('successful cleanup preserves original outcome exactly once', () async {
    final rows = <Map<String, Object?>>[];
    expect(
      await recordBenchmarkTrial(
        row: {'outcome': 'passed', 'firstFrameUs': 20},
        observe: (_) {},
        record: rows.add,
        cleanup: () async {},
      ),
      isTrue,
    );
    expect(rows.single, {'outcome': 'passed', 'firstFrameUs': 20});
  });
}
