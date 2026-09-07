import 'value_helpers.dart';

/// Opaque identity for one playback session.
final class YlPlaybackSessionId {
  const YlPlaybackSessionId(this.value);

  final String value;

  @override
  int get hashCode => Object.hash(YlPlaybackSessionId, value);

  @override
  bool operator ==(Object other) =>
      ylValueEquals(this, other, (other) => value == other.value);

  @override
  String toString() => 'YlPlaybackSessionId(<redacted>)';
}

/// Enforces playback-session identity invariants at runtime boundaries.
void validateYlPlaybackSessionId(YlPlaybackSessionId sessionId) {
  if (sessionId.value.isEmpty) {
    throw ArgumentError('Playback session ID must not be empty.');
  }
}
