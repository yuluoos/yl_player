import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/subtitle_document.dart';

String document(String content, {String head = '', String attributes = ''}) =>
    '<tt xmlns="http://www.w3.org/ns/ttml" xmlns:tts="http://www.w3.org/ns/ttml#styling" '
    'xmlns:ttp="http://www.w3.org/ns/ttml#parameter" $attributes><head>$head</head><body><div>$content</div></body></tt>';
SubtitleDocument parse(
  String xml, {
  SubtitleLimits limits = const SubtitleLimits(),
}) => SubtitleDocument.parse(
  utf8.encode(xml),
  format: SubtitleFormat.ttml,
  limits: limits,
);
Matcher reason(SubtitleParseReason reason) => throwsA(
  isA<SubtitleParseException>().having((e) => e.reason, 'reason', reason),
);
void main() {
  test('namespace prefixes, BOM, decimal clocks and media offsets', () {
    final doc = parse(
      '\uFEFF<z:tt xmlns:z="http://www.w3.org/ns/ttml"><z:body><z:div>'
      '<z:p begin="00:00:01.000001" end="2s">one</z:p><z:p begin="1500ms" dur="1.5s">two</z:p>'
      '</z:div></z:body></z:tt>',
    );
    expect(doc.cues.first.start.inMicroseconds, 1000001);
    expect(
      doc.cuesAt(const Duration(milliseconds: 1600)).map((c) => c.payload),
      ['one', 'two'],
    );
    expect(doc.cuesAt(const Duration(seconds: 3)), isEmpty);
    expect(
      doc.cuesAt(
        const Duration(milliseconds: 1200),
        offset: const Duration(milliseconds: 500),
      ),
      isEmpty,
    );
  });
  test('parent relative timing, duration and clipping', () {
    final doc = parse(
      '<tt xmlns="http://www.w3.org/ns/ttml"><body begin="1s" end="5s"><div begin="1s" dur="2s">'
      '<p begin="0.5s" end="3s">clipped</p><p begin="3s" dur="1s">outside</p>'
      '</div></body></tt>',
    );
    expect(doc.cues, hasLength(1));
    expect(doc.cues.single.start, const Duration(milliseconds: 2500));
    expect(doc.cues.single.end, const Duration(seconds: 4));
  });
  test('default whitespace across span boundaries, br and XML entities', () {
    final doc = parse(
      document(
        '<p begin="0s" end="1s">  one\n <span> two </span>  &lt;b&gt;&amp;&#x1F600;<br/> next </p>',
      ),
    );
    expect(doc.cues.single.payload, 'one two <b>&😀\nnext');
  });
  test('xml space preserve inherits and CDATA remains plain text', () {
    final doc = parse(
      document(
        '<p begin="0s" end="1s" xml:space="preserve"> a <span><![CDATA[<b>]]></span>\n b </p>',
      ),
    );
    expect(doc.cues.single.payload, ' a <b>\n b ');
  });
  test('referenced style chain and inline normal override inherit', () {
    final doc = parse(
      document(
        '<p begin="0s" end="1s" style="b c">one<span tts:fontWeight="normal">two</span></p>',
        head:
            '<styling><style xml:id="a" tts:fontWeight="bold"/><style xml:id="b" style="a" tts:fontStyle="italic"/>'
            '<style xml:id="c" tts:color="#12ab34" tts:textDecoration="underline"/></styling>',
      ),
    );
    final runs = doc.cues.single.textRuns!;
    expect(runs.first.bold, isTrue);
    expect(runs.first.italic, isTrue);
    expect(runs.first.color, 0xff12ab34);
    expect(runs.first.underline, isTrue);
    expect(runs.last.bold, isFalse);
    expect(runs.last.italic, isTrue);
  });
  test('region geometry alignment and inherited style', () {
    final doc = parse(
      document(
        '<p begin="0s" end="1s" region="r">one</p>',
        head:
            '<layout><region xml:id="r" tts:origin="10% 60%" tts:extent="80% 30%" tts:displayAlign="after" '
            'tts:textAlign="right" tts:color="yellow"/></layout>',
      ),
    );
    final cue = doc.cues.single;
    expect(cue.region!.x, .1);
    expect(cue.region!.y, .6);
    expect(cue.region!.width, .8);
    expect(cue.region!.height, .3);
    expect(cue.region!.displayAlign, 'after');
    expect(cue.alignment, 'right');
    expect(cue.textRuns!.single.color, 0xffffff00);
  });
  for (final xml in [
    '<tt xmlns="http://www.w3.org/ns/ttml"><body></tt>',
    document('<p begin="2s" end="1s">bad</p>'),
    document('<p begin="00:61:00" end="1s">bad</p>'),
    document('<p begin="0s" end="1s">&unknown;</p>'),
    document('<p begin="0s" end="1s">&#0;</p>'),
    document('<p begin="0s" end="1s">&#xD800;</p>'),
    document('<p begin="0s" end="1s">bare & bad</p>'),
    document('<p begin="0s" end="1s" style="missing">bad</p>'),
    document('<p begin="0s" end="1s" region="missing">bad</p>'),
    document(
      '<p begin="0s" end="1s" xml:id="a">a</p><p begin="1s" end="2s" xml:id="a">b</p>',
    ),
    document('<p begin="0s" end="1s" begin="2s">bad</p>'),
    document(
      '<p begin="0s" end="1s" style="a">bad</p>',
      head:
          '<styling><style xml:id="a" style="b"/><style xml:id="b" style="a"/></styling>',
    ),
  ]) {
    test(
      'reject malformed ${xml.hashCode}',
      () => expect(() => parse(xml), reason(SubtitleParseReason.malformed)),
    );
  }
  for (final xml in [
    document(
      '<p begin="0s" end="1s">one</p>',
      attributes: 'ttp:timeBase="smpte"',
    ),
    document('<p begin="00:00:01:12" end="2s">one</p>'),
    document('<p begin="2f" end="2s">one</p>'),
    document('<p begin="0s" end="1s"><span begin="0.5s">timed</span></p>'),
    document('<p begin="0s" end="1s" tts:fontFamily="remote">one</p>'),
    document('<p begin="0s" end="1s" tts:writingMode="tbrl">one</p>'),
    document('<p begin="0s" end="1s"><set tts:color="red"/>one</p>'),
    document(
      '<p begin="0s" end="1s" region="r">one</p>',
      head:
          '<layout><region xml:id="r" tts:origin="0px 0px" tts:extent="80% 20%"/></layout>',
    ),
    '<?xml-stylesheet href="http://secret/style"?>${document('<p begin="0s" end="1s">one</p>')}',
    '<!DOCTYPE tt [<!ENTITY x SYSTEM "http://secret/entity">]>${document('<p begin="0s" end="1s">&x;</p>')}',
    document(
      '<p begin="0s" end="1s">one</p>',
      attributes: 'xmlns:x="urn:extension" x:active="true"',
    ),
  ]) {
    test(
      'reject unsupported ${xml.hashCode}',
      () => expect(() => parse(xml), reason(SubtitleParseReason.unsupported)),
    );
  }
  test('bounded cues and active intervals', () {
    final xml = document(List.filled(3, '<p begin="0s" end="1s">a</p>').join());
    expect(
      () => parse(xml, limits: const SubtitleLimits(maxCues: 2)),
      reason(SubtitleParseReason.limitExceeded),
    );
    expect(
      () => parse(xml, limits: const SubtitleLimits(maxActiveCues: 2)),
      reason(SubtitleParseReason.limitExceeded),
    );
  });
  test('bounded nesting and payload before rendering', () {
    expect(
      () => parse(
        document(
          '<p begin="0s" end="1s">${'<span>' * 40}x${'</span>' * 40}</p>',
        ),
      ),
      reason(SubtitleParseReason.limitExceeded),
    );
    expect(
      () => parse(
        document('<p begin="0s" end="1s">12345</p>'),
        limits: const SubtitleLimits(maxCueCodeUnits: 4),
      ),
      reason(SubtitleParseReason.limitExceeded),
    );
  });
  test('large offset cannot overflow into admitted media interval', () {
    expect(
      () => parse(document('<p begin="0s" end="5124095577h">overflow</p>')),
      reason(SubtitleParseReason.limitExceeded),
    );
  });
  test('finite ancestor at seven-day boundary supplies paragraph end', () {
    final doc = parse(
      '<tt xmlns="http://www.w3.org/ns/ttml"><body end="168h"><div><p>one</p></div></body></tt>',
    );
    expect(doc.cues.single.end, const Duration(days: 7));
  });
  test('unprefixed attributes stay unqualified with a default namespace', () {
    final doc = parse(document('<p begin="0s" dur="1s">one</p>'));
    expect(doc.cues.single.end, const Duration(seconds: 1));
  });
  test('limits style count, chain depth and per-cue rendered runs', () {
    expect(
      () => parse(
        document(
          '<p begin="0s" end="1s">one</p>',
          head:
              '<styling>${List.generate(129, (i) => '<style xml:id="s$i"/>').join()}</styling>',
        ),
      ),
      reason(SubtitleParseReason.limitExceeded),
    );
    expect(
      () => parse(
        document(
          '<p begin="0s" end="1s">one</p>',
          head:
              '<styling>${List.generate(34, (i) => '<style xml:id="s$i"${i < 33 ? ' style="s${i + 1}"' : ''}/>').join()}</styling>',
        ),
      ),
      reason(SubtitleParseReason.limitExceeded),
    );
    expect(
      () => parse(
        document(
          '<p begin="0s" end="1s">${List.filled(513, '<span>x</span>').join()}</p>',
        ),
      ),
      reason(SubtitleParseReason.limitExceeded),
    );
  });
  test('empty or clipped content still rejects bad style references', () {
    expect(
      () => parse(
        document('<p begin="0s" end="0s"><span style="missing">x</span></p>'),
      ),
      reason(SubtitleParseReason.malformed),
    );
  });
  final valid = document('<p dur="1s">one</p>');
  for (final (name, xml) in [
    ('leading text', 'garbage$valid'),
    ('trailing text', '${valid}garbage'),
    ('outside cdata', '<![CDATA[ ]]>$valid'),
    (
      'nested declaration',
      document('<p dur="1s"><?xml version="1.0"?>one</p>'),
    ),
    ('late declaration', ' \n<?xml version="1.0"?>$valid'),
    ('unquoted attribute', document('<p dur="1s" xml:lang=en>one</p>')),
    ('missing attribute value', document('<p dur="1s" xml:lang>one</p>')),
    ('less than in attribute', document('<p dur="1s" xml:lang="en<">one</p>')),
    ('double hyphen comment', '<!--bad--comment-->$valid'),
    ('trailing hyphen comment', '<!--bad--->$valid'),
    (
      'duplicate namespace',
      valid.replaceFirst(
        '<tt ',
        '<tt xmlns:unused="urn:a" xmlns:unused="urn:b" ',
      ),
    ),
    (
      'reserved prefix',
      valid.replaceFirst('<tt ', '<tt xmlns:xml="urn:wrong" '),
    ),
    (
      'reserved namespace alias',
      valid.replaceFirst(
        '<tt ',
        '<tt xmlns:unused="http://www.w3.org/XML/1998/namespace" ',
      ),
    ),
    (
      'empty prefixed namespace',
      valid.replaceFirst('<tt ', '<tt xmlns:unused="" '),
    ),
    (
      'cdata closing in text',
      document('<p dur="1s">bad]]&gt;</p>').replaceFirst(']]&gt;', ']]>'),
    ),
    ('missing declaration version', '<?xml?>$valid'),
    (
      'duplicate declaration version',
      '<?xml version="1.0" version="1.0"?>$valid',
    ),
    ('wrong standalone', '<?xml version="1.0" standalone="maybe"?>$valid'),
  ]) {
    test(
      'strict XML rejects $name',
      () => expect(() => parse(xml), reason(SubtitleParseReason.malformed)),
    );
  }
  test('XML comments and declarations at legal boundaries remain usable', () {
    expect(
      parse(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><!--before-->$valid<!--after-->',
      ).cues.single.payload,
      'one',
    );
  });
  test('style-chain budget is independent of declaration order and cache', () {
    final styles = List.generate(
      34,
      (i) => '<style xml:id="s$i"${i == 0 ? '' : ' style="s${i - 1}"'}/>',
    );
    for (final ordered in [styles, styles.reversed]) {
      expect(
        () => parse(
          document(
            '<p dur="1s" style="s33">one</p>',
            head: '<styling>${ordered.join()}</styling>',
          ),
        ),
        reason(SubtitleParseReason.limitExceeded),
      );
    }
  });
  test('diagnostic never reveals XML text', () {
    try {
      parse(document('<p begin="secret" end="1s">token</p>'));
      fail('must fail');
    } on SubtitleParseException catch (e) {
      expect(e.toString(), isNot(contains('secret')));
      expect(e.toString(), isNot(contains('token')));
    }
  });
}
