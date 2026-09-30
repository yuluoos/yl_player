import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/video_performance_series.dart';

Map<String, Object?> point(int? total, {int dropped = 0, double delay = 0}) => {
  'status': total == null ? 'noMetrics' : 'observed',
  'layerCount': 1,
  'totalFrames': total,
  'droppedFrames': total == null ? null : dropped,
  'corruptedFrames': total == null ? null : 0,
  'totalFrameDelaySeconds': total == null ? null : delay,
};

void main() {
  test('requires increasing counters and preserves missing samples', () {
    final series = VideoPerformanceSeries();
    series.observe(point(null), 10);
    series.observe(point(10, dropped: 1, delay: 2), 20);
    expect(series.complete, isFalse);
    series.observe(point(34, dropped: 3, delay: 3), 1020);
    expect(series.complete, isTrue);
    expect(series.delta, {
      'observationWindowUs': 1000,
      'totalFrames': 24,
      'droppedFrames': 2,
      'corruptedFrames': 0,
      'totalFrameDelaySeconds': 1.0,
    });
    expect(series.observations, hasLength(3));
  });
  test('zero or unchanged counters cannot claim an advancing window', () {
    final series = VideoPerformanceSeries();
    series.observe(point(0), 1);
    series.observe(point(0), 2);
    expect(series.complete, isFalse);
    expect(series.delta, isNull);
  });
  test('counter resets and reversed clocks fail without erasing evidence', () {
    for (final second in [
      point(8),
      point(12, dropped: 0, delay: 4),
      point(12, dropped: 2, delay: 1),
    ]) {
      final series = VideoPerformanceSeries()
        ..observe(point(10, dropped: 1, delay: 2), 1);
      expect(() => series.observe(second, 2), throwsStateError);
      expect(series.observations, hasLength(2));
      expect(series.complete, isFalse);
      expect(series.delta, isNull);
    }
    final series = VideoPerformanceSeries()..observe(point(10), 2);
    expect(() => series.observe(point(11), 2), throwsStateError);
  });
  test('strict schema rejects invalid counters and nonfinite delay', () {
    for (final changes in [
      {'totalFrames': -1},
      {'droppedFrames': 1.5},
      {'totalFrameDelaySeconds': double.nan},
      {'totalFrameDelaySeconds': double.infinity},
      {'totalFrameDelaySeconds': -1},
      {'private': 'secret'},
      {'layerCount': 2},
      {'status': 'noMetrics'},
    ]) {
      expect(
        () => VideoPerformanceSeries().observe({...point(1), ...changes}, 1),
        throwsFormatException,
      );
    }
  });
  test('unavailable snapshots are retained but never qualify', () {
    for (final status in ['unsupported', 'unavailable', 'ambiguous']) {
      final series = VideoPerformanceSeries();
      expect(
        () => series.observe({...point(null), 'status': status}, 1),
        throwsStateError,
      );
      expect(series.observations.single['status'], status);
      expect(series.complete, isFalse);
    }
  });
  test('copies native samples immutably and bounds collection', () {
    final row = point(1);
    final series = VideoPerformanceSeries()..observe(row, 1);
    row['totalFrames'] = 99;
    expect(series.observations.single['totalFrames'], 1);
    expect(
      () => series.observations.single['totalFrames'] = 2,
      throwsUnsupportedError,
    );
    for (var t = 2; t <= 80; t++) {
      series.observe(point(null), t);
    }
    expect(() => series.observe(point(2), 81), throwsStateError);
  });
}
