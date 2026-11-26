import 'dart:typed_data';

/// A VOD segment uses the shared 45 kHz manifest clock. DVD packs are remuxed
/// on demand, while Blu-ray packet ranges can be served directly from UDF.
abstract interface class IsoSegment {
  int get ticks;
  bool get discontinuity;

  /// A full network GET can start reading its body while preparing headers.
  /// Leave the hint off for HEAD and partial requests.
  Future<IsoPayload> openPayload({bool fullNetworkRead = false});
}

abstract interface class IsoPayload {
  int get length;
  Stream<Uint8List> read(int start, int stop);
}

/// Session-local LRU of completed DVD remuxes. Concurrent probes and ranges
/// for a segment share its producer, even while other segments are requested.
final class DvdSegmentCache {
  DvdSegmentCache({this.capacityBytes = 16 * 1024 * 1024});
  final int capacityBytes;
  final _ready = <int, IsoPayload>{};
  final _pending = <int, Future<IsoPayload>>{};
  int _bytes = 0;
  bool _closed = false;

  Future<IsoPayload> get(int index, IsoSegment segment) {
    if (_closed) return Future.error(StateError('Closed DVD segment cache'));
    final hit = _ready.remove(index);
    if (hit != null) {
      _ready[index] = hit;
      return Future.value(hit);
    }
    return _pending.putIfAbsent(index, () => _load(index, segment));
  }

  Future<IsoPayload> _load(int index, IsoSegment segment) async {
    try {
      final payload = await Future.sync(segment.openPayload);
      if (!_closed && payload.length <= capacityBytes) {
        while (_bytes + payload.length > capacityBytes || _ready.length >= 64) {
          _bytes -= _ready.remove(_ready.keys.first)!.length;
        }
        _ready[index] = payload;
        _bytes += payload.length;
      }
      return payload;
    } finally {
      _pending.remove(index);
    }
  }

  void close() {
    _closed = true;
    _ready.clear();
    _pending.clear();
    _bytes = 0;
  }
}
