import 'package:flutter/widgets.dart';
import 'subtitle_document.dart';
import 'text_subtitle_runtime.dart';

/// Region coordinates are relative to the player's visible video aperture.
final class TtmlRegionOverlay extends StatelessWidget {
  const TtmlRegionOverlay({
    required this.cues,
    required this.aperture,
    super.key,
  });
  final List<TextSubtitleCue> cues;
  final Size aperture;
  @override
  Widget build(BuildContext context) {
    final region = cues.first.cue.region!;
    return Positioned(
      left: aperture.width * region.x,
      top: aperture.height * region.y,
      width: aperture.width * region.width,
      height: aperture.height * region.height,
      child: ClipRect(
        child: CustomMultiChildLayout(
          delegate: _TtmlFlow(region, cues.length),
          children: [
            for (var i = 0; i < cues.length; i++)
              LayoutId(
                id: i,
                child: RichText(
                  text: TextSpan(
                    style: TextStyle(
                      color: const Color(0xffffffff),
                      fontFamily: 'monospace',
                      fontSize: aperture.height / 15,
                      height: 1.25,
                    ),
                    children: [cues[i].text],
                  ),
                  textDirection: TextDirection.ltr,
                  textScaler: TextScaler.noScaling,
                  textAlign: switch (cues[i].cue.alignment) {
                    'right' || 'end' => TextAlign.right,
                    'center' => TextAlign.center,
                    _ => TextAlign.left,
                  },
                  overflow: TextOverflow.clip,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TtmlFlow extends MultiChildLayoutDelegate {
  _TtmlFlow(this.region, this.count);
  final SubtitleRegion region;
  final int count;
  @override
  void performLayout(Size size) {
    final heights = <double>[];
    var total = 0.0;
    for (var i = 0; i < count; i++) {
      final child = layoutChild(i, BoxConstraints.tightFor(width: size.width));
      heights.add(child.height);
      total += child.height;
    }
    var top = switch (region.displayAlign) {
      'after' => size.height - total,
      'center' => (size.height - total) / 2,
      _ => 0.0,
    };
    for (var i = 0; i < count; i++) {
      positionChild(i, Offset(0, top));
      top += heights[i];
    }
  }

  @override
  bool shouldRelayout(_TtmlFlow oldDelegate) => true;
}
