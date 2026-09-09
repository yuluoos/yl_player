import CoreMedia
import CoreVideo
import QuartzCore
import Foundation

protocol YlPresentationOutput: AnyObject {
  func acceptsPresentationFrame(generation: UInt64) -> Bool
  var presentationGeneration: UInt64 { get }
  func didAcceptPresentationFrame(generation: UInt64)
  func didPublishFirstPresentationFrame()
  func presentationDidTick(atHostTimeUs: Int64)
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
final class YlPresentationCoordinator {
  private let services: YlPlatformServices
  private let stateLock: NSLock
  private let openStartedAt: CFTimeInterval
  private let positionEventIntervalMs: Int64
  weak var output: (any YlPresentationOutput)?
  let frameScheduler = YlFrameScheduler()
  let postSeekGate = YlPostSeekGate()
  var mediaClock: YlMediaClock!
  var displayLink: (any YlDisplayDriving)?
  var currentPixelBuffer: CVPixelBuffer?
  var firstFrameSent = false
  var firstFrameDurationMs: Int64?
  var lastStateEmitAt = CFTimeInterval(0)

  var textureId: Int64 { services.textureOutput.textureId }
  init(services: YlPlatformServices, lock: NSLock, openedAt: CFTimeInterval,
       positionEventIntervalMs: Int64) {
    self.services = services
    self.stateLock = lock
    self.openStartedAt = openedAt
    self.positionEventIntervalMs = positionEventIntervalMs
  }

  func clearOutput() { services.textureOutput.clear() }

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
      payload: frame.pixelBuffer,
      ptsUs: frame.ptsUs == .min ? 0 : frame.ptsUs,
      durationUs: frame.durationUs,
      keyframe: frame.keyframe,
      generation: frame.generation
    ))
    guard accepted else { return }
    output.didAcceptPresentationFrame(generation: frame.generation)
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.firstFrameSent,
            let output = self.output, output.acceptsPresentationFrame(generation: frame.generation)
      else { return }
      self.present(frame.pixelBuffer)
      self.firstFrameSent = true
      self.firstFrameDurationMs = Int64(
        (CACurrentMediaTime() - self.openStartedAt) * 1_000
      )
      output.didPublishFirstPresentationFrame()
    }
  }

  private func displayLinkTick() {
    let now = Self.hostTimeUs()
    let position = mediaClock.position(atHostTimeUs: now)
    guard let output else { return }
    let currentGeneration = output.presentationGeneration
    if let frame = frameScheduler.frame(at: position, generation: currentGeneration) {
      let pixelBuffer = unsafeBitCast(frame.payload, to: CVPixelBuffer.self)
      present(pixelBuffer)
    }
    output.presentationDidTick(atHostTimeUs: now)
    let wallNow = CACurrentMediaTime()
    if wallNow - lastStateEmitAt >= Double(positionEventIntervalMs) / 1_000 {
      lastStateEmitAt = wallNow
      output.emitPresentationDelta()
    }
  }

  private func present(_ pixelBuffer: CVPixelBuffer) {
    stateLock.withLock { currentPixelBuffer = pixelBuffer }
    if textureId >= 0 { services.textureOutput.publish(pixelBuffer) }
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
