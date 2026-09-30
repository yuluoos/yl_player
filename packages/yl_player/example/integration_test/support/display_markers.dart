const _colors = [
  [255, 0, 0],
  [0, 255, 0],
  [0, 0, 255],
  [255, 255, 255],
];

/// Paused display-layer readback, never a physical presentation timestamp.
final class DisplayMarkers {
  DisplayMarkers({required this.startedUs});
  final int startedUs;
  final _rows = <Map<String, Object?>>[];
  int _lastMarker = -1;
  int? firstReadbackUs;
  bool get complete => _lastMarker == 3;
  int? get firstReadbackDelayUs =>
      firstReadbackUs == null ? null : firstReadbackUs! - startedUs;
  int get markersSeen => _lastMarker + 1;
  List<Map<String, Object?>> get observations => List.unmodifiable(_rows);

  void observe(Map<String, Object?> row, int receivedUs) {
    const keys = {'status', 'layerCount', 'ready', 'width', 'height', 'pixels'};
    if (row.length != keys.length ||
        !keys.every(row.containsKey) ||
        row['layerCount'] is! int ||
        row['ready'] is! bool ||
        ![
          'observed',
          'noLayer',
          'noImage',
          'ambiguous',
          'unsupported',
        ].contains(row['status'])) {
      throw const FormatException('Invalid display observation');
    }
    final pixels = row['pixels'];
    final observed = row['status'] == 'observed';
    if (observed
        ? (row['layerCount'] != 1 ||
              row['ready'] != true ||
              row['width'] != 320 ||
              row['height'] != 180 ||
              pixels is! List ||
              pixels.length != 27 ||
              pixels.any((v) => v is! int || v < 0 || v > 255))
        : (pixels != null || row['width'] != null || row['height'] != null)) {
      throw const FormatException('Invalid display pixels');
    }
    if (receivedUs < startedUs ||
        (_rows.isNotEmpty && receivedUs <= (_rows.last['receivedUs'] as int)) ||
        _rows.length >= 160) {
      throw StateError('Invalid display observation clock or count');
    }
    int? marker;
    if (observed) {
      for (var c = 0; c < _colors.length; c++) {
        if (List.generate(27, (i) => i).every(
          (i) => (((pixels as List)[i] as int) - _colors[c][i % 3]).abs() <= 24,
        )) {
          marker = c;
          break;
        }
      }
    }
    _rows.add(
      Map.unmodifiable({
        ...row,
        'pixels': pixels is List ? List.unmodifiable(pixels) : null,
        'receivedUs': receivedUs,
        'marker': marker,
      }),
    );
    if (['ambiguous', 'unsupported'].contains(row['status'])) {
      throw StateError('Display probe unavailable');
    }
    if (marker != null) {
      if (marker < _lastMarker || marker > _lastMarker + 1) {
        throw StateError('Unexpected display marker order');
      }
      _lastMarker = marker;
      firstReadbackUs ??= receivedUs;
    }
  }
}
