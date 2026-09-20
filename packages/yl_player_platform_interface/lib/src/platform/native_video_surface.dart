import 'package:flutter/foundation.dart';

/// An explicitly negotiated native presentation surface for one player.
///
/// The existing `YlPlatformPlayer.textureId` remains the output identity. A
/// view receives it as `{'textureId': int}` using StandardMessageCodec. Mounting
/// or unmounting a surface never transfers ownership of the underlying player.
@immutable
final class YlNativeVideoSurface {
  const YlNativeVideoSurface({required this.viewType, required this.platform});

  final String viewType;
  final TargetPlatform platform;
}

/// Optional rendering capability. Existing platform players need not implement
/// this interface and continue to render through their Flutter texture.
abstract interface class YlPlatformNativeVideoSurfaceProvider {
  YlNativeVideoSurface? get nativeVideoSurface;
}
