import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/src/subtitles/text_subtitle_runtime.dart';
import 'package:yl_player/yl_player.dart';

void main() {
  test('ASS overrides embedded in SRT are explicitly unsupported', () {
    expect(
      () => parseSubtitleText(r'{\an8}top'),
      throwsA(
        isA<YlPlayerException>().having(
          (e) => e.failure.code,
          'code',
          YlFailureCodes.subtitleUnsupported,
        ),
      ),
    );
  });
  test('safe nested styles and escaped Unicode remain plain text', () {
    final text = parseSubtitleText(
      '<b>A<i>B</i></b><u>C</u> &lt;script&gt; &#x1F600; &amp;',
    );
    expect(text.toPlainText(), 'ABC <script> 😀 &');
    final spans = text.children!.cast<TextSpan>();
    expect(spans[0].style!.fontWeight, FontWeight.bold);
    expect(spans[1].style!.fontWeight, FontWeight.bold);
    expect(spans[1].style!.fontStyle, FontStyle.italic);
    expect(spans[2].style!.decoration, TextDecoration.underline);
    expect(spans[3].style!.fontWeight, FontWeight.normal);
  });
  for (final source in [
    '<b>bad',
    '</b>bad',
    '<i><b>x</i></b>',
    'bad <',
    '&#0;',
    '&#xD800;',
    '&#x110000;',
  ]) {
    test('malformed markup rejects $source', () {
      expect(
        () => parseSubtitleText(source),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.subtitleMalformed,
          ),
        ),
      );
    });
  }
  for (final source in [
    '<script>secret</script>',
    '<font color="red">x</font>',
    '<v speaker>x</v>',
    '<ruby>x</ruby>',
    '&unknown;',
  ]) {
    test('unsupported effects reject $source', () {
      expect(
        () => parseSubtitleText(source),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.subtitleUnsupported,
          ),
        ),
      );
    });
  }
  test('style depth and span count bounded independently', () {
    for (final source in ['${'<b>' * 17}x${'</b>' * 17}', '<b>x</b>' * 513]) {
      expect(
        () => parseSubtitleText(source),
        throwsA(
          isA<YlPlayerException>().having(
            (e) => e.failure.code,
            'code',
            YlFailureCodes.subtitleTooLarge,
          ),
        ),
      );
    }
  });
}
