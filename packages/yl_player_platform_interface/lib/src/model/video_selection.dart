import 'value_helpers.dart';

enum YlVideoSelectionReason { initial, user, trackUnavailable }

/// The authoritative video mode reported by a playback session.
final class YlVideoSelection {
  const YlVideoSelection({
    this.fixedTrackId,
    this.reason = YlVideoSelectionReason.initial,
  });

  final String? fixedTrackId;
  final YlVideoSelectionReason reason;

  bool get isAutomatic => fixedTrackId == null;

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) => fixedTrackId == other.fixedTrackId && reason == other.reason,
  );

  @override
  int get hashCode => Object.hash(fixedTrackId, reason);

  @override
  String toString() =>
      'YlVideoSelection(fixedTrackId: <redacted>, reason: $reason)';
}
