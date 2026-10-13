import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'package:yl_player/src/subtitles/mp4_subtitles.dart';
import 'package:yl_player/src/subtitles/subtitle_resource.dart';
import 'mp4_parser_test.dart' show parse, bad, field;
import 'support/fmp4_fixture.dart';

List<int> elng(String tag) => full('elng', [...utf8.encode(tag), 0]);
List<int> languageFile(
  List<int> extra, {
  String codec = 'tx3g',
  String layout = 'ordinary',
}) {
  final sample = switch (codec) {
    'wvtt' => vttCue('hello'),
    'stpp' => stppSample('<p begin="0s" end="1s">hello</p>'),
    _ => textSample('hello'),
  };
  final track = Mp4Track(
    language: 'zho',
    mediaExtra: extra,
    entry: switch (codec) {
      'wvtt' => wvttEntry(),
      'stpp' => stppEntry(),
      _ => description(),
    },
    samples: layout == 'fragmented' ? [] : [sample],
    durations: layout == 'fragmented' ? [] : [1000],
  );
  return layout == 'ordinary'
      ? mp4(tracks: [track])
      : fragmented(
          tracks: [track],
          fragments: [
            Fragment(
              tracks: [
                FragmentTrack(
                  time: layout == 'hybrid' ? 1000 : 0,
                  samples: [
                    codec == 'stpp' && layout == 'hybrid'
                        ? stppSample('<p begin="1s" end="2s">hello</p>')
                        : sample,
                  ],
                ),
              ],
            ),
          ],
        );
}

void main() {
  for (final codec in ['tx3g', 'wvtt', 'stpp']) {
    for (final layout in ['ordinary', 'fragmented', 'hybrid']) {
      test(
        '$codec $layout preserves extended script tag and cue identity',
        () async {
          final data = (await parse(
            languageFile(elng('zh-Hant-TW'), codec: codec, layout: layout),
          )).single;
          expect(data.track.language, 'zh-Hant-TW');
          expect(data.track.id, 'mp4:1');
          expect(data.packets, hasLength(layout == 'hybrid' ? 2 : 1));
        },
      );
    }
  }
  for (final tag in [
    'en',
    'en-US',
    'zh-Hans',
    'MN-cYRL-mn',
    'es-419',
    'zh-cmn-Hans-CN',
    'abcd',
    'abcdefgh',
    'sl-rozaj-biske-1994',
    'de-CH-1901',
    'en-a-abc-b-def-x-private',
    'en-0-ab',
    'x-local',
    'i-klingon',
    'sgn-BE-FR',
    'en-GB-oed',
    'zh-min-nan',
    'x-a-a',
  ]) {
    test('well formed $tag preserved verbatim', () async {
      expect((await parse(languageFile(elng(tag)))).single.track.language, tag);
    });
  }
  test('absent extended tag retains packed language', () async {
    expect((await parse(languageFile([]))).single.track.language, 'zho');
  });
  for (final tag in [
    '',
    'e',
    'en_',
    'en_US',
    'en--US',
    '-en',
    'en-',
    'en US',
    'en\n',
    '中文',
    'en-abcdefghi',
    'en-a',
    'en-x',
    'x',
    'en-12',
    '123',
    'en-Latn-Latn',
    'en-variant-VARIANT',
    'en-a-ab-A-cd',
    'en-x-ab-abcdefghi',
  ]) {
    test('malformed tag ${jsonEncode(tag)} rejected', () async {
      await expectLater(parse(languageFile(elng(tag))), bad());
    });
  }
  for (final bytes in [
    full('elng', ascii.encode('en')),
    full('elng', [...ascii.encode('en'), 0, 0]),
    full('elng', [0]),
    full('elng', []),
    box('elng', [0, 0, 0]),
    [...elng('en'), ...elng('fr')],
  ]) {
    test('malformed framing ${bytes.toString()} rejected', () async {
      await expectLater(parse(languageFile(bytes)), bad());
    });
  }
  for (final bytes in [
    full('elng', [101, 110, 0], version: 1),
    full('elng', [101, 110, 0], flags: 1),
  ]) {
    test('unsupported fullbox $bytes rejected', () async {
      await expectLater(
        parse(languageFile(bytes)),
        bad(SubtitleParseReason.unsupported),
      );
    });
  }
  final boundary = 'x-${List.filled(13, 'abcdefgh').join('-')}-abcdefg-a';
  test('128 ASCII characters accepted without truncation', () async {
    expect(boundary.length, 128);
    expect(
      (await parse(languageFile(elng(boundary)))).single.track.language,
      boundary,
    );
  });
  test('oversized elng rejected before body read', () async {
    final bytes = languageFile(elng('$boundary-a'));
    final marker = ascii.encode('elng');
    final at =
        [
          for (var i = 0; i < bytes.length - 4; i++)
            if (List.generate(
              4,
              (k) => bytes[i + k] == marker[k],
            ).every((v) => v))
              i,
        ].single +
        4;
    await expectLater(
      Mp4Subtitles(bytes.length, (p, n) async {
        expect(
          p == at && n > 8,
          false,
          reason: 'oversized body must not be fetched',
        );
        return bytes.sublist(p, p + n);
      }, SubtitleCancellation()).parse(),
      bad(SubtitleParseReason.limitExceeded),
    );
  });
  test('valid elng does not bypass invalid mdhd language', () async {
    await expectLater(
      parse(field(languageFile(elng('en')), 'mdhd', 20, num(0, 2))),
      bad(SubtitleParseReason.unsupported),
    );
  });
  test('non subtitle elng is not interpreted', () async {
    expect(
      await parse(
        mp4(
          tracks: [Mp4Track(handler: 'vide', mediaExtra: elng('invalid_'))],
        ),
      ),
      isEmpty,
    );
  });
}
