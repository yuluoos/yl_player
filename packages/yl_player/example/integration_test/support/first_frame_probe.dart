/// Test-owned measurement. All timestamps share the caller's monotonic clock;
/// the native event's implementation-local epoch is deliberately not used.
final class FirstFrameProbe {
  FirstFrameProbe({required this.nowUs});
  final int Function() nowUs;
  int? _start;
  String? _session;
  final _frames = <String, int>{};
  bool _closed = false;

  void start() {
    if (_start != null || _closed) throw StateError('Probe cannot be reused');
    _start = nowUs();
  }

  void bind(String session) {
    if (_session != null || _start == null || _closed) {
      throw StateError('Probe cannot be rebound');
    }
    _session = session;
    _frames.removeWhere((key, _) => key != session);
  }

  void observe(String session) {
    if (_closed || _start == null) return;
    if (_session != null && _session != session) return;
    final timestamp = nowUs();
    if (timestamp < _start!) throw StateError('Monotonic clock reversed');
    if (!_frames.containsKey(session) && _frames.length >= 16) {
      throw StateError('Unexpected number of candidate sessions');
    }
    _frames.putIfAbsent(session, () => timestamp);
  }

  void close() => _closed = true;

  Map<String, Object?> fields(String outcome) {
    if (_start == null) throw StateError('Probe not started');
    final timestamp = _frames[_session];
    if (outcome == 'passed' && timestamp == null) {
      throw StateError('Passed attempt has no correlated first frame');
    }
    return {
      'outcome': outcome,
      'startedUs': _start,
      'firstPresentedUs': timestamp,
      'firstFrameUs': timestamp == null ? null : timestamp - _start!,
    };
  }
}
