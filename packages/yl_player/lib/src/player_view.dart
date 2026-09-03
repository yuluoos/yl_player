import 'package:flutter/widgets.dart';

import 'player_controller.dart';

/// Displays a player's native video texture without application controls.
final class YlPlayerView extends StatelessWidget {
  const YlPlayerView({
    required this.controller,
    this.placeholder,
    this.filterQuality = FilterQuality.low,
    super.key,
  });

  final YlPlayerController controller;
  final Widget? placeholder;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int?>(
    valueListenable: controller.textureId,
    builder: (context, textureId, child) {
      if (textureId == null) {
        return placeholder ?? const SizedBox.shrink();
      }
      return Texture(textureId: textureId, filterQuality: filterQuality);
    },
  );
}
