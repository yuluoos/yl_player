import 'dart:async';
import 'display_cleanup.dart';
import 'first_frame_probe.dart';

/// Owns all resources acquired during setup as well as public Load timing.
final class BenchmarkTrial {
  BenchmarkTrial(int Function() nowUs) : probe = FirstFrameProbe(nowUs: nowUs);
  final FirstFrameProbe probe;
  final cleanup = <Future<void> Function()>[];
  final _ownership = DisplayTrialCleanup();

  Future<T> create<T>(
    Future<T> creation, {
    required Future<void> Function(T) release,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final value = await _ownership.create(
      creation,
      timeout: timeout,
      release: release,
    );
    cleanup.add(() => release(value));
    return value;
  }
}

/// Every declared attempt produces exactly one row, even if setup fails.
/// Unknown creation/disposal prevents another playback from contaminating it.
Future<void> runBenchmarkTrials({
  required int attempts,
  required int Function() nowUs,
  required Future<void> Function(BenchmarkTrial) body,
  required void Function(Map<String, Object?>) record,
}) async {
  if (attempts < 1 || attempts > 100) {
    throw const FormatException('Invalid benchmark attempt count');
  }
  var aborted = false;
  for (var attempt = 1; attempt <= attempts; attempt++) {
    final started = nowUs();
    final trial = BenchmarkTrial(nowUs);
    var outcome = aborted ? 'skipped' : 'failed';
    if (!aborted) {
      try {
        await body(trial);
        // Validate a correlated observation before assigning success.
        trial.probe.fields('passed');
        outcome = 'passed';
      } on TimeoutException {
        outcome = 'timeout';
      } catch (_) {
        outcome = 'failed';
      }
    }
    trial.probe.close();
    final observation = trial.probe.hasStarted
        ? trial.probe.fields(outcome)
        : <String, Object?>{
            'outcome': outcome,
            'startedUs': started,
            'firstPresentedUs': null,
            'firstFrameUs': null,
          };
    final cleaned = await trial._ownership.run(trial.cleanup);
    if (!cleaned) {
      aborted = true;
      if (outcome == 'passed') observation['outcome'] = 'failed';
    }
    record({'attempt': attempt, ...observation});
  }
}
