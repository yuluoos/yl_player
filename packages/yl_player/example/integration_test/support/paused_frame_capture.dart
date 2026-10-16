import 'dart:async';

/// Samples a paused surface before allowing playback to leave its marker window.
/// Waits for actual consumption via [readyToPause] before pausing after a seek.
/// A null read retries while paused; timeout/read errors never invoke [resume].
/// The caller owns readback-clock cleanup on every exit. [resume] must release
/// that clock before requesting public playback. [timeout] bounds polling, so
/// callbacks that can block must also enforce their own command deadlines.
Future<int> capturePausedFrame({
  required Future<bool> Function() readyToPause,
  required Future<void> Function() pause,
  required Future<int?> Function() read,
  required Future<void> Function() resume,
  Duration timeout = const Duration(seconds: 2),
  Duration pollInterval = const Duration(milliseconds: 20),
}) async {
  final timer = Stopwatch()..start();
  while (!await readyToPause()) {
    if (timer.elapsed >= timeout) {
      throw TimeoutException(
        'Audio consumption did not become ready for paused capture',
        timeout,
      );
    }
    await Future<void>.delayed(pollInterval);
  }
  await pause();
  while (timer.elapsed < timeout) {
    final value = await read();
    if (value != null) {
      await resume();
      return value;
    }
    await Future<void>.delayed(pollInterval);
  }
  throw TimeoutException('Paused surface did not provide a frame', timeout);
}

/// Waits for native effects after the public seek command acknowledges intent.
Future<void> waitForNativePhase(
  Future<bool> Function() ready, {
  Duration timeout = const Duration(seconds: 5),
  Duration pollInterval = const Duration(milliseconds: 20),
}) async {
  final timer = Stopwatch()..start();
  while (!await ready()) {
    if (timer.elapsed >= timeout) {
      throw TimeoutException(
        'Native audio reset did not complete after seek',
        timeout,
      );
    }
    await Future<void>.delayed(pollInterval);
  }
}

/// Collects a phase until public state and the captured native consumption agree.
Future<void> captureNativePhase({
  required bool Function() done,
  required Future<int?> Function() capture,
  required int minimumNativeClockUs,
  Duration timeout = const Duration(seconds: 12),
}) async {
  final timer = Stopwatch()..start();
  int? consumed;
  while (!done() || consumed == null || consumed < minimumNativeClockUs) {
    if (timer.elapsed >= timeout) {
      throw TimeoutException(
        'Native consumption did not reach the phase target',
        timeout,
      );
    }
    consumed = await capture();
  }
}
