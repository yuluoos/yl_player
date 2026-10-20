import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/drm/license_timing.dart';

void main() {
  test('receipt observes sealed pending state even when body throws', () async {
    final trace = LicenseTimingTrace();
    final gate = Completer<void>();
    late Future<void> pending;
    bool? recordedIncomplete;
    await expectLater(
      withLicenseTimingTrace(
        trace,
        () async {
          pending = timeLicenseTransport(() => gate.future);
          throw StateError('cancelled workload');
        },
        onClosed: (closed) {
          recordedIncomplete = closed.incomplete;
        },
      ),
      throwsStateError,
    );
    expect(recordedIncomplete, isTrue);
    gate.complete();
    await pending;
    expect(trace.rows, isEmpty);
  });

  for (final status in [200, 403]) {
    test(
      'real license transport $status emits safe bounded wall timing',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          await request.drain<void>();
          await Future<void>.delayed(const Duration(milliseconds: 25));
          request.response.statusCode = status;
          request.response.add([4, 5, 6]);
          await request.response.close();
        });
        final client = YlDrmLicenseClient();
        addTearDown(client.close);
        final trace = LicenseTimingTrace();
        Future<void> call() async {
          await client.send(
            YlDrmLicenseEndpoint(
              Uri.parse('http://127.0.0.1:${server.port}/SECRET'),
              allowInsecureLoopback: true,
            ),
            YlDrmBytes([1, 2, 3]),
          );
        }

        if (status == 200) {
          await withLicenseTimingTrace(trace, call);
        } else {
          await expectLater(
            withLicenseTimingTrace(trace, call),
            throwsA(isA<YlPlayerException>()),
          );
        }
        final transport = trace.rows
            .where((r) => r['phase'] == 'transport')
            .toList();
        expect(transport.length, 1);
        expect(trace.rows.any((r) => r['phase'] == 'connect'), isTrue);
        expect(trace.rows.any((r) => r['phase'] == 'responseHeaders'), isTrue);
        expect(
          (transport.single['endedUs'] as int) -
              (transport.single['startedUs'] as int),
          greaterThanOrEqualTo(25000),
        );
        expect(
          transport.single['outcome'],
          status == 200 ? 'returned' : 'failed',
        );
        expect(trace.rows.toString(), isNot(contains('SECRET')));
        expect(() => trace.rows.clear(), throwsUnsupportedError);
      },
    );
  }
  test(
    'closed trace reports pending work and cannot accept late samples',
    () async {
      final trace = LicenseTimingTrace();
      final finish = Completer<void>();
      late Future<void> task;
      await withLicenseTimingTrace(trace, () async {
        task = timeLicenseTransport(() => finish.future);
      });
      expect(trace.incomplete, isTrue);
      expect(trace.rows, isEmpty);
      finish.complete();
      await task;
      expect(trace.rows, isEmpty);
      await expectLater(
        withLicenseTimingTrace(trace, () async {}),
        throwsStateError,
      );
    },
  );
  test(
    'boundaries remain bounded without storing untrusted request data',
    () async {
      final trace = LicenseTimingTrace();
      await withLicenseTimingTrace(trace, () async {
        for (var i = 0; i < 140; i++) {
          await timeLicenseTransport(() async {});
        }
      });
      expect(trace.rows.length, 128);
      expect(trace.omitted, 12);
      expect(trace.incomplete, isFalse);
    },
  );
}
