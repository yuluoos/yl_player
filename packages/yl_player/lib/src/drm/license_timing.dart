import 'dart:async';

/// Package-internal acceptance observer. Carries numeric wall times only.
/// Callbacks registered in this Zone retain the same observer; close the trace
/// after controller cleanup to prevent late events contaminating a later run.
final class LicenseTimingTrace {
  final _clock = Stopwatch()..start();
  final _rows = <Map<String, Object>>[];
  bool _closed = false;
  bool _entered = false;
  int _inFlight = 0;
  bool incomplete = false;
  int omitted = 0;
  List<Map<String, Object>> get rows => List.unmodifiable(_rows);
}

enum LicenseTimingPhase { transport, connect, responseHeaders, body }

final _key = Object();
LicenseTimingTrace? get currentLicenseTimingTrace =>
    Zone.current[_key] as LicenseTimingTrace?;
Future<T> withLicenseTimingTrace<T>(
  LicenseTimingTrace trace,
  Future<T> Function() body, {
  void Function(LicenseTimingTrace)? onClosed,
}) async {
  if (trace._entered) throw StateError('License trace already closed');
  trace._entered = true;
  try {
    return await runZoned(body, zoneValues: {_key: trace});
  } finally {
    trace.incomplete = trace._inFlight != 0;
    trace._closed = true;
    onClosed?.call(trace);
  }
}

Future<T> timeLicenseTransport<T>(
  Future<T> Function() body, {
  LicenseTimingTrace? owner,
  LicenseTimingPhase phase = LicenseTimingPhase.transport,
}) async {
  final trace = owner ?? currentLicenseTimingTrace;
  if (trace == null || trace._closed) return body();
  trace._inFlight++;
  final start = trace._clock.elapsedMicroseconds;
  var outcome = 'failed';
  try {
    final value = await runZoned(body, zoneValues: {_key: trace});
    outcome = 'returned';
    return value;
  } finally {
    trace._inFlight--;
    if (!trace._closed) {
      if (trace._rows.length == 128) {
        trace.omitted++;
      } else {
        trace._rows.add(
          Map.unmodifiable({
            'phase': phase.name,
            'startedUs': start,
            'endedUs': trace._clock.elapsedMicroseconds,
            'outcome': outcome,
          }),
        );
      }
    }
  }
}
