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

/// One committed protected presentation. None of these integers is a texture ID.
@immutable
final class YlProtectedVideoSurface {
  const YlProtectedVideoSurface({
    required this.playerId,
    required this.surfaceId,
    required this.sessionId,
    required this.generation,
    required this.viewType,
    required this.platform,
  });
  final int playerId;
  final int surfaceId;
  final String sessionId;
  final int generation;
  final String viewType;
  final TargetPlatform platform;
  @override
  bool operator ==(Object other) =>
      other is YlProtectedVideoSurface &&
      playerId == other.playerId &&
      surfaceId == other.surfaceId &&
      sessionId == other.sessionId &&
      generation == other.generation &&
      viewType == other.viewType &&
      platform == other.platform;
  @override
  int get hashCode => Object.hash(
    playerId,
    surfaceId,
    sessionId,
    generation,
    viewType,
    platform,
  );
}

abstract interface class YlPlatformProtectedVideoSurfaceProvider {
  YlProtectedVideoSurface? get protectedVideoSurface;
  Future<void> attachProtectedView(YlProtectedVideoSurface surface, int viewId);
  Future<void> detachProtectedView(YlProtectedVideoSurface surface, int viewId);
}
