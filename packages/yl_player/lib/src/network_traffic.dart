import 'dart:async';

/// Samples observed byte deltas only while a consumer subscribes. Backend
/// counters belong to the newest load, independently of playback commit.
final class NetworkTrafficSampler {
  NetworkTrafficSampler(this._source, {int Function()? nowMicroseconds})
    : _clock = nowMicroseconds {
    _rates = StreamController<int?>.broadcast(
      sync: true,
      onListen: _start,
      onCancel: _stop,
    );
  }

  final Stream<int?> _source;
  final int Function()? _clock;
  final _watch = Stopwatch();
  late final StreamController<int?> _rates;
  StreamSubscription<int?>? _subscription;
  Timer? _timer;
  int _generation = 0;
  int? _bytes;
  int? _sampleBytes;
  int? _rate;
  int _sampleTime = 0;
  bool _disposed = false;

  int get _now => _clock?.call() ?? _watch.elapsedMicroseconds;

  Stream<int?> get rates => Stream<int?>.multi((listener) {
    if (_disposed) {
      listener.close();
      return;
    }
    final subscription = _rates.stream.listen(
      listener.add,
      onDone: listener.close,
    );
    listener.add(_rate);
    listener.onCancel = subscription.cancel;
    listener.onPause = subscription.pause;
    listener.onResume = subscription.resume;
  });

  void _start() {
    if (_disposed) return;
    final generation = ++_generation;
    _watch.start();
    _bytes = _sampleBytes = _rate = null;
    _sampleTime = _now;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _sample());
    _subscription = _source.listen(
      (bytes) {
        if (_disposed || generation != _generation) return;
        if (bytes == null || bytes < 0) {
          _bytes = _sampleBytes = null;
          _sampleTime = _now;
          _publish(null);
          return;
        }
        final previous = _bytes;
        if (previous == null || bytes < previous) {
          // A first observation may include an arbitrary history. Establish
          // its baseline rather than showing all historical bytes as a burst.
          _sampleBytes = bytes;
          _sampleTime = _now;
          _publish(0);
        }
        _bytes = bytes;
      },
      onError: (Object _) {
        if (_disposed || generation != _generation) return;
        _bytes = _sampleBytes = null;
        _publish(null);
      },
      onDone: () {
        if (_disposed || generation != _generation) return;
        _timer?.cancel();
        _timer = null;
        _publish(null);
      },
    );
  }

  void _sample() {
    final bytes = _bytes;
    final previous = _sampleBytes;
    if (_disposed || bytes == null || previous == null) return;
    final now = _now;
    final elapsed = now - _sampleTime;
    if (elapsed <= 0) return;
    final delta = bytes - previous;
    _sampleBytes = bytes;
    _sampleTime = now;
    _publish(
      delta <= 0
          ? 0
          : (delta / elapsed * Duration.microsecondsPerSecond).round(),
    );
  }

  void _publish(int? value) {
    if (_disposed || _rates.isClosed) return;
    _rate = value;
    _rates.add(value);
  }

  Future<void> _stop() async {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _watch.stop();
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stop();
    // A paused external observer must not block native player disposal.
    unawaited(_rates.close());
  }
}
