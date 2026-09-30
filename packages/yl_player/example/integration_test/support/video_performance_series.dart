/// System renderer counters, not presentation timestamps or physical output.
final class VideoPerformanceSeries {
  final _rows = <Map<String, Object?>>[];
  Map<String, Object?>? _first, _last;
  bool _valid = true;
  static const _counters = ['totalFrames', 'droppedFrames', 'corruptedFrames'];
  static const _values = [..._counters, 'totalFrameDelaySeconds'];
  List<Map<String, Object?>> get observations => List.unmodifiable(_rows);
  bool get complete =>
      _valid &&
      _first != null &&
      _last != null &&
      (_last!['totalFrames'] as int) > (_first!['totalFrames'] as int);
  Map<String, Object?>? get delta => !complete
      ? null
      : Map.unmodifiable({
          'observationWindowUs':
              (_last!['receivedUs'] as int) - (_first!['receivedUs'] as int),
          for (final key in _values)
            key: (_last![key] as num) - (_first![key] as num),
        });

  void observe(Map<String, Object?> row, int receivedUs) {
    const keys = {'status', 'layerCount', ..._values};
    final observed = row['status'] == 'observed';
    final delay = row['totalFrameDelaySeconds'];
    if (row.length != keys.length ||
        !keys.every(row.containsKey) ||
        ![
          'observed',
          'noLayer',
          'noMetrics',
          'ambiguous',
          'unsupported',
          'unavailable',
        ].contains(row['status']) ||
        row['layerCount'] is! int ||
        (row['layerCount'] as int) < 0 ||
        (observed
            ? row['layerCount'] != 1 ||
                  _counters.any(
                    (k) =>
                        row[k] is! int ||
                        (row[k] as int) < 0 ||
                        (row[k] as int) > 9007199254740991,
                  ) ||
                  delay is! num ||
                  !delay.isFinite ||
                  delay < 0
            : _values.any((k) => row[k] != null))) {
      _valid = false;
      throw const FormatException('Invalid video performance snapshot');
    }
    if (!_valid ||
        receivedUs < 0 ||
        _rows.length >= 80 ||
        (_rows.isNotEmpty && receivedUs <= (_rows.last['receivedUs'] as int))) {
      _valid = false;
      throw StateError('Invalid video performance observation sequence');
    }
    final saved = Map<String, Object?>.unmodifiable({
      ...row,
      'receivedUs': receivedUs,
    });
    _rows.add(saved);
    if (['unsupported', 'unavailable', 'ambiguous'].contains(row['status']) ||
        (_last != null && row['status'] == 'noLayer') ||
        (observed &&
            _last != null &&
            _values.any((k) => (row[k] as num) < (_last![k] as num)))) {
      _valid = false;
      throw StateError('Video performance observation unavailable or reset');
    }
    if (observed) {
      _first ??= saved;
      _last = saved;
    }
  }
}
