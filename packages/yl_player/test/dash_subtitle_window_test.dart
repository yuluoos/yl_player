import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/dash_subtitles.dart';
import 'package:yl_player/src/subtitles/dash_subtitle_resource.dart';
import 'package:yl_player/src/subtitles/subtitle_resource.dart';
import 'support/fmp4_fixture.dart' as mp4;
import 'package:yl_player/src/subtitles/subtitle_document.dart';

class Reader implements DashSubtitleReader {
  Reader(this.resources, {this.offsets = const {}});
  final Map<String, int> offsets;
  final Map<String, List<int>> resources;
  final readPaths = <String>[];
  @override
  Future<DashSubtitleReply> root(SubtitleCancellation token) =>
      throw UnimplementedError();
  @override
  Future<DashSubtitleReply> read(
    DashSubtitleResource resource,
    SubtitleCancellation token,
    int maxBytes,
  ) async {
    token.check();
    final location = resource.locations.single;
    readPaths.add(location.uri.path);
    final bytes = resources[location.uri.path]!;
    expect(bytes.length, lessThanOrEqualTo(maxBytes));
    return DashSubtitleReply(
      bytes,
      location,
      sourceOffset: offsets[location.uri.path] ?? 0,
    );
  }
}

void main() {
  final origin = DashSubtitleLocation(Uri.parse('https://owned.test/root.mpd'));
  const xml =
      '''<MPD mediaPresentationDuration="PT6S"><Period duration="PT6S"><AdaptationSet id="1" mimeType="text/vtt"><Representation id="t"><SegmentTemplate timescale="1" presentationTimeOffset="10" media="s-\$Time\$.vtt"><SegmentTimeline><S t="10" d="2" r="2"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>''';
  test(
    'selected window loads only current and next, caches, maps PTO and clips cues',
    () async {
      final catalog = DashSubtitleCatalog.parse(utf8.encode(xml), origin);
      final reader = Reader({
        for (final t in [10, 12, 14])
          '/s-$t.vtt': utf8.encode(
            'WEBVTT\n\n00:00:$t.000 --> 00:00:${t + 3}.000\n<b>segment $t</b>\n',
          ),
      });
      final loader = DashSubtitleWindowLoader(catalog, reader);
      final token = SubtitleCancellation();
      final id = catalog.tracks.single.id;
      final first = await loader.load(id, Duration.zero, token);
      expect(reader.readPaths, ['/s-10.vtt', '/s-12.vtt']);
      expect(first.cues.map((c) => (c.start.inSeconds, c.end.inSeconds)), [
        (0, 2),
        (2, 4),
      ]);
      await loader.load(id, const Duration(milliseconds: 500), token);
      expect(reader.readPaths, hasLength(2));
      final later = await loader.load(id, const Duration(seconds: 3), token);
      expect(reader.readPaths, ['/s-10.vtt', '/s-12.vtt', '/s-14.vtt']);
      expect(later.cues.map((c) => (c.start.inSeconds, c.end.inSeconds)), [
        (2, 4),
        (4, 6),
      ]);
    },
  );
  test(
    'fractional period mapping retains style and half-open boundaries',
    () async {
      const mpd =
          '''<MPD mediaPresentationDuration="PT1S"><Period start="PT0.000001S" duration="PT0.999999S"><AdaptationSet mimeType="application/ttml+xml"><Representation id="t"><BaseURL>sub.ttml</BaseURL></Representation></AdaptationSet></Period></MPD>''';
      final catalog = DashSubtitleCatalog.parse(utf8.encode(mpd), origin);
      final reader = Reader({
        '/sub.ttml': utf8.encode(
          '<tt xmlns="http://www.w3.org/ns/ttml" xmlns:tts="http://www.w3.org/ns/ttml#styling"><body><div><p begin="0s" end="2s"><span tts:fontWeight="bold">owned</span></p></div></body></tt>',
        ),
      });
      final doc = await DashSubtitleWindowLoader(
        catalog,
        reader,
      ).load(catalog.tracks.single.id, Duration.zero, SubtitleCancellation());
      expect(doc.cues.single.start.inMicroseconds, 1);
      expect(doc.cues.single.end.inMicroseconds, 1000000);
      expect(doc.cues.single.textRuns!.single.bold, isTrue);
    },
  );
  for (final codec in ['wvtt', 'stpp']) {
    test(
      'fMP4 $codec reuses existing parser and maps absolute sample time',
      () async {
        final init = mp4.fragmented(
          tracks: [
            mp4.Mp4Track(
              entry: codec == 'wvtt' ? mp4.wvttEntry() : mp4.stppEntry(),
              samples: [],
              durations: [],
            ),
          ],
          fragments: [],
        );
        final media = mp4.Fragment(
          tracks: [
            mp4.FragmentTrack(
              time: 10000,
              samples: [
                codec == 'wvtt'
                    ? mp4.vttCue('owned')
                    : mp4.stppSample('<p begin="10s" end="11s">owned</p>'),
              ],
              durations: [1000],
            ),
          ],
        ).build(init.length);
        final manifest =
            '<MPD mediaPresentationDuration="PT1S"><Period duration="PT1S"><AdaptationSet mimeType="application/mp4" codecs="$codec"><Representation id="t"><SegmentTemplate duration="1" presentationTimeOffset="10" initialization="init.mp4" media="segment.m4s"/></Representation></AdaptationSet></Period></MPD>';
        final catalog = DashSubtitleCatalog.parse(
          utf8.encode(manifest),
          origin,
        );
        final reader = Reader({'/init.mp4': init, '/segment.m4s': media});
        final doc = await DashSubtitleWindowLoader(
          catalog,
          reader,
        ).load(catalog.tracks.single.id, Duration.zero, SubtitleCancellation());
        expect(doc.cues, hasLength(1));
        expect(doc.cues.single.start, Duration.zero);
        expect(doc.cues.single.end, const Duration(seconds: 1));
        expect(doc.cues.single.payload, 'owned');
      },
    );
  }

  test('combining windows retains simultaneous-cue limits', () {
    final doc = SubtitleDocument.parse(
      utf8.encode('WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nowned\n'),
      format: SubtitleFormat.webvtt,
    );
    expect(
      () => SubtitleDocument.combine(List.filled(65, doc)),
      throwsA(isA<SubtitleParseException>()),
    );
  });

  test(
    'range fragments retain 8 GiB absolute offsets without allocating holes',
    () async {
      const offset = 8 * 1024 * 1024 * 1024;
      final init = mp4.fragmented(fragments: []);
      final media = mp4.Fragment(
        tracks: [
          mp4.FragmentTrack(time: 10000, base: 'explicit', baseValue: offset),
        ],
      ).build(offset);
      final manifest =
          '<MPD mediaPresentationDuration="PT1S"><Period duration="PT1S"><AdaptationSet mimeType="application/mp4" codecs="wvtt"><Representation id="t"><SegmentList presentationTimeOffset="10"><SegmentTimeline><S t="10" d="1"/></SegmentTimeline><Initialization sourceURL="init.mp4"/><SegmentURL media="huge.mp4" mediaRange="$offset-${offset + media.length - 1}"/></SegmentList></Representation></AdaptationSet></Period></MPD>';
      final catalog = DashSubtitleCatalog.parse(utf8.encode(manifest), origin);
      final reader = Reader(
        {'/init.mp4': init, '/huge.mp4': media},
        offsets: {'/huge.mp4': offset},
      );
      final doc = await DashSubtitleWindowLoader(
        catalog,
        reader,
      ).load(catalog.tracks.single.id, Duration.zero, SubtitleCancellation());
      expect(doc.cues.single.payload, 'hello');
      expect(doc.cues.single.start, Duration.zero);
      expect(doc.inputBytes, lessThan(4096));
    },
  );
}
