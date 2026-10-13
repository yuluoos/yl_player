part of 'mp4_subtitles.dart';

sealed class _Mp4SubtitleEntry {
  YlSubtitleFormat get format;
  bool get forced;
  List<_Mp4Cue> decode(List<int> bytes);
}

final class _Mp4Cue {
  const _Mp4Cue(
    this.text, {
    this.runs,
    this.identifier,
    this.settings,
    this.ttml,
    this.alignment = 'center',
  });
  final String text, alignment;
  final List<SubtitleTextRun>? runs;
  final String? identifier;
  final WebVttCueSettings? settings;
  final SubtitleCue? ttml;
}

/// Local child caps and the owning resource budget both apply before parsing.
List<_Box> _vttBoxes(
  List<int> b,
  int start,
  int end, {
  required void Function() countBox,
  int limit = 64,
}) {
  final boxes = <_Box>[];
  for (var p = start; p < end;) {
    if (boxes.length >= limit) _limit();
    countBox();
    if (end - p < 8) _bad();
    var size = _u(b, p), header = 8;
    if (size == 1) {
      if (end - p < 16) _bad();
      size = _u(b, p + 8, 8);
      header = 16;
    }
    if (size == 0) _unsupported();
    if (size < header || size > end - p) _bad();
    boxes.add(_Box(_type(b, p + 4), p + header, p + size));
    p += size;
  }
  return boxes;
}

String _vttString(List<int> b, _Box box, int limit) {
  if (box.size > limit * 4) _limit();
  final s = _utf8(b.sublist(box.start, box.end));
  if (s.length > limit) _limit();
  return s;
}

final class _Wvtt implements _Mp4SubtitleEntry {
  const _Wvtt(this._countBox);
  final void Function() _countBox;
  @override
  YlSubtitleFormat get format => YlSubtitleFormat.webvtt;
  @override
  bool get forced => false;
  static _Wvtt parse(List<int> b, void Function() countBox) {
    final fields = <String>{};
    for (final box in _vttBoxes(b, 8, b.length, countBox: countBox, limit: 8)) {
      if (!fields.add(box.type)) _bad();
      switch (box.type) {
        case 'vttC':
          final config = _vttString(b, box, 16384);
          final doc = SubtitleDocument.parse(
            utf8.encode(config),
            format: SubtitleFormat.webvtt,
          );
          if (doc.cues.isNotEmpty) _unsupported();
        case 'vlab':
          final label = _vttString(b, box, 1024);
          if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(label)) _bad();
        case 'btrt':
          if (box.size != 12) _bad();
        default:
          _unsupported();
      }
    }
    if (!fields.contains('vttC')) _bad();
    return _Wvtt(countBox);
  }

  @override
  List<_Mp4Cue> decode(List<int> b) {
    final boxes = _vttBoxes(b, 0, b.length, countBox: _countBox);
    if (boxes.isEmpty) _bad();
    final result = <_Mp4Cue>[];
    for (final box in boxes) {
      if (box.type == 'vtte') {
        if (box.size != 0 || boxes.length != 1) _bad();
        return const [];
      }
      if (box.type != 'vttc') _unsupported();
      final fields = <String, _Box>{};
      for (final child in _vttBoxes(
        b,
        box.start,
        box.end,
        countBox: _countBox,
        limit: 8,
      )) {
        if (!['payl', 'iden', 'sttg', 'ctim'].contains(child.type)) {
          _unsupported();
        }
        if (fields.containsKey(child.type)) _bad();
        fields[child.type] = child;
      }
      final payload = fields['payl'];
      if (payload == null) _bad();
      final text = _vttString(
        b,
        payload,
        16384,
      ).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      final id = fields['iden'] == null
          ? null
          : _vttString(b, fields['iden']!, 1024);
      if (id != null &&
          (id.contains('-->') || RegExp(r'[\x00-\x1f\x7f]').hasMatch(id))) {
        _bad();
      }
      final settings = WebVttCueSettings.parse(
        fields['sttg'] == null ? '' : _vttString(b, fields['sttg']!, 1024),
      );
      if (fields['ctim'] case final time?) {
        // Original cue time is metadata for split cues; sample timing remains
        // authoritative. Inline timestamp/karaoke rendering is unsupported.
        final value = _vttString(b, time, 32);
        final match = RegExp(
          r'^(?:[0-9]{2,}:)?[0-5][0-9]:[0-5][0-9]\.[0-9]{3}$',
        ).firstMatch(value);
        if (match == null) _bad();
      }
      if (text.isNotEmpty) {
        result.add(_Mp4Cue(text, identifier: id, settings: settings));
      }
    }
    return result;
  }
}
