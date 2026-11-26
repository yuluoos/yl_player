import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/iso/iso_image.dart';
import 'package:yl_player/src/iso/iso_segment.dart';

final class _Segment implements IsoSegment, IsoPayload {
  _Segment(this.length);
  @override
  final int length;
  var loads = 0;
  Completer<void>? pending;
  @override
  bool get discontinuity => false;
  @override
  int get ticks => 45000;
  @override
  Future<IsoPayload> openPayload() async {
    loads++;
    await pending?.future;
    return this;
  }

  @override
  Stream<Uint8List> read(int start, int stop) =>
      Stream.value(Uint8List(stop - start));
}

void main() {
  test(
    'DVD byte budget evicts the least recently used completed segment',
    () async {
      final cache = DvdSegmentCache(capacityBytes: 10);
      addTearDown(cache.close);
      final a = _Segment(5),
          b = _Segment(5),
          c = _Segment(4),
          large = _Segment(11);
      await cache.get(0, a);
      await cache.get(1, b);
      await cache.get(0, a);
      await cache.get(2, c);
      await cache.get(3, large);
      await cache.get(3, large);
      await cache.get(0, a);
      await cache.get(1, b);
      expect([a.loads, b.loads, c.loads, large.loads], [1, 2, 1, 2]);
    },
  );

  test(
    'interleaved DVD requests share in-flight work, retry failures and close',
    () async {
      final cache = DvdSegmentCache();
      final a = _Segment(1)..pending = Completer<void>();
      final first = cache.get(0, a);
      await cache.get(1, _Segment(2));
      expect(identical(first, cache.get(0, a)), isTrue);
      final failed = expectLater(first, throwsFormatException);
      a.pending!.completeError(const FormatException());
      await failed;
      a.pending = Completer<void>();
      final retry = cache.get(0, a);
      cache.close();
      a.pending!.complete();
      await retry;
      await expectLater(cache.get(0, a), throwsStateError);
      expect(a.loads, 2);
    },
  );

  test(
    'overlapping metadata reads share a Range and release it after failure',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      final ranges = <String>[];
      final data = Uint8List.fromList(List.generate(150000, (i) => i % 251));
      origin.listen((r) async {
        final range = r.headers.value('range')!;
        ranges.add(range);
        final span = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
        final a = int.parse(span[1]!), b = int.parse(span[2]!);
        if (ranges.length == 2) {
          r.response.statusCode = 503;
        } else {
          r.response
            ..statusCode = 206
            ..headers.set('content-range', 'bytes $a-$b/${data.length}')
            ..contentLength = b - a + 1
            ..add(Uint8List.sublistView(data, a, b + 1));
        }
        await r.response.close();
      });
      final image = IsoImage.network(
        Uri.parse('http://127.0.0.1:${origin.port}/disc.iso'),
        {},
        {},
      );
      addTearDown(image.close);
      await image.open();
      await expectLater(
        Future.wait([image.read(4096, 128), image.read(8192, 4096)]),
        throwsA(isA<HttpException>()),
      );
      expect(ranges.length, 2);
      final result = await Future.wait([
        image.read(4096, 128),
        image.read(8192, 4096),
      ]);
      expect(result[0], data.sublist(4096, 4224));
      expect(result[1], data.sublist(8192, 12288));
      expect(ranges.length, 3);
      // A distant NAV clock needs only its prefix, including a read at EOF.
      expect(
        await image.read(data.length - 65, 65, readAhead: false),
        data.sublist(data.length - 65),
      );
      expect(ranges.last, 'bytes=149935-149999');
    },
  );
}
