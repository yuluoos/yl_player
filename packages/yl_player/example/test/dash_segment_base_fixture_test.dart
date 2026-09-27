import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/dash_segment_base_fixture.dart';

void main() {
  for (final version in [0, 1]) {
    test('owned SegmentBase v$version preserves fragments and exact clock', () {
      final inputs = <String, Uint8List>{};
      for (final file in Directory(
        'assets/test_media/dash/period0',
      ).listSync().whereType<File>()) {
        inputs['/period0/${file.uri.pathSegments.last}'] = file
            .readAsBytesSync();
      }
      final (xml, files) = packDashSegmentBase(inputs, version: version);
      expect(xml, contains('mediaPresentationDuration="PT4S"'));
      expect(xml, isNot(contains('SegmentTemplate')));
      for (final track in [0, 1]) {
        final data = files['/period0/indexed-$track.mp4']!;
        final init = inputs['/period0/init-$track.m4s']!;
        expect(data.sublist(0, init.length), init);
        final index = ByteData.sublistView(data, init.length);
        final count = track == 0 ? 4 : 5;
        final size = 32 + (version == 1 ? 8 : 0) + count * 12;
        expect(index.getUint32(0), size);
        expect(index.getUint8(8), version);
        expect(index.getUint32(16), track == 0 ? 12288 : 48000);
        expect(
          xml,
          contains('indexRange="${init.length}-${init.length + size - 1}"'),
        );
        var offset = init.length + size, ticks = 0;
        for (var n = 1; n <= count; n++) {
          final fragment =
              inputs['/period0/chunk-$track-${n.toString().padLeft(5, '0')}.m4s']!;
          final entry = 32 + (version == 1 ? 8 : 0) + (n - 1) * 12;
          expect(index.getUint32(entry), fragment.length);
          expect(index.getUint32(entry + 8), 0x90000000);
          ticks += index.getUint32(entry + 4);
          expect(data.sublist(offset, offset + fragment.length), fragment);
          offset += fragment.length;
        }
        expect(offset, data.length);
        expect(ticks, (track == 0 ? 12288 : 48000) * 4);
      }
    });
  }
}
