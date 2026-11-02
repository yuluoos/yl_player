import yl_player_media_core
#if os(macOS)
import AppKit
import AVFoundation
import CoreImage
import Metal

@available(macOS 14.0, *)
public enum YlMetalSpikeReadback {
  public static var metrics: [String: Any]? { YlMacosTimedVideoEndpoint.active?.metrics }
}
// Isolated continuous-SDR presentation experiment. GPU allocations are not qualified.
@available(macOS 14.0, *)
final class YlMacosTimedVideoEndpoint: YlTimedVideoEndpoint {
  static weak var active: YlMacosTimedVideoEndpoint?
  private let layer: CAMetalLayer
  private let device: MTLDevice
  private let commands: MTLCommandQueue
  private let context: CIContext
  private let queue = DispatchQueue(label: "dev.ylplayer.metal-spike", qos: .userInitiated)
  private let stateLock = NSLock()
  private let group = DispatchGroup()
  private var closed = false
  private var snapshot: YlPresentationClockSnapshot?
  private var generation: UInt64?
  private var readyHandler: (() -> Void)?
  private var prepared = false
  private var preparing = false
  private var pending = 0
  private var presented = 0
  private var dropped = 0
  private var late = 0
  private var maximumDelay = 0.0
  private var preview: [YlFrameEnvelope] = []
  private let onFailure: (Error) -> Void
  var lifetimeDiagnostics: YlTimedVideoLifetimeDiagnostics? { nil }
  var isRetired: Bool { stateLock.withLock { closed } }
  var diagnostics: [String: Any]? { metrics }
  var metrics: [String: Any] {
    queue.sync {
      ["status": "observed", "path": "metal", "metalReady": prepared,
       "totalFrames": presented, "droppedFrames": dropped, "corruptedFrames": 0,
       "lateFrames": late, "maximumPresentationDelaySeconds": maximumDelay,
       "totalFrameDelaySeconds": maximumDelay, "surfaceHasBounds": !layer.bounds.isEmpty]
    }
  }
  var pausedPreview: YlFrameEnvelope? {
    queue.sync {
      guard let snapshot, !snapshot.playing else { return nil }
      return preview.last { $0.ptsUs <= snapshot.positionUs }
    }
  }
  init(container: CALayer, collectDiagnostics: Bool = false, onFailure: @escaping (Error) -> Void) throws {
    precondition(Thread.isMainThread)
    device = MTLCreateSystemDefaultDevice()!
    commands = device.makeCommandQueue()!
    context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    layer = CAMetalLayer()
    layer.device = device
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = false
    layer.maximumDrawableCount = 3
    layer.displaySyncEnabled = true
    layer.frame = container.bounds
    layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    layer.drawableSize = CGSize(width: 320, height: 180)
    self.onFailure = onFailure
    container.addSublayer(layer)
    Self.active = self
  }
  func layout(in container: CALayer) {
    print("METAL_LAYOUT", CACurrentMediaTime(), container.bounds, layer.frame)
    precondition(Thread.isMainThread)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.frame = container.bounds
    CATransaction.commit()
  }
  func prepare(_ pixel: CVPixelBuffer, retaining reservation: AnyObject?) {
    queue.async { [self] in
      guard !isRetired, !prepared, !preparing else { return }
      preparing = true
      render(pixel, target: nil) { [self, reservation] actual in
        withExtendedLifetime(reservation) {}
        preparing = false
        print("METAL_PREFLIGHT", actual)
        if actual > 0 {
          prepared = true
          presented = 1
          readyHandler?()
        } else {
          queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in
            prepare(pixel, retaining: reservation)
          }
        }
      }
    }
  }
  func update(_ snapshot: YlPresentationClockSnapshot, generation: UInt64) {
    queue.sync {
      self.snapshot = snapshot
      self.generation = generation
      let current = preview.last { $0.ptsUs <= snapshot.positionUs }
      preview = (current.map { [$0] } ?? []) + preview.filter { $0.ptsUs > snapshot.positionUs }.suffix(3)
    }
  }
  func setReadyHandler(_ handler: @escaping () -> Void) { queue.sync { readyHandler = handler } }
  func enqueue(_ frame: YlFrameEnvelope) -> Bool {
    queue.sync {
      guard !isRetired, prepared, pending < 3, frame.generation == generation,
        let snapshot, snapshot.playing else { return false }
      let pixel = unsafeBitCast(frame.payload, to: CVPixelBuffer.self)
      precondition(CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
      let target = Double(snapshot.hostTimeUs)/1_000_000 + Double(frame.ptsUs-snapshot.positionUs)/1_000_000/snapshot.rate
      pending += 1
      preview.append(frame)
      render(pixel, target: target) { [self, frame] actual in
        withExtendedLifetime(frame) {}
        pending -= 1
        if actual == 0 { dropped += 1 }
        else {
          presented += 1
          maximumDelay = max(maximumDelay, actual-target)
          if actual-target > 1.0/24 { late += 1 }
        }
        print("METAL_PRESENT", frame.ptsUs, target, actual)
        readyHandler?()
      }
      return true
    }
  }
  private func render(_ pixel: CVPixelBuffer, target: Double?, completion: @escaping (Double) -> Void) {
    autoreleasepool {
      let drawable = layer.nextDrawable()!
      let command = commands.makeCommandBuffer()!
      context.render(CIImage(cvPixelBuffer: pixel), to: drawable.texture, commandBuffer: command,
        bounds: CGRect(x: 0, y: 0, width: 320, height: 180), colorSpace: CGColorSpaceCreateDeviceRGB())
      group.enter()
      drawable.addPresentedHandler { [self] receipt in
        let actual = receipt.presentedTime
        queue.async {
          completion(actual)
          group.leave()
        }
      }
      command.addCompletedHandler { [onFailure] completed in
        if let error = completed.error { DispatchQueue.main.async { onFailure(error) } }
      }
      if let target { command.present(drawable, atTime: target) }
      else { command.present(drawable) }
      command.commit()
    }
  }
  func retire(removingImage: Bool, completion: @escaping () -> Void) {
    stateLock.withLock { closed = true }
    queue.async { [self] in
      readyHandler = nil
      group.notify(queue: queue) { [self] in
        preview.removeAll()
        DispatchQueue.main.async { [self] in
          layer.removeFromSuperlayer()
          completion()
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
