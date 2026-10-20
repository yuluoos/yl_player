import Foundation

/// Buffer/seek-window policy only. Its offset is not an end-to-end latency measurement.
enum YlLiveCatchUpAction: Equatable { case none, rate(Float), edge }
enum YlLiveCatchUpPolicy {
  /// The advertised end is exclusive and can have no decodable media yet.
  /// Automatic catch-up keeps the low-mode target buffer inside the window.
  static func catchUpPosition(startMs: Int64, endMs: Int64, targetMs: Int64) -> Int64? {
    guard startMs >= 0, endMs > startMs, targetMs > 0 else { return nil }
    return max(startMs, endMs - min(targetMs, endMs - startMs))
  }

  static func endAutomaticCatchUp(requestedRate: Float, playing: Bool,
    restoreRate: (Float) -> Void) -> Bool {
    if playing { restoreRate(requestedRate) }
    return false
  }
  static func action(lowLatency: Bool, playing: Bool, active: Bool,
    automaticEdgeAllowed: Bool, requestedRate: Float, offsetMs: Int64?,
    targetMs: Int64, hasSeekableWindow: Bool, maySeek: Bool) -> YlLiveCatchUpAction {
    guard lowLatency, playing, active, automaticEdgeAllowed, requestedRate == 1,
          hasSeekableWindow, let offsetMs, offsetMs >= 0 else { return .none }
    if offsetMs > targetMs + 3_000, maySeek { return .edge }
    return .rate(offsetMs > targetMs ? 1.03 : 1)
  }
}

/// A pause longer than the low-mode target can leave old data in TCP/demux
/// queues. Refresh once on resumed demand; smooth mode preserves that media.
enum YlLiveResumePolicy {
  /// AVPlayer can retain buffered bytes while its paused HLS seekable window
  /// expires. Restarting rate alone can immediately pause internally again.
  static func requiresHlsRefresh(lowLatency: Bool, live: Bool, pausedAt: TimeInterval?,
    now: TimeInterval, automaticEdgeAllowed: Bool, requestedRate: Float,
    positionMs: Int64?, startMs: Int64?, endMs: Int64?) -> Bool {
    guard automaticEdgeAllowed, requestedRate == 1,
      requiresRefresh(lowLatency: lowLatency, live: live, pausedAt: pausedAt, now: now) else { return false }
    guard let positionMs, let startMs, let endMs,
      startMs >= 0, endMs > startMs else { return true }
    return positionMs < startMs || positionMs >= endMs
  }

  static func requiresRefresh(lowLatency: Bool, live: Bool, pausedAt: TimeInterval?, now: TimeInterval) -> Bool {
    guard lowLatency, live, let pausedAt else { return false }
    return now - pausedAt >= 2
  }
}
