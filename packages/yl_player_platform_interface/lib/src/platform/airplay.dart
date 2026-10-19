import 'package:flutter/foundation.dart';

import '../model/identifiers.dart';
import '../model/source_assessment.dart';
import '../options/load_options.dart';
import '../source/media_source.dart';
import 'platform_load_result.dart';

/// Negotiated AirPlay capability and the current session's actual route state.
/// Enabling AirPlay never implies a device was selected or a frame presented.
@immutable
final class YlAirPlayState {
  const YlAirPlayState({
    this.supported = false,
    this.enabled = false,
    this.active = false,
    this.sessionId,
  });

  final bool supported;
  final bool enabled;
  final bool active;
  final YlPlaybackSessionId? sessionId;

  @override
  bool operator ==(Object other) =>
      other is YlAirPlayState &&
      supported == other.supported &&
      enabled == other.enabled &&
      active == other.active &&
      sessionId == other.sessionId;
  @override
  int get hashCode => Object.hash(supported, enabled, active, sessionId);
  @override
  String toString() =>
      'YlAirPlayState(supported: $supported, enabled: $enabled, '
      'active: $active, sessionId: $sessionId)';
}

/// System route picker bound to a single native player identity.
@immutable
final class YlAirPlayRoutePickerSurface {
  const YlAirPlayRoutePickerSurface({
    required this.platform,
    required this.channelSuffix,
    this.viewType = 'yl_player_apple/airplay',
  });
  final TargetPlatform platform;
  final String channelSuffix;
  final String viewType;
}

/// Optional AirPlay SPI. Admission must preserve an existing playable session
/// when unsupported; successful loads use the ordinary commit/state barrier.
abstract interface class YlAirPlayPlatformPlayer {
  ValueListenable<YlAirPlayState> get airPlayState;
  YlAirPlayRoutePickerSurface? get airPlayRoutePickerSurface;
  Future<YlSourceAssessment> assessForAirPlay(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  });
  Future<YlPlatformLoadResult> loadForAirPlay(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  });
}
