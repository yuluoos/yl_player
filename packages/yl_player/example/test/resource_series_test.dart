import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/resource_series.dart';

Map<String, Object?> snapshot(int time) => {
  'monotonicUs': time,
  'cpuUs': time ~/ 2,
  'rssBytes': 100,
  'footprintBytes': 80,
  'thermal': 'nominal',
  'power': 'ac',
  'status': 'ok',
};
void main() {
  test(
    'opening sample failure still cancels the owned periodic sampler',
    () async {
      var reads = 0;
      final series = ResourceSeries(
        read: () {
          reads++;
          if (reads == 2) throw const FormatException('opening failed');
          return snapshot(reads);
        },
      )..enter('idle');
      final cleanup = <Future<void> Function()>[];
      startResourceSampling(
        series: series,
        cleanup: cleanup,
        onFailure: () {},
        interval: const Duration(milliseconds: 2),
      );
      expect(() => series.enter('opening'), throwsFormatException);
      for (final action in cleanup) {
        await action();
      }
      final stoppedAt = reads;
      await Future<void>.delayed(const Duration(milliseconds: 12));
      expect(reads, stoppedAt);
      series.close();
    },
  );

  test('creation deadline returns ownership before expiry', () async {
    var releases = 0;
    expect(
      await createResourceOwner(
        Future.value(7),
        timeout: const Duration(seconds: 1),
        release: (_) async {
          releases++;
        },
      ),
      7,
    );
    expect(releases, 0);
  });
  test(
    'hung creation times out while recorded samples remain available',
    () async {
      final series = ResourceSeries(read: () => snapshot(1))..enter('opening');
      await expectLater(
        createResourceOwner(
          Completer<int>().future,
          timeout: const Duration(milliseconds: 10),
          release: (_) async {},
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(series.close().single['phase'], 'opening');
    },
  );
  test(
    'late creation is released once and release error is consumed',
    () async {
      final creation = Completer<int>();
      final released = Completer<void>();
      var releases = 0;
      await expectLater(
        createResourceOwner(
          creation.future,
          timeout: const Duration(milliseconds: 10),
          release: (value) async {
            expect(value, 7);
            releases++;
            released.complete();
            throw StateError('release failure');
          },
        ),
        throwsA(isA<TimeoutException>()),
      );
      creation.complete(7);
      await released.future;
      await Future<void>.delayed(Duration.zero);
      expect(releases, 1);
    },
  );
  test('captures phases with native clock and freezes after close', () {
    var time = 1;
    final series = ResourceSeries(read: () => snapshot(time++));
    series.enter('idle');
    series.sample();
    series.enter('playing');
    final rows = series.close();
    expect(rows.map((e) => e['phase']), ['idle', 'idle', 'playing']);
    expect(rows.first['monotonicUs'], 1);
    expect(series.sample, throwsStateError);
    expect(() => rows.add(snapshot(10)), throwsUnsupportedError);
  });
  test('unavailable counters remain null', () {
    final series = ResourceSeries(
      read: () => {
        ...snapshot(1),
        'cpuUs': null,
        'rssBytes': null,
        'footprintBytes': null,
        'status': 'unavailable',
      },
    );
    series.enter('idle');
    expect(series.close().single['cpuUs'], isNull);
  });
  test('rejects arbitrary native fields without echoing values', () {
    final series = ResourceSeries(
      read: () => {...snapshot(1), 'private': 'secret'},
    );
    expect(() => series.enter('idle'), throwsA(isA<FormatException>()));
    expect(series.close(), isEmpty);
  });
  test('rejects backwards phase or native clock', () {
    final series = ResourceSeries(read: () => snapshot(1));
    series.enter('playing');
    expect(() => series.enter('idle'), throwsStateError);
    expect(series.sample, throwsA(isA<FormatException>()));
  });
  test('sample limit fails explicitly and preserves earlier rows', () {
    var time = 0;
    final series = ResourceSeries(read: () => snapshot(++time));
    series.enter('idle');
    for (var i = 1; i < 256; i++) {
      series.sample();
    }
    expect(series.sample, throwsStateError);
    expect(series.close(), hasLength(256));
  });
}
