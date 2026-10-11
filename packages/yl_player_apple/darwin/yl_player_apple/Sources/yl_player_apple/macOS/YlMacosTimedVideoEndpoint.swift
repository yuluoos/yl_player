#if os(macOS)
import AVFoundation
import AppKit
import Darwin

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
  private var clockSnapshot: YlPresentationClockSnapshot?
  private var timebaseAnchor: YlPresentationClockSnapshot?
  // Share the same reservations: one current image plus at most three future
  // images permits paused surface reattachment without a stale preview.
  private var previewFrames: [YlFrameEnvelope] = []
  private var requesting = false
  private var readyHandler: (() -> Void)?
  // Bounded scalar evidence only; diagnostics never retain a rejected frame.
  private var blockedPTS: Int64?, blockedSince: TimeInterval?, readyAt: TimeInterval?
  private var blockedAttempts = 0
  private var readyAtCallback: Bool?
  private var readinessTrace: YlTimedVideoReadinessTrace?
  private var backpressureEvents: [[String: Double]] = []
  private var failed = false
  private var retirementStarted = false
  private var retirementFinished = false
  private var retirementCallbacks: [() -> Void] = []
  private let onFailure: (Error) -> Void
  private let collectDiagnostics: Bool
  private var diagnosticUpdates = 0, diagnosticEnqueues = 0, lateEnqueues = 0
  private var diagnosticAnchors = 0
  let lifetimeDiagnostics: YlTimedVideoLifetimeDiagnostics?
  private var maximumForwardCorrectionUs = 0.0, maximumBackwardCorrectionUs = 0.0
  private var minimumLeadUs: Double?, maximumLeadUs: Double?
  private var diagnosticEvents: [[String: Double]] = []
  var diagnostics: [String: Any]? {
    queue.sync {
      guard collectDiagnostics else { return nil }
      return ["backpressureEvents": backpressureEvents, "readyChecks": readinessTrace?.values as Any? ?? NSNull(), "blockedPTS": blockedPTS as Any? ?? NSNull(), "blockedSince": blockedSince as Any? ?? NSNull(), "blockedAttempts": blockedAttempts, "anchors": diagnosticAnchors, "lifetime": lifetimeDiagnostics?.snapshot as Any? ?? NSNull(), "updates": diagnosticUpdates, "enqueues": diagnosticEnqueues, "lateEnqueues": lateEnqueues,
        "maximumForwardCorrectionUs": maximumForwardCorrectionUs, "maximumBackwardCorrectionUs": maximumBackwardCorrectionUs,
        "minimumLeadUs": minimumLeadUs as Any? ?? NSNull(), "maximumLeadUs": maximumLeadUs as Any? ?? NSNull(), "events": diagnosticEvents]
    }
  }

  init(container: CALayer, collectDiagnostics: Bool = false, onFailure: @escaping (Error) -> Void) throws {
    precondition(Thread.isMainThread)
    var base: CMTimebase?
    let status = CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(), timebaseOut: &base)
    guard status == noErr, let base else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    self.timebase = base
    self.onFailure = onFailure
    self.collectDiagnostics = collectDiagnostics
    self.lifetimeDiagnostics = collectDiagnostics ? YlTimedVideoLifetimeDiagnostics() : nil
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
      if collectDiagnostics {
        diagnosticUpdates += 1
        if clockSnapshot != nil {
          let host = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) * 1_000_000
          let current = CMTimeGetSeconds(CMTimebaseGetTime(timebase)) * 1_000_000
          let target = Double(snapshot.positionUs) + (snapshot.playing ? max(0, host - Double(snapshot.hostTimeUs)) * snapshot.rate : 0)
          let correction = target - current
          maximumForwardCorrectionUs = max(maximumForwardCorrectionUs, correction)
          maximumBackwardCorrectionUs = max(maximumBackwardCorrectionUs, -correction)
          if abs(correction) > 5_000 {
            diagnosticEvents.append(["uptime": ProcessInfo.processInfo.systemUptime, "correctionUs": correction])
            if diagnosticEvents.count > 32 { diagnosticEvents.removeFirst() }
          }
        }
      }
      self.generation = generation
      clockSnapshot = snapshot
      prunePreviewFrames()
      guard snapshot.rate.isFinite, snapshot.rate >= 0.25, snapshot.rate <= 4 else {
        fail(NSError(domain: "YLTimedVideoClock", code: -1)); return
      }
      // SetRateAndAnchorTime always emits TimeJumped, even for equivalent
      // observations. Preserve the native timeline through sub-ms source jitter.
      // Compare with the last APPLIED anchor so small drift cannot accumulate.
      let continuous = timebaseAnchor.map { anchor in
        let expected = Double(anchor.positionUs) + (anchor.playing
          ? (Double(snapshot.hostTimeUs) - Double(anchor.hostTimeUs)) * anchor.rate : 0)
        return anchor.playing == snapshot.playing && anchor.rate == snapshot.rate
          && snapshot.playing && abs(Double(snapshot.positionUs) - expected) <= 1_000 * snapshot.rate
      } ?? false
      if !continuous {
        let status = CMTimebaseSetRateAndAnchorTime(timebase, rate: snapshot.playing ? snapshot.rate : 0,
          anchorTime: CMTime(value: snapshot.positionUs, timescale: 1_000_000),
          immediateSourceTime: CMTime(value: snapshot.hostTimeUs, timescale: 1_000_000))
        if status != noErr { fail(NSError(domain: NSOSStatusErrorDomain, code: Int(status))); return }
        timebaseAnchor = snapshot
        if collectDiagnostics { diagnosticAnchors += 1 }
      }
      if renderer.status == .failed { fail(renderer.error ?? NSError(domain: "YLTimedVideoRenderer", code: -1)) }
    }
  }

  func setReadyHandler(_ handler: @escaping () -> Void) {
    queue.sync {
      guard !isRetired, !failed else { return }
      readyHandler = handler
    }
  }

  func enqueue(_ frame: YlFrameEnvelope) -> Bool {
    let requested = collectDiagnostics ? ProcessInfo.processInfo.systemUptime : 0
    return queue.sync {
      let entered = collectDiagnostics ? ProcessInfo.processInfo.systemUptime : 0
      guard !isRetired, !failed, generation == frame.generation else { return false }
      guard renderer.status != .failed else {
        fail(renderer.error ?? NSError(domain: "YLTimedVideoRenderer", code: -1)); return false
      }
      let checkBegan = collectDiagnostics ? ProcessInfo.processInfo.systemUptime : 0
      let ready = renderer.isReadyForMoreMediaData
      let checkReturned = collectDiagnostics ? ProcessInfo.processInfo.systemUptime : 0
      if collectDiagnostics, !ready || (blockedSince != nil && blockedPTS == frame.ptsUs) {
        if !ready, blockedSince == nil || blockedPTS != frame.ptsUs {
          readinessTrace = YlTimedVideoReadinessTrace()
        }
        readinessTrace?.recordCheck(requested: requested, entered: entered,
          began: checkBegan, returned: checkReturned, ready: ready, threadID: diagnosticThreadID())
      }
      guard ready else {
        if collectDiagnostics {
          if blockedSince == nil || blockedPTS != frame.ptsUs {
            blockedPTS = frame.ptsUs; blockedSince = checkReturned
            blockedAttempts = 0; readyAt = nil; readyAtCallback = nil
          }
          blockedAttempts += 1
        }
        if !requesting {
          requesting = true
          let registrationBegan = collectDiagnostics ? ProcessInfo.processInfo.systemUptime : 0
          renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self, self.requesting, !self.isRetired, !self.failed else { return }
            let callbackEntered = self.collectDiagnostics ? ProcessInfo.processInfo.systemUptime : 0
            self.renderer.stopRequestingMediaData()
            let stopReturned = self.collectDiagnostics ? ProcessInfo.processInfo.systemUptime : 0
            self.requesting = false
            if self.collectDiagnostics, self.blockedSince != nil {
              // Callback execution is not the exact instant native ready flipped.
              self.readyAt = ProcessInfo.processInfo.systemUptime
              self.readyAtCallback = self.renderer.isReadyForMoreMediaData
              self.readinessTrace?.recordCallback(entered: callbackEntered, stopReturned: stopReturned,
                readyReturned: ProcessInfo.processInfo.systemUptime, ready: self.readyAtCallback == true,
                threadID: self.diagnosticThreadID())
            }
            self.readyHandler?()
          }
          if collectDiagnostics {
            readinessTrace?.recordRegistration(began: registrationBegan,
              returned: ProcessInfo.processInfo.systemUptime, threadID: diagnosticThreadID())
          }
        }
        return false
      }
      do {
        let pixel = unsafeBitCast(frame.payload, to: CVPixelBuffer.self)
        let timing = CMSampleTimingInfo(
          duration: frame.durationUs > 0 ? CMTime(value: frame.durationUs, timescale: 1_000_000) : .invalid,
          presentationTimeStamp: CMTime(value: frame.ptsUs, timescale: 1_000_000), decodeTimeStamp: .invalid)
        let sample = try YlSampleBufferVideoRenderer.makeSample(pixel, retaining: frame.reservation, timing: timing)
        var backpressureEvent: [String: Double]?
        if collectDiagnostics {
          let lead = Double(frame.ptsUs) - CMTimeGetSeconds(CMTimebaseGetTime(timebase)) * 1_000_000
          diagnosticEnqueues += 1
          minimumLeadUs = min(minimumLeadUs ?? lead, lead); maximumLeadUs = max(maximumLeadUs ?? lead, lead)
          if lead < 0 { lateEnqueues += 1 }
          if let blockedSince, let blockedPTS {
            var event: [String: Double] = ["ptsUs": Double(blockedPTS),
              "firstRejectedUptime": blockedSince, "attempts": Double(blockedAttempts)]
            if let readinessTrace { event.merge(readinessTrace.values) { _, new in new } }
            if blockedPTS == frame.ptsUs {
              event["enqueueBeganUptime"] = ProcessInfo.processInfo.systemUptime
              event["leadAtEnqueueUs"] = lead
              if let readyAt { event["lastReadyCallbackUptime"] = readyAt }
              if let readyAtCallback { event["readyAtCallback"] = readyAtCallback ? 1 : 0 }
              backpressureEvent = event
            } else {
              event["replacedByPTSUs"] = Double(frame.ptsUs)
              event["endedUptime"] = ProcessInfo.processInfo.systemUptime
              appendBackpressureEvent(event)
            }
            self.blockedSince = nil; self.blockedPTS = nil; self.readyAt = nil
            readinessTrace = nil
            readyAtCallback = nil; blockedAttempts = 0
          }
        }
        lifetimeDiagnostics?.track(sample: sample, frame: frame)
        renderer.enqueue(sample)
        if var event = backpressureEvent {
          event["enqueueReturnedUptime"] = ProcessInfo.processInfo.systemUptime
          appendBackpressureEvent(event)
        }
        previewFrames.append(frame); prunePreviewFrames()
        return true
      } catch { fail(error); return false }
    }
  }

  private func appendBackpressureEvent(_ event: [String: Double]) {
    backpressureEvents.append(event)
    if backpressureEvents.count > 16 { backpressureEvents.removeFirst() }
  }

  private func diagnosticThreadID() -> UInt64 {
    var identifier: UInt64 = 0
    pthread_threadid_np(nil, &identifier)
    return identifier
  }

  var pausedPreview: YlFrameEnvelope? {
    queue.sync {
      guard !isRetired, let snapshot = clockSnapshot, !snapshot.playing else { return nil }
      return previewFrames.last { $0.ptsUs <= snapshot.positionUs }
    }
  }

  private func prunePreviewFrames() {
    guard let snapshot = clockSnapshot else { return }
    let current = previewFrames.last { $0.ptsUs <= snapshot.positionUs }
    let future = previewFrames.filter { $0.ptsUs > snapshot.positionUs }.suffix(3)
    previewFrames = current.map { [$0] } ?? []
    previewFrames.append(contentsOf: future)
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
    lifetimeDiagnostics?.record("retire.requested")
    if Thread.isMainThread { layer.removeFromSuperlayer() }
    else { DispatchQueue.main.async { [layer] in layer.removeFromSuperlayer() } }
    queue.async { [self] in
      if retirementFinished { completion(); return }
      retirementCallbacks.append(completion)
      guard !retirementStarted else { return }
      retirementStarted = true
      readyHandler = nil
      lifetimeDiagnostics?.record("flush.begin")
      if requesting { renderer.stopRequestingMediaData(); requesting = false }
      CMTimebaseSetRate(timebase, rate: 0)
      renderer.flush(removingDisplayedImage: removingImage) { [self] in
        lifetimeDiagnostics?.record("flush.completed")
        DispatchQueue.main.async { [self] in
          layer.removeFromSuperlayer()
          lifetimeDiagnostics?.record("layer.removed")
          queue.async { [self] in
            previewFrames.removeAll(); clockSnapshot = nil; timebaseAnchor = nil
            lifetimeDiagnostics?.record("preview.cleared")
            retirementFinished = true
            let callbacks = retirementCallbacks; retirementCallbacks.removeAll()
            callbacks.forEach { $0() }
          }
        }
      }
    }
  }
}
/// Diagnostic metadata only: weak references cannot prolong a sample or receipt.
@available(macOS 14.0, *)
final class YlTimedVideoLifetimeDiagnostics {
  private struct Probe {
    weak var sample: AnyObject?
    weak var reservation: YlManagedBufferLedger.Token?
    let pts: Int64
  }
  private let lock = NSLock()
  private var probes: [Probe] = []
  private var events: [[String: Any]] = []
  func track(sample: CMSampleBuffer, frame: YlFrameEnvelope) {
    lock.withLock {
      probes.append(.init(sample: sample, reservation: frame.reservation, pts: frame.ptsUs))
      if probes.count > 8 { probes.removeFirst() }
    }
  }
  func record(_ phase: String) {
    lock.withLock {
      events.append(["phase": phase, "uptime": ProcessInfo.processInfo.systemUptime])
      if events.count > 16 { events.removeFirst() }
    }
  }
  var snapshot: [String: Any] {
    lock.withLock {
      ["events": events, "samples": probes.map {
        ["pts": $0.pts, "sampleAlive": $0.sample != nil, "reservationAlive": $0.reservation != nil] as [String: Any]
      }]
    }
  }
}
#endif
