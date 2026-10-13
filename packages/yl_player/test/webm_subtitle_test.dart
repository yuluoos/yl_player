import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player/src/subtitles/matroska_subtitles.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'package:yl_player/src/subtitles/subtitle_resource.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'support/matroska_fixture.dart';

Future<List<EmbeddedSubtitleData>> parse(List<int> b) => MatroskaSubtitles(
  b.length,
  (p, n) async => b.sublist(p, p + n),
  SubtitleCancellation(),
).parse();
List<int> webm({
  String codec = 'D_WEBVTT/SUBTITLES',
  List<int> trackExtra = const [],
  List<int>? blocks,
}) => mkv(
  docType: 'webm',
  tracks: track(codec: codec, extra: trackExtra),
  clusters: cluster(
    blocks ?? block(text: 'id\nposition:25%,center align:start\n<b>hello</b>'),
  ),
);
Matcher unsupported() => throwsA(
  isA<SubtitleParseException>().having(
    (e) => e.reason,
    'reason',
    SubtitleParseReason.unsupported,
  ),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final codec in ['D_WEBVTT/SUBTITLES', 'D_WEBVTT/CAPTIONS']) {
    test('$codec WebM uses UID, settings and container times', () async {
      final d = (await parse(webm(codec: codec))).single;
      expect(d.track.id, 'mkv:101');
      expect(d.track.format, YlSubtitleFormat.webvtt);
      final c = SubtitleDocument.fromEmbeddedPackets(
        d.packets,
        format: SubtitleFormat.webvtt,
        sourceBytes: d.sourceBytes,
      ).cues.single;
      expect(c.identifier, 'id');
      expect(c.positionPercent, 25);
      expect(c.alignment, 'start');
      expect(c.payload, '<b>hello</b>');
      expect(c.start, const Duration(seconds: 1));
      expect(c.end, const Duration(seconds: 2));
    });
  }
  for (final codec in [
    'S_TEXT/UTF8',
    'S_TEXT/ASS',
    'S_TEXT/SSA',
    'S_TEXT/WEBVTT',
    'D_WEBVTT/DESCRIPTIONS',
    'D_WEBVTT/METADATA',
  ]) {
    test(
      'WebM subtitle type rejects $codec',
      () async => expectLater(parse(webm(codec: codec)), unsupported()),
    );
  }
  test(
    'metadata track is skipped without parsing its arbitrary payload',
    () async {
      final metadata = element(0xae, [
        ...uint(0xd7, 2),
        ...uint(0x73c5, 202),
        ...uint(0x83, 0x21),
        ...str(0x86, 'D_WEBVTT/METADATA'),
      ]);
      final d = await parse(
        mkv(
          docType: 'webm',
          tracks: [
            ...track(codec: 'D_WEBVTT/CAPTIONS'),
            ...metadata,
          ],
          clusters: cluster([
            ...block(text: '\n\ncaption'),
            ...block(number: 2, text: 'not subtitle syntax', duration: null),
          ]),
        ),
      );
      expect(d.single.packets.single.text, 'caption');
    },
  );
  test(
    'same language main and forced selection identities survive reorder',
    () async {
      Future<List<EmbeddedSubtitleData>> scan(bool reverse) => parse(
        mkv(
          docType: 'webm',
          tracks: reverse
              ? [
                  ...track(
                    number: 7,
                    uid: 700,
                    codec: 'D_WEBVTT/CAPTIONS',
                    forced: true,
                  ),
                  ...track(number: 3, uid: 300, codec: 'D_WEBVTT/SUBTITLES'),
                ]
              : [
                  ...track(number: 3, uid: 300, codec: 'D_WEBVTT/SUBTITLES'),
                  ...track(
                    number: 7,
                    uid: 700,
                    codec: 'D_WEBVTT/CAPTIONS',
                    forced: true,
                  ),
                ],
          clusters: cluster([
            ...block(number: 3, text: '\n\nnormal'),
            ...block(number: 7, text: '\n\nforced'),
          ]),
        ),
      );
      final a = await scan(false), b = await scan(true);
      expect(a.first.track.id, b.last.track.id);
      expect(a.last.track.id, b.first.track.id);
      expect(b.first.track.role, 'forced');
    },
  );
  test(
    'unknown DocType remains unsupported',
    () async => expectLater(parse(mkv(docType: 'unknown')), unsupported()),
  );
  test(
    'WebM malformed prefix is reported after container admission',
    () async => expectLater(
      parse(webm(blocks: block(text: 'missing prefix'))),
      throwsA(
        isA<SubtitleParseException>().having(
          (e) => e.reason,
          'reason',
          SubtitleParseReason.malformed,
        ),
      ),
    ),
  );
  test(
    'WebM explicit duration still required',
    () async => expectLater(
      parse(
        webm(
          trackExtra: uint(0x23e383, 1000000000),
          blocks: block(text: '\n\nhello', duration: null),
        ),
      ),
      unsupported(),
    ),
  );
  group('real file discovery', () {
    late Directory dir;
    late File file;
    late TextSubtitleRuntime r;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('yl-webm-');
      file = await File('${dir.path}/misleading.mp4').writeAsBytes(webm());
      r = TextSubtitleRuntime();
    });
    tearDown(() async {
      r.reset();
      await dir.delete(recursive: true);
    });
    for (final format in [YlMediaFormat.automatic, YlMediaFormat.webm]) {
      test(
        '$format detects contents independent of suffix and renders',
        () async {
          await r.discover(YlFileSource(file.path, format: format));
          r.select('mkv:101');
          expect(
            r
                .cuesAt(const Duration(milliseconds: 1500))
                .single
                .text
                .toPlainText(),
            'hello',
          );
        },
      );
      test('$format discovers independently muxed VP9/WebVTT WebM', () async {
        await r.discover(
          YlFileSource(
            File(
              'packages/yl_player/test/fixtures/webm-subtitle-owned.webm',
            ).absolute.path,
            format: format,
          ),
        );
        r.select(r.state.tracks.single.id);
        expect(r.cuesAt(const Duration(milliseconds: 502)), isEmpty);
        expect(
          r.cuesAt(const Duration(milliseconds: 503)).single.text.toPlainText(),
          'Owned WebM subtitle',
        );
        expect(r.cuesAt(const Duration(milliseconds: 1707)), isEmpty);
      });
    }
    for (final format in [YlMediaFormat.matroska, YlMediaFormat.mp4]) {
      test('WebM cannot masquerade as explicit $format', () async {
        await expectLater(
          r.discover(YlFileSource(file.path, format: format)),
          throwsA(isA<YlPlayerException>()),
        );
        expect(r.state.tracks, isEmpty);
      });
    }
    test('explicit WebM rejects Matroska and keeps old selection', () async {
      await r.discover(YlFileSource(file.path));
      r.select('mkv:101');
      final old = r.state;
      await file.writeAsBytes(mkv());
      await expectLater(
        r.discover(YlFileSource(file.path, format: YlMediaFormat.webm)),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.subtitleUnsupported,
          ),
        ),
      );
      expect(r.state, old);
      expect(
        r.cuesAt(const Duration(seconds: 1)).single.text.toPlainText(),
        'hello',
      );
    });
  });
}
