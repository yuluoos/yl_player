import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'subtitle_document.dart';
import 'text_subtitle_runtime.dart';

part 'ass_wrap.dart';

/// Bounded script-space text composition. Flutter owns font fallback; no font
/// downloads, retained pictures, frame timers or native/video pixel reads.
final class AssSubtitleOverlay extends StatefulWidget {
  const AssSubtitleOverlay({required this.cues, super.key});
  final List<TextSubtitleCue> cues;
  @override
  State<AssSubtitleOverlay> createState() => _AssSubtitleOverlayState();
}

final class _AssSubtitleOverlayState extends State<AssSubtitleOverlay> {
  // Only active cue layouts survive a rebuild; no catalog-wide font/text cache.
  final _runs = <AssCueLayout, List<AssTextRun>>{};
  @override
  void initState() {
    super.initState();
    PaintingBinding.instance.systemFonts.addListener(_fontsChanged);
  }

  void _fontsChanged() => setState(_runs.clear);

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(_fontsChanged);
    _runs.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.cues.map((c) => c.cue.ass!).toSet();
    _runs.removeWhere((layout, _) => !active.contains(layout));
    for (final layout in active) {
      _runs.putIfAbsent(layout, () => _wrapAss(layout));
    }
    return Positioned.fill(
      child: Semantics(
        label: widget.cues.map((c) => c.text.toPlainText()).join('\n'),
        child: CustomPaint(painter: _AssPainter(widget.cues, Map.of(_runs))),
      ),
    );
  }
}

final class _AssPainter extends CustomPainter {
  _AssPainter(this.cues, this.runs);
  final Map<AssCueLayout, List<AssTextRun>> runs;
  final List<TextSubtitleCue> cues;
  @override
  void paint(Canvas canvas, Size size) {
    final ordered = [...cues]
      ..sort((a, b) {
        final order = a.cue.ass!.layer.compareTo(b.cue.ass!.layer);
        return order == 0 ? a.cue.ordinal.compareTo(b.cue.ordinal) : order;
      });
    final occupied = <(int, Rect)>[];
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final cue in ordered) {
      final a = cue.cue.ass!;
      final opacity = a.opacity(
        cue.elapsed.inMicroseconds / 1000,
        (cue.cue.end - cue.cue.start).inMicroseconds / 1000,
      );
      final horizontal = (a.alignment - 1) % 3;
      final vertical = (a.alignment - 1) ~/ 3;
      final textAlign = [
        TextAlign.left,
        TextAlign.center,
        TextAlign.right,
      ][horizontal];
      TextPainter painter(bool outline, {bool shadow = false}) =>
          TextPainter(
            text: TextSpan(
              children: [
                for (final run in runs[a]!)
                  TextSpan(
                    text: run.text,
                    style: _style(run.style, outline, shadow),
                  ),
              ],
            ),
            textDirection: TextDirection.ltr,
            textAlign: textAlign,
            textScaler: TextScaler.noScaling,
            textWidthBasis: TextWidthBasis.longestLine,
          )..layout(
            maxWidth: a.wrap != 1
                ? double.infinity
                : a.width - a.left - a.right,
          );
      final fill = painter(false);
      final extraPainters = <TextPainter>[];
      try {
        var x = [
          a.left,
          (a.width + a.left - a.right) / 2,
          a.width - a.right,
        ][horizontal];
        var y = [a.height - a.vertical, a.height / 2, a.vertical][vertical];
        if (a.motion != null) {
          final pos = a.motion!.at(cue.elapsed.inMicroseconds / 1000);
          x = pos.$1;
          y = pos.$2;
        }
        x -= fill.width * horizontal / 2;
        y -= fill.height * (1 - vertical / 2);
        final padding = a.runs.fold<double>(
          0,
          (v, r) => math.max(v, r.style.outline + r.style.shadow),
        );
        var box = Rect.fromLTWH(x, y, fill.width, fill.height).inflate(padding);
        if (a.motion == null) {
          // At most 64 existing rectangles. Each collision moves fully past an
          // occupied edge, so this loop has a strict active-cue bound.
          for (var attempt = 0; attempt < ordered.length; attempt++) {
            final collisions = occupied.where(
              (b) => b.$1 == a.layer && b.$2.overlaps(box),
            );
            if (collisions.isEmpty) break;
            final delta = vertical == 0
                ? collisions.map((b) => b.$2.top - box.bottom).reduce(math.min)
                : collisions.map((b) => b.$2.bottom - box.top).reduce(math.max);
            y += delta;
            box = box.shift(Offset(0, delta));
          }
          occupied.add((a.layer, box));
        }
        canvas.save();
        canvas.scale(size.width / a.width, size.height / a.height);
        if (opacity < 1) {
          canvas.saveLayer(
            box.intersect(Rect.fromLTWH(0, 0, a.width, a.height)),
            Paint()..color = Color.fromRGBO(255, 255, 255, opacity),
          );
        }
        final outlined = a.runs.any((r) => r.style.outline > 0);
        void paintPass(bool border, Offset origin, {bool shadow = false}) {
          final pass = painter(border, shadow: shadow);
          extraPainters.add(pass);
          pass.paint(canvas, origin);
        }

        final shadow = a.runs.first.style.shadow;
        if (shadow > 0) {
          final origin = Offset(x + shadow, y + shadow);
          if (outlined) paintPass(true, origin, shadow: true);
          paintPass(false, origin, shadow: true);
        }
        if (outlined) paintPass(true, Offset(x, y));
        fill.paint(canvas, Offset(x, y));
        if (opacity < 1) canvas.restore();
        canvas.restore();
      } finally {
        fill.dispose();
        for (final p in extraPainters) {
          p.dispose();
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AssPainter oldDelegate) => true;
}

TextStyle _style(AssTextStyle s, bool outline, bool shadow) {
  return TextStyle(
    fontFamily: s.font,
    fontFamilyFallback: const ['sans-serif'],
    fontSize: s.size,
    height: 1,
    leadingDistribution: TextLeadingDistribution.even,
    fontWeight: s.bold ? FontWeight.bold : FontWeight.normal,
    fontStyle: s.italic ? FontStyle.italic : FontStyle.normal,
    decoration: TextDecoration.combine([
      if (s.underline) TextDecoration.underline,
      if (s.strikeout) TextDecoration.lineThrough,
    ]),
    foreground: Paint()
      ..color = outline && s.outline == 0
          ? const Color(0x00000000)
          : Color(
              shadow
                  ? s.shadowColor
                  : outline
                  ? s.outlineColor
                  : s.color,
            )
      ..style = outline ? PaintingStyle.stroke : PaintingStyle.fill
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = s.outline * 2,
  );
}
