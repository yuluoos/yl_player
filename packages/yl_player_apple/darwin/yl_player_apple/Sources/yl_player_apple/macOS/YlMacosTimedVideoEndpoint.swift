#if os(macOS)
import AVFoundation
import AppKit

/// Layer hierarchy belongs to main. Renderer and timebase operations belong to
/// queue; no sample is bounced through the main run loop.
@available(macOS 14.0, *)
final class YlMacosTimedVideoEndpoint: YlTimedVideoEndpoint {
  private let layer: AVSampleBufferDisplayLayer
  private let renderer: AVSampleBufferVideoRenderer
  private let timebase: CMTimebase
  private let queue = DispatchQueue(label: "dev.ylplayer.native-video", qos: .userInitiated)
  private let stateLock = NSLock()
  private var closed = false
  private var generation: UInt64?
  private var requesting = false
  private var failed = false
  private var retirementStarted = false
  private var retirementFinished = false
  private var retirementCallbacks: [() -> Void] = []
  private let onFailure: (Error) -> Void

  init(container: CALayer, onFailure: @escaping (Error) -> Void) throws {
    precondition(Thread.isMainThread)
    var base: CMTimebase?
    let status = CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(), timebaseOut: &base)
    guard status == noErr, let base else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    self.timebase = base
    self.onFailure = onFailure
    layer = AVSampleBufferDisplayLayer()
    renderer = layer.sampleBufferRenderer
    CMTimebaseSetRate(base, rate: 0)
    layer.controlTimebase = base
    layer.videoGravity = .resize
    layer.frame = container.bounds
    layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    container.addSublayer(layer)
  }

  var isRetired: Bool { stateLock.withLock { closed } }

  func layout(in container: CALayer) {
    precondition(Thread.isMainThread)
    guard !isRetired else { return }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    layer.frame = container.bounds
    CATransaction.commit()
  }

  func update(_ snapshot: YlPresentationClockSnapshot, generation: UInt64) {
    queue.sync {
      guard !isRetired, !failed, self.generation == nil || self.generation == generation else { return }
      self.generation = generation
      guard snapshot.rate.isFinite, snapshot.rate >= 0.25, snapshot.rate <= 4 else {
        fail(NSError(domain: "YLTimedVideoClock", code: -1)); return
      }
      let status = CMTimebaseSetRateAndAnchorTime(timebase, rate: snapshot.playing ? snapshot.rate : 0,
        anchorTime: CMTime(value: snapshot.positionUs, timescale: 1_000_000),
        immediateSourceTime: CMTime(value: snapshot.hostTimeUs, timescale: 1_000_000))
      if status != noErr { fail(NSError(domain: NSOSStatusErrorDomain, code: Int(status))) }
      if renderer.status == .failed { fail(renderer.error ?? NSError(domain: "YLTimedVideoRenderer", code: -1)) }
    }
  }

  func enqueue(_ frame: YlFrameEnvelope) -> Bool {
    queue.sync {
      guard !isRetired, !failed, generation == frame.generation else { return false }
      guard renderer.status != .failed else {
        fail(renderer.error ?? NSError(domain: "YLTimedVideoRenderer", code: -1)); return false
      }
      guard renderer.isReadyForMoreMediaData else {
        if !requesting {
          requesting = true
          renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self, self.requesting else { return }
            self.renderer.stopRequestingMediaData()
            self.requesting = false
          }
        }
        return false
      }
      do {
        let pixel = unsafeBitCast(frame.payload, to: CVPixelBuffer.self)
        let timing = CMSampleTimingInfo(
          duration: frame.durationUs > 0 ? CMTime(value: frame.durationUs, timescale: 1_000_000) : .invalid,
          presentationTimeStamp: CMTime(value: frame.ptsUs, timescale: 1_000_000), decodeTimeStamp: .invalid)
        renderer.enqueue(try YlSampleBufferVideoRenderer.makeSample(pixel, retaining: frame.reservation, timing: timing))
        return true
      } catch { fail(error); return false }
    }
  }

  private func fail(_ error: Error) {
    guard !failed, !isRetired else { return }
    failed = true
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.isRetired else { return }
      self.onFailure(error)
    }
  }

  func retire(removingImage: Bool, completion: @escaping () -> Void) {
    stateLock.withLock { closed = true }
    if Thread.isMainThread { layer.removeFromSuperlayer() }
    else { DispatchQueue.main.async { [layer] in layer.removeFromSuperlayer() } }
    queue.async { [self] in
      if retirementFinished { completion(); return }
      retirementCallbacks.append(completion)
      guard !retirementStarted else { return }
      retirementStarted = true
      if requesting { renderer.stopRequestingMediaData(); requesting = false }
      CMTimebaseSetRate(timebase, rate: 0)
      renderer.flush(removingDisplayedImage: removingImage) { [self] in
        DispatchQueue.main.async { [self] in
          layer.removeFromSuperlayer()
          queue.async { [self] in
            retirementFinished = true
            let callbacks = retirementCallbacks; retirementCallbacks.removeAll()
            callbacks.forEach { $0() }
          }
        }
      }
    }
  }
}
#endif
