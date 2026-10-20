import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/seek_progress_window.dart';

void main() {
  SeekProgressWindow probe() =>
      SeekProgressWindow(session: 's', startedUs: 100, targetUs: 5000000);
  void add(
    SeekProgressWindow p,
    int t,
    int pos, {
    bool buffer = false,
    String id = 's',
  }) => p.observe(
    sessionId: id,
    nowUs: t,
    positionUs: pos,
    playing: true,
    buffering: buffer,
  );
  test('start precedes seek; target and full continuous progress required', () {
    final p = probe();
    add(p, 1000, 0);
    expect(p.firstNearUs, isNull);
    add(p, 200000, 5000000);
    expect(p.firstNearUs, 200000);
    for (var i = 1; i <= 4; i++) {
      add(p, 200000 + i * 250000, 5000000 + i * 250000);
    }
    expect(p.stableUs, 1200000);
  });
  test('buffering resets window while preserving first target observation', () {
    final p = probe();
    add(p, 1000, 5000000);
    add(p, 251000, 5250000, buffer: true);
    add(p, 501000, 5500000);
    add(p, 751000, 5750000);
    add(p, 1001000, 6000000);
    expect(p.stableUs, isNull);
    expect(p.firstNearUs, 1000);
    add(p, 1251000, 6250000);
    add(p, 1501000, 6500000);
    expect(p.stableUs, 1501000);
  });
  test(
    'replacement permanently cancels and stale observations cannot pass',
    () {
      final p = probe();
      add(p, 1000, 5000000, id: 'other');
      for (var i = 0; i <= 5; i++) {
        add(p, 2000 + i * 250000, 5000000 + i * 250000);
      }
      expect(p.cancelled, isTrue);
      expect(p.stableUs, isNull);
    },
  );
  test('stalls and long sampling gaps cannot manufacture stability', () {
    final p = probe();
    add(p, 1000, 5000000);
    add(p, 251000, 5000000);
    add(p, 1001000, 6000000);
    expect(p.stableUs, isNull);
    add(p, 1251000, 6000000);
    add(p, 1501000, 6000000);
    add(p, 1751000, 6000000);
    add(p, 2001000, 6000000);
    expect(p.stableUs, isNull);
  });
  test('intermediate backward progress resets the full window', () {
    final p = probe();
    add(p, 1000, 5000000);
    add(p, 251000, 5500000);
    add(p, 501000, 5400000);
    add(p, 751000, 5750000);
    add(p, 1001000, 6000000);
    expect(p.stableUs, isNull);
  });
  test('backward clock is rejected', () {
    final p = probe();
    expect(() => add(p, 99, 5000000), throwsFormatException);
    add(p, 200, 5000000);
    expect(() => add(p, 199, 5000000), throwsFormatException);
  });
  test(
    'paused target is a state observation but never a stable playback window',
    () {
      final p = probe();
      p.observe(
        sessionId: 's',
        nowUs: 1000,
        positionUs: 5000000,
        playing: false,
        buffering: false,
      );
      expect(p.firstNearUs, 1000);
      expect(p.stableUs, isNull);
      for (var i = 0; i <= 4; i++) {
        add(p, 2000 + i * 250000, 5000000 + i * 250000);
      }
      expect(p.stableUs, 1002000);
    },
  );
}
