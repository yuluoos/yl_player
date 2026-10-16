import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'player_controller.dart';
import 'subtitles/text_subtitle_overlay.dart';

/// Displays current-session video using the negotiated presentation surface.
///
/// Apple native video surfaces are composed by the platform and may not appear
/// in a Flutter repaint-boundary image. Mounting this widget does not itself
/// establish that a frame has been presented; observe the session's first frame.
/// This widget does not start playback or take ownership of the controller.
final class YlPlayerView extends StatelessWidget {
  /// Binds video and opted-in subtitles to the controller’s current session.
  const YlPlayerView({
    required this.controller,
    this.placeholder,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.backgroundColor = const Color(0xFF000000),
    this.filterQuality = FilterQuality.low,
    super.key,
  });

  /// Player whose current video surface and subtitle projection are displayed.
  final YlPlayerController controller;

  /// Content shown while ordinary video has no current frame or geometry.
  final Widget? placeholder;

  /// Video aperture fitting; protected surfaces require [BoxFit.contain].
  final BoxFit fit;

  /// Video aperture placement; protected surfaces require [Alignment.center].
  final AlignmentGeometry alignment;

  /// Ordinary-video background. Protected output always uses opaque black.
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
        final protected = controller.protectedVideoSurface;
        if (protected != null) {
          if (kIsWeb ||
              protected.platform != defaultTargetPlatform ||
              ![
                TargetPlatform.android,
                TargetPlatform.iOS,
                TargetPlatform.macOS,
              ].contains(protected.platform) ||
              protected.sessionId != controller.state.sessionId?.value) {
            return const ColoredBox(color: Color(0xFF000000));
          }
          if (fit != BoxFit.contain || alignment != Alignment.center) {
            throw FlutterError(
              'Protected video currently requires BoxFit.contain and Alignment.center.',
            );
          }
          return ColoredBox(
            color: const Color(0xFF000000),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _ProtectedVideoView(
                  key: ValueKey((controller, protected)),
                  controller: controller,
                  surface: protected,
                ),
                // Separate composition only: never read or flatten secure video.
                if (controller.textSubtitleCues.isNotEmpty)
                  TextSubtitleOverlay(
                    cues: controller.textSubtitleCues,
                    geometry: controller.state.videoGeometry,
                    fit: fit,
                    alignment: alignment,
                  ),
              ],
            ),
          );
        }
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
          child: ClipRect(
            child: controller.textSubtitleCues.isEmpty || textureId == null
                ? content
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      content,
                      TextSubtitleOverlay(
                        cues: controller.textSubtitleCues,
                        geometry: geometry,
                        fit: fit,
                        alignment: alignment,
                      ),
                    ],
                  ),
          ),
        );
      },
    ),
  );
}

/// Native secure SurfaceView owns geometry and its pre-frame black cover. Never
/// put this output through Flutter texture, opacity or pixel transforms.
class _ProtectedVideoView extends StatefulWidget {
  const _ProtectedVideoView({
    super.key,
    required this.controller,
    required this.surface,
  });
  final YlPlayerController controller;
  final YlProtectedVideoSurface surface;
  @override
  State<_ProtectedVideoView> createState() => _ProtectedVideoViewState();
}

class _ProtectedVideoViewState extends State<_ProtectedVideoView> {
  int? _viewId;
  void _created(int id) {
    if (!mounted) return;
    _viewId = id;
    unawaited(
      widget.controller.attachProtectedView(widget.surface, id).catchError((
        Object _,
      ) {
        // The adapter publishes the sanitized failure through its player state.
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final params = <String, Object>{
      'playerId': widget.surface.playerId,
      'surfaceId': widget.surface.surfaceId,
      'sessionId': widget.surface.sessionId,
      'generation': widget.surface.generation,
    };
    if (widget.surface.platform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: widget.surface.viewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _created,
      );
    }
    if (widget.surface.platform == TargetPlatform.macOS) {
      return AppKitView(
        viewType: widget.surface.viewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _created,
      );
    }
    return PlatformViewLink(
      viewType: widget.surface.viewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      ),
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: widget.surface.viewType,
          layoutDirection: Directionality.of(context),
          creationParams: <String, Object>{
            'playerId': widget.surface.playerId,
            'surfaceId': widget.surface.surfaceId,
            'sessionId': widget.surface.sessionId,
            'generation': widget.surface.generation,
          },
          creationParamsCodec: const StandardMessageCodec(),
        );
        controller.addOnPlatformViewCreatedListener(
          params.onPlatformViewCreated,
        );
        controller.addOnPlatformViewCreatedListener(_created);
        unawaited(controller.create());
        return controller;
      },
    );
  }

  @override
  void dispose() {
    final id = _viewId;
    if (id != null) {
      unawaited(
        widget.controller
            .detachProtectedView(widget.surface, id)
            .catchError((Object _) {}),
      );
    }
    super.dispose();
  }
}
