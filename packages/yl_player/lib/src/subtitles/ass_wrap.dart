part of 'ass_overlay.dart';

/// Smart wrapping uses the engine's Unicode line boundaries and styled glyph
/// measurements, then balances within the original line count. Ten width probes
/// plus at most 128 local measurements bound expensive shaping per active cue.
/// An exhausted balancing budget retains already valid line breaks. No content,
/// grapheme or style is dropped, and hard breaks are never moved. Results live
/// only with the active overlay, so animation does not repeat these measurements.
List<AssTextRun> _wrapAss(AssCueLayout layout) {
  if (layout.wrap == 1 || layout.wrap == 2) return layout.runs;
  final text = layout.runs.map((r) => r.text).join();
  final maxWidth = layout.width - layout.left - layout.right;
  TextPainter shape(List<AssTextRun> runs, double width) => TextPainter(
    text: TextSpan(
      children: [
        for (final r in runs)
          TextSpan(text: r.text, style: _style(r.style, false, false)),
      ],
    ),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
  )..layout(maxWidth: width);
  final painter = shape(layout.runs, maxWidth);
  try {
    final original = painter.computeLineMetrics();
    if (original.length < 2) return layout.runs;
    var low = 0.0, high = maxWidth;
    for (var i = 0; i < 10; i++) {
      final width = (low + high) / 2;
      painter.layout(maxWidth: width);
      if (painter.computeLineMetrics().length > original.length) {
        low = width;
      } else {
        high = width;
      }
    }
    painter.layout(maxWidth: high);
    final lines = <_AssLine>[];
    for (final metric in painter.computeLineMetrics()) {
      final position = painter.getPositionForOffset(
        Offset(metric.left + .01, metric.baseline - metric.ascent / 2),
      );
      final range = painter.getLineBoundary(position);
      var start = range.start, end = range.end;
      while (end > start && text[end - 1] == '\n') {
        end--;
      }
      final hard = (end < text.length && text[end] == '\n');
      while (start < end && _assSpace(text.codeUnitAt(start))) {
        start++;
      }
      while (end > start && _assSpace(text.codeUnitAt(end - 1))) {
        end--;
      }
      lines.add(_AssLine(start, end, metric.width, hard));
    }
    if (layout.wrap == 3) {
      var budget = 128;
      double width(int start, int end) {
        final measurement = shape(
          _assSlice(layout.runs, start, end),
          double.infinity,
        );
        try {
          return measurement.width;
        } finally {
          measurement.dispose();
        }
      }

      for (var i = 0; i + 1 < lines.length && budget >= 3; i++) {
        final upper = lines[i], lower = lines[i + 1];
        if (upper.hard ||
            upper.start == upper.end ||
            lower.start == lower.end) {
          continue;
        }
        // Move the last Unicode word/cluster down only if the lines become
        // closer in length, or equally balanced with the lower line wider.
        while (upper.width > lower.width && budget >= 3) {
          // Ask the line breaker rather than the word selector: NBSP and
          // joined emoji are not necessarily one Unicode word, but must stay
          // together. Narrowing this line finds its last legal soft boundary.
          final probe = shape(
            _assSlice(layout.runs, upper.start, upper.end),
            math.max(.01, upper.width - .1),
          );
          int split;
          try {
            split =
                upper.start +
                probe.getLineBoundary(const TextPosition(offset: 0)).end;
          } finally {
            probe.dispose();
          }
          while (split < upper.end && _assSpace(text.codeUnitAt(split))) {
            split++;
          }
          if (split <= upper.start || split >= upper.end) break;
          var end = split;
          while (end > upper.start && _assSpace(text.codeUnitAt(end - 1))) {
            end--;
          }
          if (end == upper.start) break;
          budget -= 3;
          final top = width(upper.start, end), bottom = width(split, lower.end);
          if (bottom > maxWidth + .01 ||
              (top - bottom).abs() > (upper.width - lower.width).abs() + .01) {
            break;
          }
          upper.end = end;
          upper.width = top;
          lower.start = split;
          lower.width = bottom;
        }
      }
    }
    final result = <AssTextRun>[];
    final buffers = <StringBuffer>[];
    void append(String value, AssTextStyle style) {
      if (result.isEmpty || !identical(result.last.style, style)) {
        result.add(AssTextRun('', style));
        buffers.add(StringBuffer());
      }
      buffers.last.write(value);
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (i > 0) {
        append(
          '\n',
          result.isEmpty ? layout.runs.first.style : result.last.style,
        );
      }
      for (final run in _assSlice(layout.runs, line.start, line.end)) {
        append(run.text, run.style);
      }
    }
    return [
      for (var i = 0; i < result.length; i++)
        AssTextRun(buffers[i].toString(), result[i].style),
    ];
  } finally {
    painter.dispose();
  }
}

bool _assSpace(int unit) => unit == 0x20 || unit == 0x09;

List<AssTextRun> _assSlice(List<AssTextRun> runs, int start, int end) {
  final result = <AssTextRun>[];
  var offset = 0;
  for (final run in runs) {
    final next = offset + run.text.length;
    if (next > start && offset < end) {
      result.add(
        AssTextRun(
          run.text.substring(
            math.max(0, start - offset),
            math.min(run.text.length, end - offset),
          ),
          run.style,
        ),
      );
    }
    offset = next;
    if (offset >= end) break;
  }
  return result;
}

final class _AssLine {
  _AssLine(this.start, this.end, this.width, this.hard);
  int start, end;
  double width;
  final bool hard;
}
