import '../model/identifiers.dart';

/// A committed session whose matching authoritative full state is already
/// accepted by the adapter. The load barrier requires both native commit success
/// and that state, in either arrival order, but never Ready or First Frame.
/// Invalidated candidates fail instead of returning stale handles. Implementors
/// bound transport waits and clean up failed loads; state remains authoritative.
final class YlPlatformLoadResult {
  const YlPlatformLoadResult({required this.sessionId});
  final YlPlaybackSessionId sessionId;
  @override
  bool operator ==(Object other) =>
      other is YlPlatformLoadResult && sessionId == other.sessionId;
  @override
  int get hashCode => Object.hash(YlPlatformLoadResult, sessionId);
  @override
  String toString() => 'YlPlatformLoadResult(sessionId: $sessionId)';
}
