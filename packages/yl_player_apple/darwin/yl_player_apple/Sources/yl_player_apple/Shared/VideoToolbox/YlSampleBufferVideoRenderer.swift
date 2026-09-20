import AVFoundation
import CoreVideo
import ObjectiveC

private var ylDisplayReservationKey: UInt8 = 0

/// Main-thread endpoint for frames already scheduled by the player clock.
/// Uses original buffers and per-frame metadata, with no SDR intermediate.
final class YlSampleBufferVideoRenderer {
  private weak var container: CALayer?
  private var layer: AVSampleBufferDisplayLayer?
  private var latestFrame: YlVideoSurfaceMailbox.Frame?
  private var statusObservation: NSKeyValueObservation?
  private var failed = false
  private var disposed = false
  private var requesting = false
  var onFailure: ((Error) -> Void)?

  func attach(_ container: CALayer) {
    guard !disposed else { return }
    retireLayer()
    self.container = container
    makeLayer()
    if let latestFrame { display(latestFrame) }
  }

  func detach(_ container: CALayer) {
    guard self.container === container else { return }
    retireLayer()
    self.container = nil
  }

  func layout() {
    guard let container else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.frame = container.bounds
    CATransaction.commit()
  }

  private func makeLayer() {
    guard let container else { return }
    let layer = AVSampleBufferDisplayLayer()
    layer.frame = container.bounds
    #if os(macOS)
    layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    #endif
    layer.videoGravity = .resize
    container.addSublayer(layer)
    self.layer = layer
    statusObservation = layer.observe(\.status, options: [.new]) { [weak self] layer, _ in
      DispatchQueue.main.async { [weak self, weak layer] in
        guard let self, let layer, self.layer === layer, layer.status == .failed else { return }
        self.fail(layer.error ?? NSError(domain: "YLVideoSurface", code: -1))
      }
    }
  }

  private func retireLayer() {
    statusObservation = nil
    layer?.stopRequestingMediaData()
    layer?.flushAndRemoveImage()
    layer?.removeFromSuperlayer()
    layer = nil
    requesting = false
  }

  func publish(_ pixelBuffer: CVPixelBuffer, retaining reservation: AnyObject? = nil) {
    guard !failed, !disposed else { return }
    let frame = YlVideoSurfaceMailbox.Frame(pixelBuffer: pixelBuffer, reservation: reservation)
    latestFrame = frame
    display(frame)
  }

  private func display(_ frame: YlVideoSurfaceMailbox.Frame) {
    guard let layer, !failed else { return }
    guard layer.status != .failed else {
      fail(layer.error ?? NSError(domain: "YLVideoSurface", code: -1)); return
    }
    guard layer.isReadyForMoreMediaData else {
      if !requesting {
        requesting = true
        layer.requestMediaDataWhenReady(on: .main) { [weak self, weak layer] in
          guard let self, let layer, self.layer === layer else { return }
          layer.stopRequestingMediaData()
          self.requesting = false
          if let frame = self.latestFrame { self.display(frame) }
        }
      }
      return
    }
    do { layer.enqueue(try Self.makeSample(frame.pixelBuffer, retaining: frame.reservation)) }
    catch { fail(error) }
  }

  func clear() {
    latestFrame = nil
    failed = false
    // A new display layer fences even delayed system errors from the old epoch.
    retireLayer()
    if !disposed { makeLayer() }
  }

  func dispose() {
    disposed = true
    clear()
    container = nil
    onFailure = nil
  }

  private func fail(_ error: Error) {
    guard !failed else { return }
    failed = true
    onFailure?(error)
  }

  static func makeSample(_ pixelBuffer: CVPixelBuffer, retaining reservation: AnyObject? = nil) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    var status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer, formatDescriptionOut: &format)
    guard status == noErr, let format else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    var timing = CMSampleTimingInfo(duration: .invalid,
      presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing,
      sampleBufferOut: &sample)
    guard status == noErr, let sample else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample,
      createIfNecessary: true) as? [NSMutableDictionary], let first = attachments.first {
      first[kCMSampleAttachmentKey_DisplayImmediately] = true
    }
    // A display layer may retain an old sample after the next frame is published.
    // Charge its memory until that sample actually dies; do not attach to pooled CVBuffers.
    objc_setAssociatedObject(sample, &ylDisplayReservationKey, reservation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return sample
  }
}
