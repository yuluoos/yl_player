/// Discovery identity is scoped to a provider. Device names are untrusted text.
class YlCastDevice {
  const YlCastDevice({
    required this.id,
    required this.providerId,
    required this.name,
  });
  final String id;
  final String providerId;
  final String name;
}

/// Discovery activity and a redacted error code for one provider.
/// An empty device list alone does not imply that scanning succeeded.
class YlCastDiscoveryState {
  const YlCastDiscoveryState({this.scanning = false, this.failureCode});
  final bool scanning;
  final String? failureCode;
}

/// A receiver-readable URL, not an application HTTP request. Never put source
/// headers or credentials into device control requests.
class YlCastRequest {
  const YlCastRequest({
    required this.uri,
    required this.contentType,
    this.isLive = false,
    this.title = '',
    this.startPosition = Duration.zero,
    this.requiresHlsFmp4 = false,
  });
  final Uri uri;
  final String contentType;
  final bool isLive;
  final String title;
  final Duration startPosition;

  /// HLS MIME admission alone does not establish fMP4 segment support.
  final bool requiresHlsFmp4;
  @override
  String toString() => 'YlCastRequest(<redacted>, $contentType, live: $isLive)';
}

enum YlCastSupport { supported, unknown, unsupported }

class YlCastAssessment {
  const YlCastAssessment(this.support, {this.reason});
  final YlCastSupport support;
  final String? reason;
  bool get isSupported => support == YlCastSupport.supported;
}

class YlCastCapabilities {
  const YlCastCapabilities({
    this.pause = false,
    this.seek = false,
    this.volume = false,
    this.mute = false,
    this.canDetachKeepingPlayback = true,
  });
  final bool pause;
  final bool seek;
  final bool volume;
  final bool mute;
  final bool canDetachKeepingPlayback;
}

enum YlCastPlaybackStatus { idle, loading, playing, paused, stopped, failed }

class YlCastPlaybackState {
  const YlCastPlaybackState({
    this.status = YlCastPlaybackStatus.idle,
    this.position,
    this.duration,
    this.volume,
    this.muted,
    this.failureCode,
  });
  final YlCastPlaybackStatus status;
  final Duration? position;
  final Duration? duration;

  /// Normalized 0...1, null when not observed.
  final double? volume;
  final bool? muted;
  final String? failureCode;
}

/// Stable, redacted failure. URLs and SOAP bodies must not appear in messages.
class YlCastException implements Exception {
  const YlCastException(this.code);
  final String code;
  @override
  String toString() => 'YlCastException($code)';
}
