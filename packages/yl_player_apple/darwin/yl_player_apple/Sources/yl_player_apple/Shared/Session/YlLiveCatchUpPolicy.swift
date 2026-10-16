import Foundation

/// Buffer/seek-window policy only. Its offset is not an end-to-end latency measurement.
enum YlLiveCatchUpAction: Equatable { case none, rate(Float), edge }
enum YlLiveCatchUpPolicy {
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
