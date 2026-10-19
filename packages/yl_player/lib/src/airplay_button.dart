import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'player_controller.dart';

/// Displays Apple's system route picker for an admitted AirPlay session.
/// The user selects the device; this widget never starts or reroutes playback.
final class YlAirPlayButton extends StatelessWidget {
  const YlAirPlayButton({
    required this.controller,
    this.size = 44,
    this.fallback,
    super.key,
  });

  final YlPlayerController controller;
  final double size;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: ValueListenableBuilder<YlAirPlayState>(
      valueListenable: controller.airPlayState,
      builder: (context, state, child) {
        final surface = controller.airPlayRoutePickerSurface;
        if (kIsWeb ||
            !state.supported ||
            !state.enabled ||
            surface == null ||
            surface.platform != defaultTargetPlatform) {
          return fallback ?? const SizedBox.shrink();
        }
        final params = <String, Object>{'channelSuffix': surface.channelSuffix};
        final key = ValueKey((controller, surface.channelSuffix));
        return switch (surface.platform) {
          TargetPlatform.iOS => UiKitView(
            key: key,
            viewType: surface.viewType,
            creationParams: params,
            creationParamsCodec: const StandardMessageCodec(),
          ),
          TargetPlatform.macOS => AppKitView(
            key: key,
            viewType: surface.viewType,
            creationParams: params,
            creationParamsCodec: const StandardMessageCodec(),
          ),
          _ => fallback ?? const SizedBox.shrink(),
        };
      },
    ),
  );
}
