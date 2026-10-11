// Owned UTF-8 samples; no external fonts or subtitle content.
String assFixture({
  String text = r'{\b1}one & {\i1}two',
  String extra = '',
  bool ssa = false,
  String wrap = '1',
}) =>
    '''[Script Info]
ScriptType: ${ssa ? 'v4.00' : 'v4.00+'}
PlayResX: 300
PlayResY: 200
WrapStyle: $wrap
ScaledBorderAndShadow: yes
[${ssa ? 'V4 Styles' : 'V4+ Styles'}]
Format: ${ssa ? 'Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding' : 'Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding'}
Style: ${ssa ? 'Default,Ahem,20,255,255,0,0,0,0,1,2,0,2,10,10,10,0,1' : 'Default,Ahem,20,&H000000FF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1'}
[Events]
Format: ${ssa ? 'Marked' : 'Layer'}, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: ${ssa ? 'Marked=0' : '0'},0:00:01.00,0:00:03.00,Default,,0,0,0,,$text
$extra''';
