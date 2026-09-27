import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/dash_offset_fixture.dart';

Uint8List box(String type, List<int> payload) {
  final b = Uint8List(8 + payload.length);
  ByteData.sublistView(b).setUint32(0, b.length);
  b.setRange(4, 8, type.codeUnits);
  b.setRange(8, b.length, payload);
  return b;
}

Uint8List fragment({int version = 1, int timestamp = 100, int timescale = 10}) {
  final tfdt = Uint8List(version == 0 ? 8 : 12)..[0] = version;
  final index = Uint8List(version == 0 ? 24 : 32)..[0] = version;
  final t = ByteData.sublistView(tfdt), s = ByteData.sublistView(index);
  s.setUint32(4, 1);
  s.setUint32(8, timescale);
  if (version == 0) {
    t.setUint32(4, timestamp);
    s.setUint32(12, timestamp);
  } else {
    t.setUint64(4, timestamp);
    s.setUint64(12, timestamp);
  }
  return Uint8List.fromList([
    ...box('sidx', index),
    ...box('moof', box('traf', box('tfdt', tfdt))),
    ...box('mdat', [11, 22, 33, 44]),
  ]);
}

void main() {
  for (final version in [0, 1]) {
    test('shifts tfdt and sidx v$version without altering source or media', () {
      final input = fragment(version: version);
      final snapshot = Uint8List.fromList(input);
      final shifted = shiftDashFragment(input, 200, timescale: 10);
      expect(shifted, fragment(version: version, timestamp: 300));
      expect(input, snapshot);
      expect(shifted.sublist(shifted.length - 4), [11, 22, 33, 44]);
    });
  }
  test(
    'fixture builder shifts actual video and audio bytes with Time/List MPDs',
    () {
      final originals = <String, Uint8List>{};
      for (final period in [0, 1]) {
        for (final track in [0, 1, 2]) {
          originals['/period$period/init-$track.m4s'] = Uint8List.fromList([
            1,
            2,
            3,
          ]);
          for (var i = 1; i <= (track == 2 ? 5 : 4); i++) {
            originals['/period$period/chunk-$track-${i.toString().padLeft(5, '0')}.m4s'] =
                fragment(timestamp: 0, timescale: track == 2 ? 48000 : 12288);
          }
        }
      }
      for (final list in [false, true]) {
        final fixture = DashOffsetFixture.fromVariants(
          originals,
          segmentList: list,
        );
        expect(
          fixture.files['/period0/chunk-0-122880.m4s'],
          fragment(timestamp: 122880, timescale: 12288),
        );
        expect(
          fixture.files['/period0/chunk-2-480000.m4s'],
          fragment(timestamp: 480000, timescale: 48000),
        );
        expect(
          fixture.files['/period1/chunk-1-368640.m4s'],
          fragment(timestamp: 368640, timescale: 12288),
        );
        expect(
          fixture.files['/period1/chunk-2-1440000.m4s'],
          fragment(timestamp: 1440000, timescale: 48000),
        );
        expect(fixture.files['/period0/init-0.m4s'], [1, 2, 3]);
        expect(
          originals['/period0/chunk-0-00001.m4s'],
          fragment(timestamp: 0, timescale: 12288),
        );
        expect(fixture.manifest, contains('presentationTimeOffset="122880"'));
        expect(fixture.manifest, contains('presentationTimeOffset="1440000"'));
        expect(
          fixture.manifest,
          contains(
            list
                ? '<SegmentURL media="chunk-0-122880.m4s"'
                : r'media="chunk-0-$Time$.m4s"',
          ),
        );
        expect(fixture.files, hasLength(32));
      }
    },
  );
  test('rejects malformed fragments, unsupported versions and overflow', () {
    final badVersion = fragment()..[8] = 2;
    final badSize = fragment();
    ByteData.sublistView(badSize).setUint32(0, 0xffffffff);
    for (final input in [
      Uint8List(0),
      fragment().sublist(0, 9),
      badVersion,
      badSize,
      fragment(version: 0, timestamp: 0xfffffff0),
      fragment(timestamp: 0x7ffffffffffffff0),
    ]) {
      expect(
        () => shiftDashFragment(input, 200, timescale: 10),
        throwsFormatException,
      );
    }
    expect(
      () => shiftDashFragment(fragment(), -1, timescale: 10),
      throwsFormatException,
    );
    expect(
      () => shiftDashFragment(fragment(), 200, timescale: 11),
      throwsFormatException,
    );
  });
}
