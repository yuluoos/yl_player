import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/benchmark_trials.dart';

void main() {
  test(
    'setup failure retains every planned attempt without false frame',
    () async {
      final rows = <Map<String, Object?>>[];
      await runBenchmarkTrials(
        attempts: 3,
        nowUs: () => 100,
        body: (_) async => throw StateError('private setup error'),
        record: rows.add,
      );
      expect(rows, hasLength(3));
      expect(rows.map((r) => r['outcome']), ['failed', 'failed', 'failed']);
      expect(rows.every((r) => r['firstFrameUs'] == null), isTrue);
      expect(rows.toString(), isNot(contains('private')));
    },
  );
  test(
    'cleanup failure runs other cleanup and explicitly skips remaining trials',
    () async {
      final rows = <Map<String, Object?>>[];
      final calls = <String>[];
      await runBenchmarkTrials(
        attempts: 3,
        nowUs: () => 100,
        body: (trial) async {
          trial.cleanup.add(() async {
            calls.add('dispose');
            throw StateError('private');
          });
          trial.cleanup.add(() async => calls.add('unmount'));
          trial.probe.start();
          trial.probe.bind('a');
          trial.probe.observe('a');
        },
        record: rows.add,
      );
      expect(calls, ['dispose', 'unmount']);
      expect(rows.map((r) => r['outcome']), ['failed', 'skipped', 'skipped']);
      expect(rows.first['firstFrameUs'], 0);
    },
  );
  test(
    'late creation is released once and never permits next playback',
    () async {
      final creation = Completer<int>();
      var disposed = 0;
      var bodies = 0;
      final rows = <Map<String, Object?>>[];
      await runBenchmarkTrials(
        attempts: 2,
        nowUs: () => 0,
        body: (trial) async {
          bodies++;
          await trial.create(
            creation.future,
            release: (_) async => disposed++,
            timeout: const Duration(milliseconds: 5),
          );
        },
        record: rows.add,
      );
      expect(rows.map((r) => r['outcome']), ['timeout', 'skipped']);
      creation.complete(1);
      await Future<void>.delayed(Duration.zero);
      expect(disposed, 1);
      expect(bodies, 1);
    },
  );
  test(
    'successful frame preserves pre-load clock and old sessions do not win',
    () async {
      var clock = 10;
      final rows = <Map<String, Object?>>[];
      await runBenchmarkTrials(
        attempts: 1,
        nowUs: () => clock,
        body: (trial) async {
          clock = 50;
          trial.probe.start();
          clock = 80;
          trial.probe.observe('old');
          clock = 100;
          trial.probe.observe('new');
          trial.probe.bind('new');
        },
        record: rows.add,
      );
      expect(rows.single['startedUs'], 50);
      expect(rows.single['firstPresentedUs'], 100);
      expect(rows.single['firstFrameUs'], 50);
      expect(rows.single['outcome'], 'passed');
    },
  );
}
