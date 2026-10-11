import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';

const _srt =
    '1\n00:00:01,000 --> 00:00:02,000\none\n\n'
    '2\n00:00:01,500 --> 00:00:03,000\ntwo';

SubtitleDocument parse(
  String source, {
  SubtitleFormat format = SubtitleFormat.srt,
  SubtitleLimits limits = const SubtitleLimits(),
}) =>
    SubtitleDocument.parse(utf8.encode(source), format: format, limits: limits);

Matcher fails(SubtitleParseReason reason) => throwsA(
  isA<SubtitleParseException>().having((e) => e.reason, 'reason', reason),
);

void main() {
  for (final block in [
    'NOTE --> private',
    'NOTE comment\n00:01.000 --> 00:02.000\nhello',
    'NOTE\nprivate --> payload',
  ]) {
    test('malformed NOTE cannot swallow a cue: ${block.hashCode}', () {
      for (final prefix in [
        'WEBVTT\n\n',
        'WEBVTT\n\n00:00.000 --> 00:01.000\nvalid\n\n',
      ]) {
        expect(
          () => parse('$prefix$block', format: SubtitleFormat.webvtt),
          fails(SubtitleParseReason.malformed),
        );
      }
    });
  }

  test('interval index matches a reference scan across overlaps and seeks', () {
    String timestamp(int ms) =>
        '00:00:${(ms ~/ 1000).toString().padLeft(2, '0')},'
        '${(ms % 1000).toString().padLeft(3, '0')}';
    final intervals = List.generate(
      150,
      (i) => (i * 113, i * 113 + 200 + (i % 9) * 167),
    );
    final document = parse(
      [
        for (var i = intervals.length - 1; i >= 0; i--)
          '$i\n${timestamp(intervals[i].$1)} --> ${timestamp(intervals[i].$2)}\ncue-$i',
      ].join('\n\n'),
    );
    for (var ms = 19500; ms >= 0; ms -= 37) {
      for (final offset in [-517, 0, 839]) {
        final expected = document.cues
            .where(
              (c) =>
                  c.start.inMicroseconds <= (ms - offset) * 1000 &&
                  c.end.inMicroseconds > (ms - offset) * 1000,
            )
            .map((c) => c.ordinal);
        expect(
          document
              .cuesAt(
                Duration(milliseconds: ms),
                offset: Duration(milliseconds: offset),
              )
              .map((c) => c.ordinal),
          expected,
        );
      }
    }
  });

  test('microsecond boundaries and extreme query operands remain safe', () {
    final document = parse(_srt);
    expect(document.cuesAt(const Duration(microseconds: 999999)), isEmpty);
    expect(
      document.cuesAt(const Duration(microseconds: 1999999)),
      hasLength(2),
    );
    expect(document.cuesAt(const Duration(days: 100000)), isEmpty);
    expect(
      () => document.cuesAt(Duration.zero, offset: const Duration(days: 8)),
      throwsArgumentError,
    );
    expect(
      () => document.cuesAt(Duration.zero, offset: const Duration(days: -8)),
      throwsArgumentError,
    );
    expect(
      document.cuesAt(const Duration(days: 7), offset: const Duration(days: 7)),
      isEmpty,
    );
  });

  test('hard line and metadata budgets reject amplification', () {
    expect(
      () => parse(List.filled(50000, '\n').join()),
      fails(SubtitleParseReason.limitExceeded),
    );
    expect(
      () => parse(
        '${List.filled(1025, '1').join()}\n00:00:01,000 --> 00:00:02,000\na',
      ),
      fails(SubtitleParseReason.limitExceeded),
    );
    expect(
      () => parse(
        'WEBVTT\n\n00:01.000 --> 00:02.000 '
        '${List.filled(1025, 'x').join()}\na',
        format: SubtitleFormat.webvtt,
      ),
      fails(SubtitleParseReason.limitExceeded),
    );
  });

  test('byte lists cannot mask values outside the unsigned byte range', () {
    for (final bytes in [
      [-1],
      [256],
      [321, 322, 323],
    ]) {
      expect(
        () => SubtitleDocument.parse(bytes, format: SubtitleFormat.srt),
        fails(SubtitleParseReason.malformed),
      );
    }
  });

  test(
    'valid prefix followed by damaged cue never yields a partial document',
    () {
      expect(
        () => parse('$_srt\n\n3\ninvalid-time\nprivate payload'),
        fails(SubtitleParseReason.malformed),
      );
    },
  );

  test('overlap, exact half-open boundaries, seek and off are stateless', () {
    final document = parse(_srt);
    List<String> at(int ms, {int offset = 0, bool enabled = true}) => document
        .cuesAt(
          Duration(milliseconds: ms),
          offset: Duration(milliseconds: offset),
          enabled: enabled,
        )
        .map((cue) => cue.payload)
        .toList();
    expect(at(999), isEmpty);
    expect(at(1000), ['one']);
    expect(at(1600), ['one', 'two']);
    expect(at(2000), ['two']);
    expect(at(3000), isEmpty);
    expect(at(3100), isEmpty);
    expect(at(1200, offset: 500), isEmpty);
    expect(at(2100, offset: 500), ['one', 'two']);
    expect(at(1100, offset: -500), ['one', 'two']);
    expect(at(1600, enabled: false), isEmpty);
    expect(at(0), isEmpty);
    expect(at(-1), isEmpty);
    expect(at(1600), ['one', 'two']);
  });

  for (final newline in ['\n', '\r\n', '\r']) {
    test('BOM, Unicode and multiline payload with ${newline.codeUnits}', () {
      final source = '\uFEFF$_srt\n第二行 🎬\n';
      final document = parse(source.replaceAll('\n', newline));
      expect(document.cues.last.payload, 'two\n第二行 🎬');
      expect(
        document.inputBytes,
        utf8.encode(source.replaceAll('\n', newline)).length,
      );
    });
  }

  test('SRT identifiers are optional and not treated as globally unique', () {
    final document = parse(
      '00:00:01,000 --> 00:00:03,000\na\n\n'
      '7\n00:00:01,000 --> 00:00:02,000\nb\n\n'
      '7\n00:00:02,000 --> 00:00:03,000\nc',
    );
    expect(document.cues.map((c) => c.identifier), [null, '7', '7']);
    expect(document.cuesAt(const Duration(seconds: 1)).map((c) => c.payload), [
      'a',
      'b',
    ]);
  });

  test('SRT out-of-order cues retain file order on lookup', () {
    final document = parse(
      '2\n00:00:02,000 --> 00:00:04,000\nb\n\n'
      '1\n00:00:01,000 --> 00:00:04,000\na',
    );
    expect(document.cuesAt(const Duration(seconds: 3)).map((c) => c.payload), [
      'b',
      'a',
    ]);
  });

  test('document and query result cannot be mutated', () {
    final document = parse(_srt);
    expect(() => document.cues.clear(), throwsUnsupportedError);
    expect(
      () => document.cuesAt(const Duration(seconds: 1)).clear(),
      throwsUnsupportedError,
    );
  });

  test('WebVTT signature, identifiers, NOTE, short and hour timestamps', () {
    final document = parse(
      'WEBVTT example\n\nNOTE comment\nignored\n\n'
      'chapter-one\n00:01.000 --> 00:02.000\nhello\n\n'
      '00:00:02.000 --> 00:00:03.000\nworld',
      format: SubtitleFormat.webvtt,
    );
    expect(document.cues.map((c) => c.payload), ['hello', 'world']);
    expect(document.cues.first.identifier, 'chapter-one');
    expect(document.cues.last.start, const Duration(seconds: 2));
  });

  test('WebVTT position and alignment survive parsing', () {
    final cue = parse(
      'WEBVTT\n\n00:01.000 --> 00:02.000 '
      'position:25.5%,line-left align:start\nhello',
      format: SubtitleFormat.webvtt,
    ).cues.single;
    expect(cue.positionPercent, 25.5);
    expect(cue.positionAlignment, 'line-left');
    expect(cue.alignment, 'start');
    final defaults = parse(
      'WEBVTT\n\n00:01.000 --> 00:02.000\nhello',
      format: SubtitleFormat.webvtt,
    ).cues.single;
    expect(defaults.positionPercent, isNull);
    expect(defaults.positionAlignment, 'auto');
    expect(defaults.alignment, 'center');
  });

  test('raw markup is retained for a future renderer, never interpreted', () {
    final cue = parse(
      'WEBVTT\n\n00:01.000 --> 00:02.000\n'
      '<v speaker><b>hello</b> &amp; <00:01.500>world',
      format: SubtitleFormat.webvtt,
    ).cues.single;
    expect(cue.payload, '<v speaker><b>hello</b> &amp; <00:01.500>world');
  });

  for (final source in [
    '',
    '\n',
    'WEBVTT-bad\n\n',
    'WEBVTT --> secret\n\n',
    'WEBVTT\n00:01.000 --> 00:02.000\nhello',
    'WEBVTT\n\n00:02.000 --> 00:03.000\nb\n\n00:01.000 --> 00:02.000\na',
  ]) {
    test('reject malformed WebVTT ${source.hashCode}', () {
      expect(
        () => parse(source, format: SubtitleFormat.webvtt),
        fails(SubtitleParseReason.malformed),
      );
    });
  }

  test('empty valid documents are supported', () {
    expect(parse('').cues, isEmpty);
    expect(parse('WEBVTT\n', format: SubtitleFormat.webvtt).cues, isEmpty);
  });

  for (final timing in [
    '00:60:00,000 --> 00:61:00,000',
    '00:00:60,000 --> 00:01:02,000',
    '00:00:02,000 --> 00:00:01,000',
    '00:00:01,000 --> 00:00:01,000',
    '-1:00:01,000 --> 00:00:02,000',
    '00:00:01.000 --> 00:00:02.000',
    '00:00:01,00 --> 00:00:02,000',
    '00:00:01,000-->00:00:02,000',
    '00:00:01,000 --> 00:00:02,000 trailing',
  ]) {
    test('reject invalid SRT timing $timing', () {
      expect(
        () => parse('1\n$timing\nsecret'),
        fails(SubtitleParseReason.malformed),
      );
    });
  }

  for (final source in [
    '1\n00:00:01,000 --> 00:00:02,000',
    'arbitrary\n00:00:01,000 --> 00:00:02,000\nsecret',
    '1\n00:00:01,000 --> 00:00:02,000\na\n2\n00:00:02,000 --> 00:00:03,000\nb',
    '1\n00:00:01,000 --> 00:00:02,000\na\u0000b',
  ]) {
    test('reject malformed SRT block ${source.hashCode}', () {
      expect(() => parse(source), fails(SubtitleParseReason.malformed));
    });
  }

  for (final settings in [
    'position:101%',
    'position:-1%',
    'position:NaN%',
    'position:2%,unknown',
    'align:middle',
    'align:start align:end',
    'align:',
  ]) {
    test('reject malformed setting $settings', () {
      expect(
        () => parse(
          'WEBVTT\n\n00:01.000 --> 00:02.000 $settings\na',
          format: SubtitleFormat.webvtt,
        ),
        fails(SubtitleParseReason.malformed),
      );
    });
  }

  for (final source in [
    'WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00.000,MPEGTS:9000\n\n',
    'WEBVTT\n\nSTYLE\n::cue { color: red; }',
    'WEBVTT\n\nREGION\nid:one',
    'WEBVTT\n\n00:01.000 --> 00:02.000 region:one\na',
  ]) {
    test('unsupported semantics are explicit ${source.hashCode}', () {
      expect(
        () => parse(source, format: SubtitleFormat.webvtt),
        fails(SubtitleParseReason.unsupported),
      );
    });
  }

  test('invalid UTF-8 and errors do not disclose input', () {
    expect(
      () => SubtitleDocument.parse([0xff], format: SubtitleFormat.srt),
      fails(SubtitleParseReason.malformed),
    );
    try {
      parse('https://secret.invalid/?token=secret');
      fail('accepted malformed source');
    } on SubtitleParseException catch (error) {
      expect(error.toString(), isNot(contains('secret')));
    }
    expect(parse(_srt).toString(), isNot(contains('one')));
    expect(parse(_srt).cues.first.toString(), isNot(contains('one')));
  });

  test('byte limit is checked before UTF-8 decoding', () {
    expect(
      () => SubtitleDocument.parse(
        [0xff, 0xff],
        format: SubtitleFormat.srt,
        limits: const SubtitleLimits(maxInputBytes: 1),
      ),
      fails(SubtitleParseReason.limitExceeded),
    );
    final length = utf8.encode(_srt).length;
    expect(
      parse(_srt, limits: SubtitleLimits(maxInputBytes: length)).cues,
      hasLength(2),
    );
    expect(
      () => parse(_srt, limits: SubtitleLimits(maxInputBytes: length - 1)),
      fails(SubtitleParseReason.limitExceeded),
    );
  });

  test('cue count and per-cue UTF-16 limits are exact', () {
    expect(
      () => parse(_srt, limits: const SubtitleLimits(maxCues: 1)),
      fails(SubtitleParseReason.limitExceeded),
    );
    expect(
      parse(
        _srt,
        limits: const SubtitleLimits(maxCues: 2, maxCueCodeUnits: 3),
      ).cues,
      hasLength(2),
    );
    expect(
      () => parse(_srt, limits: const SubtitleLimits(maxCueCodeUnits: 2)),
      fails(SubtitleParseReason.limitExceeded),
    );
  });

  test('overlap budget counts end before start at equal timestamps', () {
    expect(
      () => parse(_srt, limits: const SubtitleLimits(maxActiveCues: 1)),
      fails(SubtitleParseReason.limitExceeded),
    );
    expect(
      parse(
        _srt.replaceFirst('00:00:01,500', '00:00:02,000'),
        limits: const SubtitleLimits(maxActiveCues: 1),
      ).cues,
      hasLength(2),
    );
  });

  test('timestamps beyond seven days fail without integer overflow', () {
    expect(
      () => parse(
        '1\n999999999999999999999:00:00,000 --> '
        '999999999999999999999:00:01,000\na',
      ),
      fails(SubtitleParseReason.limitExceeded),
    );
  });

  test('invalid limits fail in release mode too', () {
    for (final limits in [
      const SubtitleLimits(maxInputBytes: 0),
      const SubtitleLimits(maxCues: -1),
      const SubtitleLimits(maxCueCodeUnits: 0),
      const SubtitleLimits(maxActiveCues: 0),
      const SubtitleLimits(maxInputBytes: 4194305),
    ]) {
      expect(() => parse(_srt, limits: limits), throwsArgumentError);
    }
  });
}
