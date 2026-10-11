part of 'mp4_subtitles.dart';

final class _Stpp implements _Mp4SubtitleEntry {
  const _Stpp();
  @override
  YlSubtitleFormat get format => YlSubtitleFormat.ttml;
  @override
  bool get forced => false;

  static _Stpp parse(List<int> b) {
    var at = 8;
    String field() {
      final start = at;
      while (at < b.length && b[at] != 0) {
        if (at - start >= 4096) _limit();
        at++;
      }
      if (at == b.length) _bad();
      final value = _utf8(b.sublist(start, at++));
      if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) _bad();
      return value;
    }

    final namespace = field();
    field(); // Schema location is descriptive metadata, never fetched.
    final auxiliary = field();
    if (namespace != 'http://www.w3.org/ns/ttml' || auxiliary.isNotEmpty) {
      _unsupported();
    }
    final extra = _vttBoxes(b, at, b.length, limit: 8);
    if (extra.length > 1) _bad();
    for (final box in extra) {
      if (box.type != 'btrt') _unsupported();
      if (box.size != 12) _bad();
    }
    return const _Stpp();
  }

  @override
  List<_Mp4Cue> decode(List<int> b) {
    final doc = SubtitleDocument.parseTtmlSample(b);
    return [
      for (final cue in doc.cues)
        _Mp4Cue(
          cue.payload,
          runs: cue.textRuns,
          identifier: cue.identifier,
          alignment: cue.alignment,
          ttml: cue,
        ),
    ];
  }
}
