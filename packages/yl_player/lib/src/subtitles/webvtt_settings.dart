part of 'subtitle_document.dart';

/// Shared strict WebVTT placement subset for file cues and MP4 sttg fields.
final class WebVttCueSettings {
  const WebVttCueSettings._(
    this.position,
    this.positionAlignment,
    this.alignment,
    this.inputBytes,
  );
  final double? position;
  final String positionAlignment, alignment;
  final int inputBytes;
  static WebVttCueSettings parse(String settings) {
    if (settings.length > 1024) _limit();
    if (RegExp(r'[\x00-\x08\x0a-\x1f\x7f]').hasMatch(settings)) _malformed();
    double? position;
    var positionAlignment = 'auto', alignment = 'center';
    if (settings.trim().isNotEmpty) {
      final seen = <String>{};
      for (final token in settings.trim().split(RegExp(r'[ \t]+'))) {
        final colon = token.indexOf(':');
        if (colon < 1 || colon == token.length - 1) _malformed();
        final key = token.substring(0, colon);
        final value = token.substring(colon + 1);
        if (!seen.add(key)) _malformed();
        switch (key) {
          case 'align':
            if (!const [
              'start',
              'center',
              'end',
              'left',
              'right',
            ].contains(value)) {
              _malformed();
            }
            alignment = value;
          case 'position':
            final match = RegExp(
              r'^([0-9]+(?:\.[0-9]+)?)%(?:,(line-left|center|line-right))?$',
            ).firstMatch(value);
            if (match == null) _malformed();
            position = double.tryParse(match.group(1)!);
            if (position == null || !position.isFinite || position > 100) {
              _malformed();
            }
            positionAlignment = match.group(2) ?? 'auto';
          default:
            _unsupported();
        }
      }
    }
    return WebVttCueSettings._(
      position,
      positionAlignment,
      alignment,
      utf8.encode(settings).length,
    );
  }
}
