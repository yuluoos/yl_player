import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'player_controller.dart';

/// Displays current-session video using the negotiated presentation surface.
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

  /// Filtering for the Flutter texture fallback. Native surfaces render using
  /// their platform's video presentation pipeline.
  final FilterQuality filterQuality;

  Widget _placeholder() => placeholder == null
      ? const SizedBox.expand()
      : Center(child: placeholder);

  Widget _layout(YlVideoGeometry geometry, Widget surface) => FittedBox(
    fit: fit,
    alignment: alignment,
    child: RotatedBox(
      quarterTurns: geometry.rotationDegrees ~/ 90,
      child: SizedBox(
        width: geometry.displaySize.width * geometry.pixelAspectRatio,
        height: geometry.displaySize.height,
        child: surface,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, child) => ValueListenableBuilder<int?>(
      valueListenable: controller.textureId,
      builder: (context, textureId, child) {
        final geometry = controller.state.videoGeometry;
        final native = controller.nativeVideoSurface;
        final useNative =
            !kIsWeb &&
            native != null &&
            native.platform == defaultTargetPlatform &&
            (native.platform == TargetPlatform.iOS ||
                native.platform == TargetPlatform.macOS);
        final presented = controller.isCurrentFramePresented;
        final Widget content;
        if (textureId == null || geometry == null) {
          content = _placeholder();
        } else if (useNative) {
          // Keep the layer attached before FirstFrame and across session
          // replacement. Visibility never grants or changes session authority.
          content = Stack(
            fit: StackFit.expand,
            children: [
              IgnorePointer(
                child: Opacity(
                  opacity: presented ? 1 : 0,
                  child: _layout(
                    geometry,
                    native.platform == TargetPlatform.macOS
                        ? AppKitView(
                            key: ValueKey((
                              controller,
                              textureId,
                              native.viewType,
                            )),
                            viewType: native.viewType,
                            creationParams: <String, Object>{
                              'textureId': textureId,
                            },
                            creationParamsCodec: const StandardMessageCodec(),
                          )
                        : UiKitView(
                            key: ValueKey((
                              controller,
                              textureId,
                              native.viewType,
                            )),
                            viewType: native.viewType,
                            creationParams: <String, Object>{
                              'textureId': textureId,
                            },
                            creationParamsCodec: const StandardMessageCodec(),
                          ),
                  ),
                ),
              ),
              if (!presented) _placeholder(),
            ],
          );
        } else if (presented) {
          content = _layout(
            geometry,
            Texture(textureId: textureId, filterQuality: filterQuality),
          );
        } else {
          content = _placeholder();
        }
        return ColoredBox(
          color: backgroundColor,
          child: ClipRect(child: content),
        );
      },
    ),
  );
}
