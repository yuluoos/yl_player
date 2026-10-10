import CoreMedia
import CoreVideo
import QuartzCore
import Foundation

protocol YlPresentationScheduling: AnyObject {
  var lateFrameDropCount: Int { get }
  var pendingPTS: [Int64] { get }
  var bufferedDurationUs: Int64 { get }
  func configureBounded(_ plan: YlBoundedBufferPlan?)
  func setRate(_ rate: Double)
  func enqueue(_ frame: YlFrameEnvelope) -> Bool
  func nextFrame(upTo positionUs: Int64, generation: UInt64) -> YlFrameEnvelope?
  func frame(at positionUs: Int64, generation: UInt64) -> YlFrameEnvelope?
  func flush(generation: UInt64)
  func dispose()
}
extension YlPresentationScheduling {
  var bufferedDurationUs: Int64 { 0 }
  func nextFrame(upTo positionUs: Int64, generation: UInt64) -> YlFrameEnvelope? { nil }
  func configureBounded(_ plan: YlBoundedBufferPlan?) {}
  func setRate(_ rate: Double) {}
}
extension YlFrameScheduler: YlPresentationScheduling {}

protocol YlPresentationOutput: AnyObject {
  func acceptsPresentationFrame(generation: UInt64) -> Bool
  var presentationGeneration: UInt64 { get }
  func didAcceptPresentationFrame(generation: UInt64)
  func didPublishFirstPresentationFrame()
  func presentationDidTick(atHostTimeUs: Int64)
  var allowsBoundedPresentation: Bool { get }
  func emitPresentationDelta()
}

final class YlPostSeekGate {
  private let lock = NSLock()
  private var minimumVideoPtsUs: Int64?
  private var minimumAudioPtsUs: Int64?

  func reset(targetUs: Int64?) {
    lock.withLock {
      minimumVideoPtsUs = targetUs
      minimumAudioPtsUs = targetUs
    }
  }

  func acceptsVideo(ptsUs: Int64) -> Bool {
    lock.withLock {
      guard let minimumVideoPtsUs else { return true }
      guard ptsUs >= minimumVideoPtsUs else { return false }
      self.minimumVideoPtsUs = nil
      return true
    }
  }

  var audioTargetUs: Int64? { lock.withLock { minimumAudioPtsUs } }

  func acceptsAudio(ptsUs: Int64) -> Bool {
    lock.withLock {
      guard let minimumAudioPtsUs else { return true }
      guard ptsUs >= minimumAudioPtsUs else { return false }
      self.minimumAudioPtsUs = nil
      return true
    }
  }
}

/// Owns scheduling, display pacing, clock and texture publication. The immutable
/// frame generation is checked against the session both before enqueue and publish.
final class YlPresentationCoordinator: YlAudioTimeline {
  private let services: YlPlatformServices
  private let stateLock: NSLock
  private let openStartedAt: CFTimeInterval
  private let positionEventIntervalMs: Int64
  weak var output: (any YlPresentationOutput)?
  private let frameScheduler: any YlPresentationScheduling
  private let postSeekGate = YlPostSeekGate()
  private var mediaClock: YlMediaClock!
  private var displayLink: (any YlDisplayDriving)?
  private var currentFrameReservation: YlManagedBufferLedger.Token?
  private var currentPixelBuffer: CVPixelBuffer?
  private var firstFrameSent = false
  private var firstFrameDurationMs: Int64?
  private var lastStateEmitAt = CFTimeInterval(0)
  private let timedLock = NSLock()
  private var timedCandidateEnabled = false
  private var timedRequiresAudioAnchor = false
  private var timedAudioReady = false
  private var timedGeneration: UInt64 = 0
  private var timedEpoch: UInt64 = 0
  private var timedSelected = false
  private var timedNoticeScheduled = false
  private var timedPump: YlTimedVideoPump?

