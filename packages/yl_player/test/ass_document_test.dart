import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';
import 'support/ass_fixture.dart';

SubtitleDocument parse(
  String text, {
  bool ssa = false,
  SubtitleLimits limits = const SubtitleLimits(),
}) => SubtitleDocument.parse(
  utf8.encode(text),
  format: ssa ? SubtitleFormat.ssa : SubtitleFormat.ass,
  limits: limits,
);
Matcher reason(SubtitleParseReason r) =>
    throwsA(isA<SubtitleParseException>().having((e) => e.reason, 'reason', r));
void main() {
  test('document run ceiling rejects before runtime span construction', () {
    final line =
        'Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,${List.filled(512, r'{\b1}a').join()}';
    expect(
      () =>
          parse(assFixture(text: 'a', extra: List.filled(40, line).join('\n'))),
      reason(SubtitleParseReason.limitExceeded),
    );
  });
  test('explicit zero movement times mean full cue duration', () {
    final a = parse(
      assFixture(text: r'{\move(10,20,110,120,0,0)}A'),
    ).cues.single.ass!;
    expect(a.motion!.at(0), (10, 20));
    expect(a.motion!.at(1000), (60, 70));
    expect(a.motion!.at(2000), (110, 120));
  });
  test(
    'named reset supplies defaults for argumentless tags; bare reset restores original',
    () {
      final alternate =
          'Style: Alternate,Missing,30,&H8000FF00,&H000000FF,&H400000FF,&H20FF0000,-1,-1,-1,-1,100,100,0,0,1,4,0,2,10,10,10,1';
      final doc = assFixture(
        text:
            r'{\rAlternate}A{\fs10\fs\fnAhem\fn\b0\b\i0\i\u0\u\s0\s\bord0\bord\shad0\shad\c&HFFFFFF&\c\3c&HFFFFFF&\3c\4c&HFFFFFF&\4c\alpha&H00&\alpha}B{\r}C',
      ).replaceFirst('[Events]', '$alternate\n[Events]');
      final a = parse(doc).cues.single.ass!;
      final s = a.runs[1].style, alt = a.runs[0].style;
      expect(
        [
          s.size,
          s.font,
          s.bold,
          s.italic,
          s.underline,
          s.strikeout,
          s.outline,
          s.shadow,
          s.color,
          s.outlineColor,
          s.shadowColor,
        ],
        [
          alt.size,
          alt.font,
          alt.bold,
          alt.italic,
          alt.underline,
          alt.strikeout,
          alt.outline,
          alt.shadow,
          alt.color,
          alt.outlineColor,
          alt.shadowColor,
        ],
      );
      expect(a.runs.last.style.size, 20);
    },
  );
  test('CRLF and LF share the same 50000-line budget', () {
    final doc = assFixture().replaceFirst(
      '[Events]',
      '${List.filled(26000, '; owned comment').join('\n')}\n[Events]',
    );
    expect(parse(doc).cues, hasLength(1));
    expect(parse(doc.replaceAll('\n', '\r\n')).cues, hasLength(1));
  });
  test(
    'mixed per-run shadow offsets reject instead of painting wrong outline shadow',
    () {
      expect(
        () => parse(assFixture(text: r'{\shad1}A{\shad2}B')),
        reason(SubtitleParseReason.unsupported),
      );
    },
  );

  for (final ssa in [false, true]) {
    test('${ssa ? 'SSA' : 'ASS'} time, colors, text and nine anchors', () {
      final doc = parse(
        assFixture(ssa: ssa, text: r'{\an8\pos(150,20)}Hello, <b>&\Nworld\h!'),
        ssa: ssa,
      );
      expect(doc.cuesAt(const Duration(milliseconds: 999)), isEmpty);
      expect(doc.cuesAt(const Duration(seconds: 1)), hasLength(1));
      expect(doc.cuesAt(const Duration(seconds: 3)), isEmpty);
      expect(
        doc.cuesAt(
          const Duration(seconds: 1),
          offset: const Duration(milliseconds: 500),
        ),
        isEmpty,
      );
      final a = doc.cues.single.ass!;
      expect(a.alignment, 8);
      expect(a.motion!.at(1000), (150, 20));
      expect(a.runs.single.style.color, 0xffff0000);
      expect(a.runs.single.text, 'Hello, <b>&\nworld\u00a0!');
    });
  }
  test('runs preserve style, BGR/alpha and reset without reparsing text', () {
    final a = parse(
      assFixture(
        text: r'{\b1\i1\u1\s1\fs30\fnMissingFont\c&H00FF00&\1a&H80&}A{\r}B',
      ),
    ).cues.single.ass!;
    final s = a.runs.first.style;
    expect(
      [s.bold, s.italic, s.underline, s.strikeout],
      [true, true, true, true],
    );
    expect(s.size, 30);
    expect(s.font, 'MissingFont');
    expect(s.color, 0x7f00ff00);
    expect(a.runs.last.style.color, 0xffff0000);
    expect(a.runs.last.style.bold, false);
  });
  test('line-wide motion/fade follows explicit relative times', () {
    final a = parse(
      assFixture(text: r'A{\move(10,20,110,120,500,1500)\fad(500,500)}'),
    ).cues.single.ass!;
    expect(a.motion!.at(0), (10, 20));
    expect(a.motion!.at(1000), (60, 70));
    expect(a.motion!.at(2000), (110, 120));
    expect(a.opacity(250, 2000), .5);
    expect(a.opacity(1000, 2000), 1);
    expect(a.opacity(1750, 2000), .5);
  });
  test('format columns reorder while dialogue commas remain text', () {
    final text = assFixture(text: 'a,b,c')
        .replaceFirst('Layer, Start, End', 'End, Start, Layer')
        .replaceFirst(
          'Dialogue: 0,0:00:01.00,0:00:03.00',
          'Dialogue: 0:00:03.00,0:00:01.00,0',
        );
    expect(parse(text).cues.single.ass!.runs.single.text, 'a,b,c');
  });
  test('SSA legacy top/center alignment and signed color', () {
    for (final (legacy, expected) in [
      (5, 7),
      (6, 8),
      (7, 9),
      (9, 4),
      (10, 5),
      (11, 6),
    ]) {
      final text = assFixture(ssa: true)
          .replaceFirst(',0,2,10,10,10,0,1', ',0,$legacy,10,10,10,0,1')
          .replaceFirst('20,255,', '20,-2147483393,');
      final a = parse(text, ssa: true).cues.single.ass!;
      expect(a.alignment, expected);
      expect(a.runs.first.style.color, 0xffff0000);
    }
  });
  for (final tag in [
    r'\p1',
    r'\k20',
    r'\t(0,500,\fs40)',
    r'\clip(0,0,1,1)',
    r'\blur2',
    r'\frz90',
    r'\pos(1,2)\move(1,2,3,4)',
    r'\fad(1500,1500)',
  ]) {
    test(
      'unsupported effect $tag rejects atomically',
      () => expect(
        () => parse(assFixture(text: '{$tag}secret')),
        reason(SubtitleParseReason.unsupported),
      ),
    );
  }
  for (final (label, mutate) in <(String, String Function(String))>[
    ('bad time', (s) => s.replaceFirst('0:00:01.00', '0:60:00.00')),
    ('reversed time', (s) => s.replaceFirst('0:00:03.00', '0:00:00.00')),
    (
      'unknown style',
      (s) => s.replaceFirst('0:00:03.00,Default', '0:00:03.00,Missing'),
    ),
    (
      'duplicate header',
      (s) => s.replaceFirst('PlayResX: 300', 'PlayResX: 300\nPlayResX: 400'),
    ),
    (
      'duplicate style',
      (s) => s.replaceFirst(
        '[Events]',
        '${s.split('\n').firstWhere((l) => l.startsWith('Style:'))}\n[Events]',
      ),
    ),
    ('wrong version', (s) => s.replaceFirst('v4.00+', 'v4.00')),
    ('bad color', (s) => s.replaceFirst('&H000000FF', '&Hgg')),
  ]) {
    test(
      label,
      () => expect(
        () => parse(mutate(assFixture())),
        reason(SubtitleParseReason.malformed),
      ),
    );
  }
  for (final text in [
    r'{\pos(NaN,1)}a',
    r'{\move(1,2,3)}a',
    r'{\b1a',
    r'a}',
    r'{\fs0}a',
  ]) {
    test(
      'malformed payload $text',
      () => expect(
        () => parse(assFixture(text: text)),
        reason(SubtitleParseReason.malformed),
      ),
    );
  }
  for (final (label, text) in [
    ('size', assFixture(text: r'{\fs257}a')),
    ('outline', assFixture(text: r'{\bord17}a')),
    ('coords', assFixture(text: r'{\pos(8193,0)}a')),
    ('time', assFixture().replaceFirst('0:00:03.00', '168:00:00.01')),
    ('runs', assFixture(text: List.filled(513, r'{\b1}a').join())),
    ('payload', assFixture(text: 'a' * 16385)),
    ('font', assFixture(text: '{\\fn${'a' * 129}}a')),
  ]) {
    test(
      '$label budget',
      () =>
          expect(() => parse(text), reason(SubtitleParseReason.limitExceeded)),
    );
  }
  test('active cue limit includes overlap but not adjacent boundaries', () {
    final line = 'Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,a';
    expect(
      () => parse(assFixture(extra: List.filled(64, line).join('\n'))),
      reason(SubtitleParseReason.limitExceeded),
    );
    expect(
      () =>
          parse(assFixture(), limits: const SubtitleLimits(maxCueCodeUnits: 2)),
      reason(SubtitleParseReason.limitExceeded),
    );
  });
  for (final wrap in ['0', '3']) {
    test('smart wrap $wrap accepted with hard and soft breaks', () {
      final cue = parse(
        assFixture(wrap: wrap, text: r'one\ntwo\Nthree'),
      ).cues.single;
      expect(cue.ass!.wrap, int.parse(wrap));
      expect(cue.ass!.runs.map((r) => r.text).join(), 'one two\nthree');
      expect(
        parse(assFixture(text: '{\\q$wrap}one')).cues.single.ass!.wrap,
        int.parse(wrap),
      );
    });
  }
  test('ordinary ASS without WrapStyle defaults to smart wrapping', () {
    expect(
      parse(
        assFixture().replaceAll('WrapStyle: 1\n', ''),
      ).cues.single.ass!.wrap,
      0,
    );
  });
  test(
    'attachments rejected; no font resource access',
    () => expect(
      () => parse('${assFixture()}\n[Fonts]\nfontname: secret.ttf'),
      reason(SubtitleParseReason.unsupported),
    ),
  );
  test(
    'font identity budget includes overridden fonts',
    () => expect(
      () => parse(
        assFixture(text: List.generate(129, (i) => '{\\fnFont$i}a').join()),
      ),
      reason(SubtitleParseReason.limitExceeded),
    ),
  );
  test('SSA BackColour supplies outline and legacy shadow alpha', () {
    final a = parse(
      assFixture(
        ssa: true,
      ).replaceFirst('20,255,255,0,0,', '20,255,255,0,65280,'),
      ssa: true,
    ).cues.single.ass!;
    expect(a.runs.first.style.outlineColor, 0xff00ff00);
    expect(a.runs.first.style.shadowColor, 0x7f00ff00);
  });
}
