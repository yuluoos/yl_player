import Foundation

struct YlAppleReducedState {
  let identity: YlAppleSessionIdentity?
  let revision: Int64
  let sequence: Int64
  let snapshot: YlNativeState?
  let failure: NativePlayerError?
}
struct YlAppleEventMetadata {
  let identity: YlAppleSessionIdentity
  let revision: Int64
  let sequence: Int64
  let occurredAtMs: Int64
}
enum YlAppleReducerOutput {
  case state(YlAppleReducedState)
  case delta(YlAppleEventMetadata, previousRevision: Int64, YlNativeTimelineDelta)
  case firstFrame(YlAppleEventMetadata)
  case retry(YlAppleEventMetadata, attempt: Int, delayMs: Int64, NativePlayerError)
  case engineChanged(YlAppleEventMetadata, previous: YlNativeEngine?, current: YlNativeEngine)
  case failed(YlAppleEventMetadata, NativePlayerError)
}

/// One player-local revision/sequence authority. Every output uses the same clock.
final class YlAppleStateReducer {
  private let playerId: Int64
  private let clock: () -> Int64
  private var sessionSequence: Int64 = 0
  private(set) var revision: Int64 = 0
  private(set) var sequence: Int64 = 0
  private(set) var identity: YlAppleSessionIdentity?
  private var snapshot: YlNativeState?
  private var failure: NativePlayerError?
  private var readyAt: Int64?
  private var firstFrameAt: Int64?
  private var publicFrameObserved = false
  private var firstFrameSent = false
  private var failed = false
  var onOutput: ((YlAppleReducerOutput) -> Void)?
  var onExhausted: (() -> Void)?

  init(playerId: Int64, clock: @escaping () -> Int64) {
    self.playerId = playerId
    self.clock = clock
  }
  var state: YlAppleReducedState {
    YlAppleReducedState(identity: identity, revision: revision, sequence: sequence,
      snapshot: snapshot, failure: failure)
  }
  func makeIdentity(loadRequestId: String) -> YlAppleSessionIdentity {
    sessionSequence += 1
    return YlAppleSessionIdentity(sessionId: "apple-\(playerId)-s\(sessionSequence)",
      loadRequestId: loadRequestId, startedAtMs: clock())
  }
  func commit(_ identity: YlAppleSessionIdentity) {
    self.identity = identity
    snapshot = nil
    failure = nil
    readyAt = nil
    firstFrameAt = nil
    publicFrameObserved = false
    firstFrameSent = false
    failed = false
    publishState()
  }
  func stop() {
    identity = nil
    snapshot = nil
    failure = nil
    failed = false
    publishState()
  }
  func accept(_ callback: YlNativeBackendCallback, identity: YlAppleSessionIdentity) {
    guard self.identity == identity, !failed else { return }
    switch callback.event {
    case .state(var value):
      let previousEngine = snapshot?.engine
      if readyAt == nil, value.status == "ready" || value.metrics.openDurationMs != nil {
        // Backend duration establishes READY, but excludes private preparation.
        // The Load identity clock measures the entire public operation.
        readyAt = max(0, clock() - identity.startedAtMs)
        var ready = value
        ready.status = "ready"
        ready.metrics.openDurationMs = readyAt
        ready.metrics.firstFrameDurationMs = firstFrameAt
        snapshot = ready
        publishState()
      }
      if readyAt == nil, value.status == "buffering" || value.status == "playing" {
        value.status = "loading"
      }
      value.metrics.openDurationMs = readyAt
      value.metrics.firstFrameDurationMs = firstFrameAt
      snapshot = value
      if let error = value.error { fail(error); return }
      publishState()
      if previousEngine != value.engine, let metadata = eventMetadata() {
        onOutput?(.engineChanged(metadata, previous: previousEngine, current: value.engine))
      }
      flushFirstFrame()
    case .delta(var value):
      value.metrics.openDurationMs = readyAt
      value.metrics.firstFrameDurationMs = firstFrameAt
      snapshot?.positionMs = value.positionMs
      snapshot?.bufferedPositionMs = value.bufferedPositionMs
      snapshot?.isAtLiveEdge = value.isAtLiveEdge
      snapshot?.liveOffsetMs = value.liveOffsetMs
      snapshot?.metrics = value.metrics
      let previous = revision
      guard advanceRevision(), let metadata = eventMetadata() else { return }
      onOutput?(.delta(metadata, previousRevision: previous, value))
    case .failure(let error): fail(error)
    case let .retry(attempt, delayMs, error):
      if let metadata = eventMetadata() {
        onOutput?(.retry(metadata, attempt: attempt, delayMs: delayMs, error))
      }
    case .firstFrame, .tracksChanged, .engineActivated:
      // Engine markers alone cannot establish public frame publication. Tracks
      // and engine changes are projected by the authoritative following state.
      break
    }
  }
  func publicFrame(identity: YlAppleSessionIdentity) {
    guard self.identity == identity, !failed, !firstFrameSent else { return }
    publicFrameObserved = true
    if firstFrameAt == nil { firstFrameAt = max(0, clock() - identity.startedAtMs) }
    flushFirstFrame()
  }
  func fail(_ error: NativePlayerError) {
    guard !failed else { return }
    failed = true
    failure = error
    publishState()
    if let metadata = eventMetadata() { onOutput?(.failed(metadata, error)) }
  }
  func projectPaused() {
    guard var value = snapshot, !failed else { return }
    value.status = "paused"
    snapshot = value
    publishState()
  }
  private func flushFirstFrame() {
    guard publicFrameObserved, readyAt != nil, !firstFrameSent, !failed else { return }
    firstFrameSent = true
    snapshot?.metrics.firstFrameDurationMs = firstFrameAt
    publishState()
    if let metadata = eventMetadata() { onOutput?(.firstFrame(metadata)) }
  }
  private func advanceRevision() -> Bool {
    guard revision < Int64.max else { onExhausted?(); return false }
    revision += 1
    return true
  }
  private func nextSequence() -> Bool {
    guard sequence < Int64.max else { onExhausted?(); return false }
    sequence += 1
    return true
  }
  private func publishState() {
    guard advanceRevision(), nextSequence() else { return }
    onOutput?(.state(state))
  }
  private func eventMetadata() -> YlAppleEventMetadata? {
    guard let identity, nextSequence() else { return nil }
    return YlAppleEventMetadata(identity: identity, revision: revision,
      sequence: sequence, occurredAtMs: clock())
  }
}
