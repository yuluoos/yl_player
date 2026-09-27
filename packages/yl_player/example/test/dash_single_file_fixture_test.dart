import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/dash_single_file_fixture.dart';

void main() {
  test('single-file fixture packs exact bytes and independent closed ranges', () {
    const manifest =
        '''<MPD><Period start="PT0S" duration="PT4S"><BaseURL>period0/</BaseURL><AdaptationSet><Representation id="p0-0"><SegmentList timescale="1" presentationTimeOffset="10"><SegmentTimeline><S t="10" d="2"/></SegmentTimeline><Initialization sourceURL="init-0.m4s"/><SegmentURL media="one.m4s"/><SegmentURL media="two.m4s"/></SegmentList></Representation></AdaptationSet></Period></MPD>''';
    final originals = {
      '/period0/init-0.m4s': Uint8List.fromList([1, 2]),
      '/period0/one.m4s': Uint8List.fromList([3, 4, 5]),
      '/period0/two.m4s': Uint8List.fromList([6]),
    };
    final (xml, files) = packDashSingleFile(manifest, originals);
    expect(files.keys, ['/period0/packed-p0-0.m4s']);
    expect(files.values.single, [1, 2, 3, 4, 5, 6]);
    expect(xml, contains('<BaseURL>packed-p0-0.m4s</BaseURL>'));
    expect(xml, contains('<Initialization range="0-1"/>'));
    expect(xml, contains('<SegmentURL mediaRange="2-4"/>'));
    expect(xml, contains('<SegmentURL mediaRange="5-5"/>'));
    expect(xml, contains('presentationTimeOffset="10"'));
    expect(xml, contains('<S t="10" d="2"/>'));
    files.values.single[0] = 9;
    expect(originals['/period0/init-0.m4s'], [1, 2]);
    expect(originals['/period0/one.m4s'], [3, 4, 5]);
  });
}
