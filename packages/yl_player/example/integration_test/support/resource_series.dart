import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

const resourcePhases = ['idle', 'opening', 'playing', 'disposing', 'disposed'];
const _keys = {
  'monotonicUs',
  'cpuUs',
  'rssBytes',
  'footprintBytes',
  'thermal',
  'power',
  'status',
};

// A timeout does not cancel native creation. Retain ownership of late values;
// the caller records a timeout and never starts another trial after it.
Future<T> createResourceOwner<T>(
  Future<T> creation, {
  required Duration timeout,
  required Future<void> Function(T) release,
}) {
  var expired = false;
  final owned = creation.then((value) async {
    if (expired) {
      try {
        await release(value).timeout(const Duration(seconds: 5));
      } catch (_) {
        // The trial is already unsuccessful; do not leak late native errors.
      }
      throw TimeoutException('Resource creation expired');
    }
    return value;
  });
  return owned.timeout(
    timeout,
    onTimeout: () {
      expired = true;
      throw TimeoutException('Resource creation expired');
    },
  );
}

Map<String, Object?> Function() openResourceSampler(String path) {
  final library = DynamicLibrary.open(path);
  final snapshot = library
      .lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>(
        'yl_resource_snapshot',
      );
  return () {
    final pointer = snapshot();
    if (pointer == nullptr) {
      throw const FormatException('Resource sampling failed');
    }
    final bytes = <int>[];
    for (var i = 0; i < 1024; i++) {
      final value = pointer[i];
      if (value == 0) {
        final raw = jsonDecode(utf8.decode(bytes));
        if (raw is! Map<String, dynamic>) {
          throw const FormatException('Invalid resource snapshot');
        }
        return raw.cast<String, Object?>();
      }
      bytes.add(value);
    }
    throw const FormatException('Invalid resource snapshot');
  };
}

class ResourceSeries {
  ResourceSeries({required this.read});
  final Map<String, Object?> Function() read;
  final _samples = <Map<String, Object?>>[];
  String? _phase;
  bool _closed = false;

  void enter(String phase) {
    if (_closed ||
        !resourcePhases.contains(phase) ||
        (_phase != null &&
            resourcePhases.indexOf(phase) < resourcePhases.indexOf(_phase!))) {
      throw StateError('Invalid resource phase');
    }
    _phase = phase;
    sample();
  }

  void sample() {
    if (_closed || _phase == null || _samples.length >= 256) {
      throw StateError('Resource recording unavailable');
    }
    final row = read();
    bool integer(Object? v) => v is int && v >= 0 && v <= 9007199254740991;
    if (row.length != _keys.length ||
        !_keys.every(row.containsKey) ||
        !integer(row['monotonicUs']) ||
        !['ok', 'unavailable'].contains(row['status']) ||
        ![
          'nominal',
          'fair',
          'serious',
          'critical',
          'unknown',
        ].contains(row['thermal']) ||
        !['ac', 'battery', 'unknown'].contains(row['power']) ||
        !['cpuUs', 'rssBytes', 'footprintBytes'].every(
          (key) => row['status'] == 'ok' ? integer(row[key]) : row[key] == null,
        ) ||
        (_samples.isNotEmpty &&
            (row['monotonicUs'] as int) <=
                (_samples.last['monotonicUs'] as int))) {
      throw const FormatException('Invalid resource snapshot');
    }
    _samples.add(Map.unmodifiable({...row, 'phase': _phase}));
  }

  List<Map<String, Object?>> close() {
    _closed = true;
    return List.unmodifiable(_samples);
  }
}
