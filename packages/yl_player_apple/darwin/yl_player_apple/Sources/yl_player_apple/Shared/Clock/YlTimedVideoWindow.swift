import Foundation

/// A consistent observation of media position and its control state. This is
/// not a second media clock; the renderer timebase follows these observations.
struct YlPresentationClockSnapshot {
  let positionUs: Int64
  let hostTimeUs: Int64
  let rate: Double
  let playing: Bool

  var submissionHorizonUs: Int64? {
    guard playing, rate.isFinite, rate >= 0.25, rate <= 4 else { return nil }
    let lead = Int64((50_000 * rate).rounded(.down))
    let sum = positionUs.addingReportingOverflow(lead)
    return sum.overflow ? Int64.max : sum.partialValue
  }
}

/// Worker-confined references to samples submitted ahead of media time. Removing
/// a reference here does not release a reservation still owned by the renderer.
final class YlTimedVideoWindow {
  private var generation: UInt64?
  private var lastSubmittedPTS: Int64?
  private(set) var pendingFrames: [YlFrameEnvelope] = []

  func canSubmit(ptsUs: Int64, snapshot: YlPresentationClockSnapshot) -> Bool {
    guard generation != nil, pendingFrames.count < 3, ptsUs >= 0,
          let horizon = snapshot.submissionHorizonUs, ptsUs <= horizon else { return false }
    return lastSubmittedPTS.map { ptsUs > $0 } ?? true
  }

  func didSubmit(_ frame: YlFrameEnvelope) {
    guard frame.generation == generation, pendingFrames.count < 3,
          frame.ptsUs >= 0, lastSubmittedPTS.map({ frame.ptsUs > $0 }) ?? true else { return }
    lastSubmittedPTS = frame.ptsUs
    pendingFrames.append(frame)
  }

  func advance(to positionUs: Int64) {
    pendingFrames.removeAll { $0.ptsUs <= positionUs }
  }

  func reset(generation: UInt64) {
    self.generation = generation
    lastSubmittedPTS = nil
    pendingFrames.removeAll()
  }
}
