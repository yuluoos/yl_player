import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/dash_subtitles.dart';
import 'package:yl_player/src/subtitles/dash_subtitle_resource.dart';
import 'package:yl_player/yl_player.dart';

void main() {
  DashSubtitleCatalog parse(String xml) => DashSubtitleCatalog.parse(
    utf8.encode(xml),
    DashSubtitleLocation(Uri.parse('https://origin.test/root.mpd')),
  );
  String period({
    String start = '0',
    String duration = '2',
    String pto = '90000',
    String base = 'p/',
    String id = '7',
  }) =>
      '''
    <Period start="PT${start}S" duration="PT${duration}S"><BaseURL>$base</BaseURL>
    <AdaptationSet id="$id" contentType="text" mimeType="text/vtt" lang="en">
    <Role schemeIdUri="urn:mpeg:dash:role:2011" value="caption"/>
    <Representation id="text" bandwidth="100"><SegmentTemplate timescale="90000" presentationTimeOffset="$pto" initialization="init.vtt" media="s-\$Time\$.vtt"><SegmentTimeline><S t="$pto" d="90000" r="1"/></SegmentTimeline></SegmentTemplate></Representation>
    </AdaptationSet></Period>''';
  test(
    'same content survives Period changes while PTO and resources stay local',
    () {
      final doc = parse(
        '<MPD mediaPresentationDuration="PT5S">${period()}${period(start: '3', pto: '180000', base: 'q/')}</MPD>',
      );
      expect(doc.tracks, hasLength(1));
      expect(doc.tracks.single.format, YlSubtitleFormat.webvtt);
      expect(doc.periods, hasLength(2));
      final first = doc.periods[0].tracks.single;
      final second = doc.periods[1].tracks.single;
      expect(first.id, second.id);
      expect(first.offset, DashSubtitleTime.of(1));
      expect(second.offset, DashSubtitleTime.of(2));
      expect(
        second.segments.first.resource.locations.single.uri.toString(),
        'https://origin.test/q/s-180000.vtt',
      );
      expect(doc.periodAt(const Duration(milliseconds: 2500)), isNull);
      expect(doc.periodAt(const Duration(seconds: 3)), same(doc.periods[1]));
    },
  );
  test('overlap clips half-open first window without shifting second Period', () {
    final doc = parse(
      '<MPD mediaPresentationDuration="PT3S">${period()}${period(start: '1', base: 'q/')}</MPD>',
    );
    expect(doc.periods.first.end, DashSubtitleTime.of(1));
    expect(doc.periodAt(const Duration(seconds: 1)), same(doc.periods.last));
  });
  test('root BaseURL cross origin then return never restores credentials', () {
    final doc = parse(
      '<MPD mediaPresentationDuration="PT2S"><BaseURL>https://foreign.test/</BaseURL>${period(base: 'https://origin.test/returned/')}</MPD>',
    );
    final track = doc.periods.single.tracks.single;
    expect(
      track.segments.first.resource.locations.single.credentialsStripped,
      isTrue,
    );
    expect(track.initialization!.locations.single.credentialsStripped, isTrue);
  });
  test('finite AV timing infers fractional programme end, text does not', () {
    const text =
        '<AdaptationSet mimeType="text/vtt"><Representation id="t"><BaseURL>whole.vtt</BaseURL></Representation></AdaptationSet>';
    const video =
        '<AdaptationSet mimeType="video/mp4"><Representation id="v"><SegmentTemplate timescale="3" presentationTimeOffset="30" media="v-\$Time\$.m4s"><SegmentTimeline><S t="30" d="1"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet>';
    final doc = parse('<MPD><Period>$video$text</Period></MPD>');
    expect(doc.duration, DashSubtitleTime.of(1, 3));
    expect(doc.periods.single.end.microseconds(ceil: true), 333334);
    expect(
      () => parse('<MPD><Period>$text</Period></MPD>'),
      throwsA(isA<YlPlayerException>()),
    );
  });
  test(
    'range list preserves offsets and numeric template padding is bounded',
    () {
      final doc = parse(
        '''<MPD mediaPresentationDuration="PT2S"><Period><AdaptationSet mimeType="application/mp4" codecs="wvtt"><Representation id="s"><SegmentList duration="1"><Initialization sourceURL="sub.mp4" range="0-99"/><SegmentURL media="sub.mp4" mediaRange="100-199"/><SegmentURL media="sub.mp4" mediaRange="200-299"/></SegmentList></Representation></AdaptationSet></Period></MPD>''',
      );
      expect(
        doc.periods.single.tracks.single.segments[1].resource.range!.start,
        200,
      );
      expect(
        doc.periods.single.tracks.single.initialization!.range!.length,
        100,
      );
      expect(
        () => parse(
          '<MPD>${period().replaceAll(r'$Time$', r'$Time%09999d$')}</MPD>',
        ),
        throwsA(isA<YlPlayerException>()),
      );
    },
  );
  test('MPD rejects permissive XML lexical forms and illegal entities', () {
    for (final xml in [
      '<MPD mediaPresentationDuration=PT1S><Period duration="PT1S"/></MPD>',
      '<MPD mediaPresentationDuration="PT1S"><Period duration="PT1S"/><BaseURL>a&broken</BaseURL></MPD>',
      '<MPD mediaPresentationDuration="PT1S"><Period duration="PT1S"/><BaseURL>&#0;</BaseURL></MPD>',
      '<?xml version="1.0" encoding="latin1"?><MPD mediaPresentationDuration="PT1S"><Period duration="PT1S"/></MPD>',
    ]) {
      expect(() => parse(xml), throwsA(isA<YlPlayerException>()), reason: xml);
    }
  });
}
