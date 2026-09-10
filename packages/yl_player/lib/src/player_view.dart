import 'package:flutter/widgets.dart';

import 'player_controller.dart';

/// Displays a player's current-session video texture without app controls.
final class YlPlayerView extends StatelessWidget {
  const YlPlayerView({
    required this.controller,
    this.placeholder,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.backgroundColor = const Color(0xFF000000),
    this.filterQuality = FilterQuality.low,
    super.key,
  });

  final YlPlayerController controller;
  final Widget? placeholder;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final Color backgroundColor;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, child) => ValueListenableBuilder<int?>(
      valueListenable: controller.textureId,
      builder: (context, textureId, child) {
        final geometry = controller.state.videoGeometry;
        final showTexture =
            textureId != null &&
            geometry != null &&
            controller.isCurrentFramePresented;
        return ColoredBox(
          color: backgroundColor,
          child: ClipRect(
            child: showTexture
                ? FittedBox(
                    fit: fit,
                    alignment: alignment,
                    child: RotatedBox(
                      quarterTurns: geometry.rotationDegrees ~/ 90,
                      child: SizedBox(
                        width:
                            geometry.displaySize.width *
                            geometry.pixelAspectRatio,
                        height: geometry.displaySize.height,
                        child: Texture(
                          textureId: textureId,
                          filterQuality: filterQuality,
                        ),
                      ),
                    ),
                  )
                : placeholder == null
                ? const SizedBox.expand()
                : Center(child: placeholder),
          ),
        );
      },
    ),
  );
}