  var timedVideoStatistics: YlTimedVideoStatistics? {
    timedLock.withLock { timedPump }?.statistics
  }
  var hasPendingTimedPresentation: Bool {
    timedLock.withLock { timedPump }?.hasPendingPresentation ?? false
  }
  private var usesTimedPresentation: Bool { timedLock.withLock { timedSelected } }
  func configureTimedCandidate(enabled: Bool, requiresAudioAnchor: Bool) {
    timedLock.withLock {
      timedCandidateEnabled = enabled
      timedRequiresAudioAnchor = requiresAudioAnchor
      timedAudioReady = !requiresAudioAnchor
    }
  }
  private func markTimedAudioReady() {
    timedLock.withLock { timedAudioReady = true }
  }
  private func synchronizeTimedPresentation() {
    timedLock.withLock { timedPump }?.synchronize()
  }
  private func stopTimedPresentation(clearOutput: Bool = true) {
    let old = timedLock.withLock { () -> YlTimedVideoPump? in
      let old = timedPump; timedPump = nil; timedEpoch &+= 1; timedNoticeScheduled = false
      return old
    }
    guard let old else { return }
    old.stop {}
    if clearOutput { services.textureOutput.clear() }
  }
  private func ensureTimedPresentation() {
    let state = timedLock.withLock { (timedCandidateEnabled, timedAudioReady, timedGeneration, timedPump) }
    guard state.0, state.1, let output, output.acceptsPresentationFrame(generation: state.2) else { return }
    if let pump = state.3, !pump.isStopped { return }
    guard mediaClock.presentationSnapshot(atHostTimeUs: Self.hostTimeUs()).playing else { return }
    if state.3 != nil { stopTimedPresentation() }
    guard let endpoint = (services.textureOutput as? YlTimedVideoOutput)?.makeTimedVideoEndpoint(),
          !endpoint.isRetired else { return }
    let epoch = timedLock.withLock { () -> UInt64 in timedEpoch &+= 1; return timedEpoch }
    let generation = state.2 // Do not capture the tuple's retired pump in the new callback.
    let pump = YlTimedVideoPump(scheduler: frameScheduler, endpoint: endpoint,
      clockSnapshot: { [mediaClock] in mediaClock!.presentationSnapshot(atHostTimeUs: Self.hostTimeUs()) },
      generation: generation, onSubmitted: { [weak self] in self?.timedFrameSubmitted(generation: generation, epoch: epoch) })
    timedLock.withLock { timedPump = pump; timedSelected = true }
    pump.synchronize()
  }
  private func timedFrameSubmitted(generation: UInt64, epoch: UInt64) {
    let schedule = timedLock.withLock { () -> Bool in
      guard timedEpoch == epoch, !timedNoticeScheduled else { return false }
      timedNoticeScheduled = true; return true
    }
    guard schedule else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.timedLock.withLock({ self.timedEpoch == epoch }), !self.firstFrameSent,
            let output = self.output, output.acceptsPresentationFrame(generation: generation) else { return }
      self.firstFrameSent = true
      self.firstFrameDurationMs = Int64((CACurrentMediaTime() - self.openStartedAt) * 1_000)
      output.didPublishFirstPresentationFrame()
    }
  }

  var textureId: Int64 { services.textureOutput.textureId }
  init(services: YlPlatformServices, lock: NSLock, openedAt: CFTimeInterval,
       positionEventIntervalMs: Int64, scheduler: any YlPresentationScheduling = YlFrameScheduler()) {
    self.frameScheduler = scheduler
    self.services = services
    self.stateLock = lock
    self.openStartedAt = openedAt
    self.positionEventIntervalMs = positionEventIntervalMs
  }

  var hasDisplay: Bool { displayLink != nil }
  var firstFrameDuration: Int64? { firstFrameDurationMs }
  var lateFrameDropCount: Int { frameScheduler.lateFrameDropCount }
  var bufferedDurationUs: Int64 { frameScheduler.bufferedDurationUs }
  func configureBounded(_ plan: YlBoundedBufferPlan?) { frameScheduler.configureBounded(plan) }
  var pendingFrames: [Int64] { frameScheduler.pendingPTS }
  func configureClock(_ provided: YlMediaClock?, audioTime: @escaping () -> YlRenderedAudioTime?) {
    mediaClock = provided ?? YlMediaClock(audioTime: audioTime)
  }
  func anchorAudio(ptsUs: Int64, sampleTime: Int64) {
    mediaClock.anchorAudio(ptsUs: ptsUs, sampleTime: sampleTime); markTimedAudioReady()
  }
  func anchorSubmittedAudio(ptsUs: Int64, sampleTime: Int64) {
    mediaClock.anchorSubmittedAudio(ptsUs: ptsUs, sampleTime: sampleTime)
    markTimedAudioReady()
  }
  func position(atHostTimeUs time: Int64) -> Int64 { mediaClock.position(atHostTimeUs: time) }
  func play(atHostTimeUs time: Int64) { mediaClock.play(atHostTimeUs: time); synchronizeTimedPresentation() }
  func pause(atHostTimeUs time: Int64) { mediaClock.pause(atHostTimeUs: time); synchronizeTimedPresentation() }
  func seek(to time: Int64) { mediaClock.seek(to: time) }
  func setRate(_ rate: Double, atHostTimeUs time: Int64) {
    frameScheduler.setRate(rate)
    mediaClock.setRate(rate, atHostTimeUs: time)
    synchronizeTimedPresentation()
  }
  func suppressFramesBefore(_ time: Int64?) { postSeekGate.reset(targetUs: time) }
  var audioTargetUs: Int64? { postSeekGate.audioTargetUs }
  func acceptsAudio(ptsUs: Int64) -> Bool { postSeekGate.acceptsAudio(ptsUs: ptsUs) }
  func flushFrames(generation: UInt64) {
    stopTimedPresentation()
    timedLock.withLock { timedGeneration = generation; timedAudioReady = !timedRequiresAudioAnchor }
    frameScheduler.flush(generation: generation)
  }
  func disposeFrames() { stopTimedPresentation(); frameScheduler.dispose() }
  func clearFrame() { currentPixelBuffer = nil }
  func clearFrameAndTexture() { currentPixelBuffer = nil; clearOutput(); currentFrameReservation = nil }
  func setDisplayPaused(_ paused: Bool) { displayLink?.isPaused = paused }
  func retireDisplay() { displayLink?.invalidate(); displayLink = nil; stopTimedPresentation() }
  func resetMilestones() { firstFrameDurationMs = nil; firstFrameSent = false }

  func clearOutput() { stopTimedPresentation(clearOutput: false); services.textureOutput.clear(); currentFrameReservation = nil }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    stateLock.lock()
    let buffer = currentPixelBuffer
    stateLock.unlock()
    return buffer.map(Unmanaged.passRetained)
  }

  func receive(_ frame: YlVideoFrame) {
    guard let output, output.acceptsPresentationFrame(generation: frame.generation),
          postSeekGate.acceptsVideo(ptsUs: frame.ptsUs) else { return }
    let accepted = frameScheduler.enqueue(YlFrameEnvelope(
      reservation: frame.reservation,
      payload: frame.pixelBuffer,
      ptsUs: frame.ptsUs == .min ? 0 : frame.ptsUs,
      durationUs: frame.durationUs,
      keyframe: frame.keyframe,
      generation: frame.generation
    ))
    guard accepted else { return }
    output.didAcceptPresentationFrame(generation: frame.generation)
    synchronizeTimedPresentation()
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.firstFrameSent, !self.usesTimedPresentation,
            let output = self.output, output.acceptsPresentationFrame(generation: frame.generation)
      else { return }
      self.present(frame.pixelBuffer, reservation: frame.reservation)
      self.firstFrameSent = true
      self.firstFrameDurationMs = Int64(
        (CACurrentMediaTime() - self.openStartedAt) * 1_000
      )
      output.didPublishFirstPresentationFrame()
    }
  }

  private func displayLinkTick() {
    ensureTimedPresentation()
    let now = Self.hostTimeUs()
    let position = mediaClock.position(atHostTimeUs: now)
    guard let output else { return }
    let currentGeneration = output.presentationGeneration
    if !usesTimedPresentation, output.allowsBoundedPresentation, let frame = frameScheduler.frame(at: position, generation: currentGeneration) {
      frame.reservation?.endQueuedTiming()
      let pixelBuffer = unsafeBitCast(frame.payload, to: CVPixelBuffer.self)
      present(pixelBuffer, reservation: frame.reservation)
    }
    output.presentationDidTick(atHostTimeUs: now)
    let wallNow = CACurrentMediaTime()
    if wallNow - lastStateEmitAt >= Double(positionEventIntervalMs) / 1_000 {
      lastStateEmitAt = wallNow
      output.emitPresentationDelta()
    }
  }

  private func present(_ pixelBuffer: CVPixelBuffer, reservation: YlManagedBufferLedger.Token?) {
    let old = stateLock.withLock { () -> YlManagedBufferLedger.Token? in
      let old = currentFrameReservation; currentPixelBuffer = pixelBuffer; currentFrameReservation = reservation; return old
    }
    if textureId >= 0 {
      ylPublishVideoFrame(pixelBuffer, retaining: reservation, to: services.textureOutput)
    }
    withExtendedLifetime(old) {}
  }

  func installDisplayLink(paused: Bool) {
    guard displayLink == nil else {
      displayLink?.isPaused = paused
      return
    }
    let link = services.makeDisplayDriver { [weak self] in self?.displayLinkTick() }
    link.isPaused = paused
    displayLink = link
  }

  static func hostTimeUs() -> Int64 {
    Int64(CACurrentMediaTime() * 1_000_000)
  }

}
