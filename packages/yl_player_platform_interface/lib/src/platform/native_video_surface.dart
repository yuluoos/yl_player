import 'package:flutter/foundation.dart';

/// An explicitly negotiated native presentation surface for one player.
///
/// The existing `YlPlatformPlayer.textureId` remains the output identity. A
/// view receives it as `{'textureId': int}` using StandardMessageCodec. Mounting
/// or unmounting a surface never transfers ownership of the underlying player.
@immutable
final class YlNativeVideoSurface {
  const YlNativeVideoSurface({required this.viewType, required this.platform});

  /// Registered platform-view factory name.
  final String viewType;

  /// Host platform on which this factory may be mounted.
  final TargetPlatform platform;
}

/// Optional rendering capability. Existing platform players need not implement
/// this interface and continue to render through their Flutter texture.
abstract interface class YlPlatformNativeVideoSurfaceProvider {
  /// Negotiated native output, or null to use the ordinary Flutter texture.
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
    this.supportsSubtitleOverlay = false,
    required this.viewType,
    required this.platform,
  });

  /// Native player owner. This is never a Flutter texture identity.
  final int playerId;

  /// Native protected presentation identity within the player.
  final int surfaceId;

  /// Playback session whose frame acknowledgments authorize presentation.
  final String sessionId;

  /// Monotonic native generation rejecting replaced or detached surfaces.
  final int generation;

  /// Registered platform-view factory name.
  final String viewType;

  /// Host platform on which this factory may be mounted.
  final TargetPlatform platform;

  /// Whether this native view supports a separate Flutter subtitle sibling.
  ///
  /// Defaults false for legacy/unknown adapters. Opt in only for surfaces that
  /// preserve protected native output below Flutter overlays, without reading
  /// video pixels or transforming it into a texture. Requires contain/center
  /// layout, current geometry and first-frame authorization. This capability
  /// does not authorize decryption or discovery of protected embedded subtitles.
  final bool supportsSubtitleOverlay;

  @override
  bool operator ==(Object other) =>
      other is YlProtectedVideoSurface &&
      playerId == other.playerId &&
      surfaceId == other.surfaceId &&
      sessionId == other.sessionId &&
      generation == other.generation &&
      viewType == other.viewType &&
      platform == other.platform &&
      supportsSubtitleOverlay == other.supportsSubtitleOverlay;
  @override
  int get hashCode => Object.hash(
    playerId,
    surfaceId,
    sessionId,
    generation,
    supportsSubtitleOverlay,
    viewType,
    platform,
  );
}

/// Optional native protected view ownership; attaching does not transfer the
/// player or authorize a frame until the matching native acknowledgment.
abstract interface class YlPlatformProtectedVideoSurfaceProvider {
  /// The committed surface, or null when no protected presentation is active.
  YlProtectedVideoSurface? get protectedVideoSurface;

  /// Claims the exact committed surface for a native platform-view identity.
  Future<void> attachProtectedView(YlProtectedVideoSurface surface, int viewId);

  /// Releases only the matching view claim; stale detach must be harmless.
  Future<void> detachProtectedView(YlProtectedVideoSurface surface, int viewId);
}
