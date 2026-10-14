import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'text_subtitle_runtime.dart';
import 'ttml_overlay.dart';
import 'ass_overlay.dart';
import 'pgs_overlay.dart';

/// Upright text in the video aperture, or the viewport during a video gap.
/// Cue validity follows programme time independently of video sample coverage.
final class TextSubtitleOverlay extends StatelessWidget {
  const TextSubtitleOverlay({
    required this.cues,
    required this.geometry,
    required this.fit,
    required this.alignment,
    super.key,
  });
  final List<TextSubtitleCue> cues;

  /// Null means no current video aperture; use the bounded viewport.
  final YlVideoGeometry? geometry;
  final BoxFit fit;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth ||
            !constraints.hasBoundedHeight ||
            constraints.biggest.isEmpty) {
          return const SizedBox.shrink();
        }
        final geometry = this.geometry;
        var input = geometry == null
            ? constraints.biggest
            : Size(
                geometry.displaySize.width * geometry.pixelAspectRatio,
                geometry.displaySize.height,
              );
        if (geometry?.rotationDegrees == 90 ||
            geometry?.rotationDegrees == 270) {
          input = Size(input.height, input.width);
        }
        final output = constraints.biggest;
        final sizes = applyBoxFit(fit, input, output);
        final resolved = alignment.resolve(
          Directionality.maybeOf(context) ?? TextDirection.ltr,
        );
        final destination = resolved.inscribe(
          sizes.destination,
          Offset.zero & output,
        );
        final rect = destination.intersect(Offset.zero & output);
        if (rect.isEmpty) return const SizedBox.shrink();
        final standardCues = cues
            .where(
              (c) =>
                  c.cue.region == null &&
                  c.cue.ass == null &&
                  c.cue.pgs == null,
            )
            .toList();
        final ttmlGroups = <String, List<TextSubtitleCue>>{};
        for (final cue in cues.where((c) => c.cue.region != null)) {
          (ttmlGroups[cue.cue.region!.id] ??= []).add(cue);
        }
        final sourceRect = resolved.inscribe(sizes.source, Offset.zero & input);
        // Alignment may place part of a contained video outside the viewport.
        // Map that clipping back into source space to preserve bitmap scale.
        final pgsSource = Rect.fromLTWH(
          (sourceRect.left +
                  (rect.left - destination.left) /
                      destination.width *
                      sourceRect.width) /
              input.width,
          (sourceRect.top +
                  (rect.top - destination.top) /
                      destination.height *
                      sourceRect.height) /
              input.height,
          rect.width / destination.width * sourceRect.width / input.width,
          rect.height / destination.height * sourceRect.height / input.height,
        );
        final fontSize = (rect.height * .055).clamp(12.0, 28.0);
        return Stack(
          children: [
            Positioned.fromRect(
              rect: rect,
              child: ClipRect(
                child: Stack(
                  children: [
                    CustomMultiChildLayout(
                      delegate: _CueLayout(
                        standardCues,
                        Directionality.maybeOf(context) ?? TextDirection.ltr,
                      ),
                      children: [
                        for (var i = 0; i < standardCues.length; i++)
                          LayoutId(
                            id: i,
                            child: RichText(
                              text: TextSpan(
                                style: TextStyle(
                                  color: const Color(0xffffffff),
                                  fontSize: fontSize,
                                  height: 1.25,
                                  backgroundColor: const Color(0xb3000000),
                                ),
                                children: [standardCues[i].text],
                              ),
                              textAlign:
                                  switch (standardCues[i].cue.alignment) {
                                    'start' => TextAlign.start,
                                    'end' => TextAlign.end,
                                    'left' => TextAlign.left,
                                    'right' => TextAlign.right,
                                    _ => TextAlign.center,
                                  },
                              textDirection:
                                  Directionality.maybeOf(context) ??
                                  TextDirection.ltr,
                              textScaler: TextScaler.noScaling,
                              overflow: TextOverflow.clip,
                            ),
                          ),
                      ],
                    ),
                    if (cues.any((c) => c.cue.ass != null))
                      AssSubtitleOverlay(
                        cues: cues.where((c) => c.cue.ass != null).toList(),
                      ),
                    for (final cue in cues.where((c) => c.cue.pgs != null))
                      PgsSubtitleOverlay(
                        frame: cue.cue.pgs!,
                        source: pgsSource,
                      ),
                    for (final group in ttmlGroups.values)
                      TtmlRegionOverlay(cues: group, aperture: rect.size),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _CueLayout extends MultiChildLayoutDelegate {
  _CueLayout(this.cues, this.direction);
  final List<TextSubtitleCue> cues;
  final TextDirection direction;
  @override
  void performLayout(Size size) {
    var bottom = size.height * .95;
    // File order reads top-to-bottom, including overlapping cues.
    for (var i = cues.length - 1; i >= 0; i--) {
      final cue = cues[i].cue;
      final defaultAnchor = switch (cue.alignment) {
        'start' => direction == TextDirection.rtl ? 1.0 : 0.0,
        'end' => direction == TextDirection.rtl ? 0.0 : 1.0,
        'left' => 0.0,
        'right' => 1.0,
        _ => .5,
      };
      final anchor = switch (cue.positionAlignment) {
        'line-left' => 0.0,
        'line-right' => 1.0,
        'center' => .5,
        _ => defaultAnchor,
      };
      final position = cue.positionPercent == null
          ? .05 + defaultAnchor * .9
          : cue.positionPercent! / 100;
      var width = size.width * .9;
      if (anchor > 0) width = math.min(width, position * size.width / anchor);
      if (anchor < 1) {
        width = math.min(width, (1 - position) * size.width / (1 - anchor));
      }
      final child = layoutChild(
        i,
        BoxConstraints(maxWidth: width, maxHeight: size.height),
      );
      bottom -= child.height;
      positionChild(
        i,
        Offset(position * size.width - child.width * anchor, bottom),
      );
      bottom -= 2;
    }
  }

  @override
  bool shouldRelayout(_CueLayout oldDelegate) => true;
}
