# yl_player_platform_interface

Shared contracts and immutable value types for the federated `yl_player`
plugin. Application code should normally import `package:yl_player/yl_player.dart`
instead of depending on this package directly.

This development release defines configuration, source, track, capability,
metrics, state, event, error, platform, and per-player backend contracts. It
does not contain a decoder or renderer.

Platform implementations extend `YlPlayerPlatform`, register an instance, and
return one `YlPlatformPlayer` for each requested controller. Implementations
must keep encoded packets, decoded frames, and PCM data on the native side.

Minimum target versions for endorsed implementations are Android API 24 and
iOS 15. Subtitles and DRM are not part of the current contract.
