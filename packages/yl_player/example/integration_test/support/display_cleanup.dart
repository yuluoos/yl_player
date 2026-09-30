import 'dart:async';
import 'resource_series.dart';

/// Owns creation uncertainty and independent cleanup for one display trial.
final class DisplayTrialCleanup {
  bool _creationUnconfirmed = false;

  Future<T> create<T>(
    Future<T> creation, {
    required Duration timeout,
    required Future<void> Function(T) release,
  }) async {
    _creationUnconfirmed = true;
    final value = await createResourceOwner(
      creation,
      timeout: timeout,
      release: release,
    );
    _creationUnconfirmed = false;
    return value;
  }

  Future<bool> run(
    List<Future<void> Function()> steps, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // The creation helper still owns late instances. It does not confirm their
    // release here, so a failed handoff cannot be reported as cleaned.
    var cleaned = !_creationUnconfirmed;
    for (final step in steps) {
      try {
        await Future<void>.sync(step).timeout(timeout);
      } catch (_) {
        cleaned = false;
      }
    }
    return cleaned;
  }
}
