import CoreMedia
import CoreVideo
import Foundation
import YlFFmpegBridge

private final class YlFELDecoderRelay {
  weak var owner: YlFELVideoDecoder?
}

/// A decoder resource owns one complete BL/EL epoch. Neither decoder can emit
/// directly to presentation; only a successfully reconstructed pair can do so.
final class YlFELVideoDecoder {
  private struct Payload {
    let metadata: YlFELMetadata
    let rpu: Data
    let reservation: YlManagedBufferLedger.Token?
  }
  private let stateLock = NSLock()
  private let parserLock = NSLock()
  private let compositionLock = NSLock()
  private let pairs = YlFELPairing<YlVideoFrame, Payload>()
  private var parser: YLFFELContextRef?
  private var base: YlVideoToolboxDecoder?
  private var enhancement: YlVideoToolboxDecoder?
  private var lease: YlHardwareDecoderLease?
  private var generation: UInt64?
  private var failed = false
  private var disposed = false
  private let configuration: YlFELConfiguration
  private let budget: YlFallbackBufferBudget
  private let compositor: YlFELCompositor
  private let onFrame: (YlVideoFrame) -> Void
  private let onError: (NativePlayerError) -> Void
  private let relay = YlFELDecoderRelay()

  var hardwareEvidence: YlHardwareDecoderEvidence {
    let modes = [base?.hardwareEvidence.mode, enhancement?.hardwareEvidence.mode]
    if modes.allSatisfy({ $0 == .hardware }) { return .init(mode: .hardware) }
    if modes.contains(where: { $0 == .software }) { return .init(mode: .software) }
    return .unknown
  }
  var usesHardwareDecoder: Bool { hardwareEvidence.mode == .hardware }

  init(configuration: YlFELConfiguration, bufferBudget: YlFallbackBufferBudget,
       factory: YlVTSessionFactory, policy: YlDecoderPolicy,
       onFrame: @escaping (YlVideoFrame) -> Void,
       onError: @escaping (NativePlayerError) -> Void) throws {
    self.configuration = configuration
    self.budget = bufferBudget
    self.onFrame = onFrame
    self.onError = onError
    compositor = try YlFELCompositor()
    parser = try configuration.freshParser()
    relay.owner = self
    do {
      if YlAppleCompatibility.current.limitsVideoReservations {
        lease = try YlHardwareDecoderLeasePool.shared.acquire()
      }
      base = try YlVideoToolboxDecoder(formatDescription: configuration.baseFormat,
        maxInFlightBytes: budget.inFlightPacketBytes, bufferScope: budget.bufferScope,
        factory: factory, sharedLease: lease,
        outputPixelFormat: Self.pixelFormat(for: configuration.baseFormat),
        onFrame: { [relay] frame in relay.owner?.receive(frame, side: .base) },
        onError: { [relay] error in relay.owner?.fail(error) })
      enhancement = try YlVideoToolboxDecoder(formatDescription: configuration.enhancementFormat,
        maxInFlightBytes: budget.inFlightPacketBytes, bufferScope: budget.bufferScope,
        factory: factory, sharedLease: lease,
        outputPixelFormat: Self.pixelFormat(for: configuration.enhancementFormat),
        onFrame: { [relay] frame in relay.owner?.receive(frame, side: .enhancement) },
        onError: { [relay] error in relay.owner?.fail(error) })
      if policy == .hardwareRequired && !usesHardwareDecoder {
        throw YlHardwareDecoderEvidence.unavailable()
      }
    } catch { dispose(); throw error }
  }

  func consume(packet: inout YLFPacketRef?, ownedPacket: YLFPacketRef, generation: UInt64,
               managedPayload: YlManagedBufferLedger.Token?, shouldCancel: () -> Bool) throws -> Bool {
    defer { ylf_packet_release(&packet) }
    guard !shouldCancel() else { return false }
    let size = ylf_packet_size(ownedPacket)
    try budget.validateInFlightPacket(size: size)
    guard size <= (Int.max - 131072) / 4 else { throw YlManagedBufferLedger.unsupported() }
    // Charge copies and parsed metadata before the bridge allocates either.
    let receipt = try budget.bufferScope?.require(category: .compressedPackets, bytes: size * 4 + 131072)
    let pts = ylf_packet_pts_us(ownedPacket)
    let dts = ylf_packet_dts_us(ownedPacket)
    let duration = ylf_packet_duration_us(ownedPacket)
    let keyframe = ylf_packet_is_keyframe(ownedPacket)
    guard receipt?.carryTiming(ptsUs: pts, durationUs: max(0, duration), from: managedPayload) ?? true else {
      throw YlManagedBufferLedger.unsupported()
    }
    parserLock.lock()
    guard let parser else { parserLock.unlock(); return false }
    var raw: Unmanaged<CFDictionary>?
    let result = ylf_fel_copy_access_unit(parser, ownedPacket, &raw)
    parserLock.unlock()
    guard result == YLFResultOK, let raw,
          let unit = raw.takeRetainedValue() as NSDictionary as? [String: Any],
          let bl = unit["baseData"] as? Data, let el = unit["enhancementData"] as? Data,
          let values = unit["metadata"] as? [String: Any], let rpu = unit["rpu"] as? Data else {
      throw YlFELFailure.bridge(result, "access unit")
    }
    let dimensions = CMVideoFormatDescriptionGetDimensions(configuration.baseFormat)
    let metadata = try YlFELFailure.metadata(values, frameSize: (Int(dimensions.width), Int(dimensions.height)))
    let blFormat = try YlFELConfiguration.format(unit, key: "baseFormat")
    let elFormat = try YlFELConfiguration.format(unit, key: "enhancementFormat")
    guard CMFormatDescriptionEqual(blFormat, otherFormatDescription: configuration.baseFormat),
          CMFormatDescriptionEqual(elFormat, otherFormatDescription: configuration.enhancementFormat) else {
      throw YlFELFailure.bridge(Int32(YLFResultDolbyVisionUnsupported), "mid-stream configuration change")
    }
    guard let base, let enhancement, !shouldCancel() else { return false }
    guard let blReservation = try base.reserve(byteCount: bl.count, shouldCancel: shouldCancel),
          let elReservation = try enhancement.reserve(byteCount: el.count, shouldCancel: shouldCancel) else { return false }
    blReservation.managedPayload = receipt
    elReservation.managedPayload = receipt
    let blSample = try Self.sample(bl, format: blFormat, pts: pts, dts: dts, duration: duration, keyframe: keyframe)
    let elSample = try Self.sample(el, format: elFormat, pts: pts, dts: dts, duration: duration, keyframe: keyframe)
    if let receipt {
      ylRetainManagedPayload(receipt, in: blSample)
      ylRetainManagedPayload(receipt, in: elSample)
    }
    stateLock.lock()
    do {
      guard !disposed, !failed else { stateLock.unlock(); return false }
      if self.generation == nil {
        self.generation = generation
        pairs.reset(generation: generation)
      }
      guard self.generation == generation else {
        throw YlFELFailure.make("decoder.dolby_vision_fel_invalid", "FEL decoder epoch was reused")
      }
      try pairs.register(pts: pts, generation: generation,
        metadata: Payload(metadata: metadata, rpu: rpu, reservation: receipt))
      stateLock.unlock()
    } catch { stateLock.unlock(); throw error }
    base.decode(sample: blSample, generation: generation, reservation: blReservation)
    enhancement.decode(sample: elSample, generation: generation, reservation: elReservation)
    return true
  }

  private func receive(_ frame: YlVideoFrame, side: YlFELPairing<YlVideoFrame, Payload>.Side) {
    do {
      stateLock.lock()
      let pair: YlFELPairing<YlVideoFrame, Payload>.Pair?
      do {
        guard !disposed, !failed else { stateLock.unlock(); return }
        pair = try pairs.receive(frame, side: side, pts: frame.ptsUs, generation: frame.generation)
        stateLock.unlock()
      } catch { stateLock.unlock(); throw error }
      guard let pair else { return }
      compositionLock.lock(); defer { compositionLock.unlock() }
      guard stateLock.withLock({ !disposed && !failed && generation == frame.generation }) else { return }
      let width = CVPixelBufferGetWidth(pair.base.pixelBuffer)
      let height = CVPixelBufferGetHeight(pair.base.pixelBuffer)
      guard width <= (Int.max - 255) / 8, height > 0,
            height <= (Int.max - 4096) / ((width * 8 + 255) & ~255) else {
        throw YlManagedBufferLedger.unsupported()
      }
      let imageCharge = ((width * 8 + 255) & ~255) * height + 4096
      guard pair.metadata.rpu.count <= Int.max - imageCharge else { throw YlManagedBufferLedger.unsupported() }
      let outputCharge = imageCharge + pair.metadata.rpu.count
      let outputReceipt = try budget.bufferScope?.require(category: .queuedVideoFrames, bytes: outputCharge)
      let output = try compositor.compose(base: pair.base.pixelBuffer,
        enhancement: pair.enhancement.pixelBuffer, metadata: pair.metadata.metadata)
      guard CVPixelBufferGetDataSize(output) <= imageCharge else { throw YlManagedBufferLedger.unsupported() }
      guard outputReceipt?.carryTiming(ptsUs: frame.ptsUs, durationUs: max(0, frame.durationUs),
        from: pair.base.reservation ?? pair.metadata.reservation) ?? true else { throw YlManagedBufferLedger.unsupported() }
      // This is provenance, not a request for Apple to apply Dolby transforms
      // again to already reconstructed linear RGB pixels.
      CVBufferSetAttachment(output, "YlFELSourceRPU" as CFString, pair.metadata.rpu as CFData, .shouldNotPropagate)
      guard stateLock.withLock({ !disposed && !failed && generation == frame.generation }) else { return }
      onFrame(YlVideoFrame(pixelBuffer: output, ptsUs: pair.base.ptsUs, durationUs: pair.base.durationUs,
        keyframe: pair.base.keyframe, generation: pair.base.generation,
        ownershipToken: pair.metadata.reservation, reservation: outputReceipt))
    } catch { fail(Self.failure(error)) }
  }

  func drain(generation: UInt64) {
    base?.drain()
    enhancement?.drain()
    do {
      stateLock.lock(); defer { stateLock.unlock() }
      guard !disposed, !failed else { return }
      try pairs.finish(generation: generation)
    } catch { fail(Self.failure(error)) }
  }

  func dispose() {
    let retire = stateLock.withLock { () -> Bool in
      guard !disposed else { return false }
      disposed = true
      pairs.reset(generation: 0)
      return true
    }
    guard retire else { return }
    base?.dispose(); enhancement?.dispose()
    lease?.release(); lease = nil
    parserLock.lock()
    if let parser { ylf_fel_free(parser) }
    parser = nil
    parserLock.unlock()
  }

  private func fail(_ error: NativePlayerError) {
    let report = stateLock.withLock { () -> Bool in
      guard !failed, !disposed else { return false }
      failed = true
      pairs.reset(generation: 0)
      return true
    }
    if report { onError(error) }
  }

  private static func failure(_ error: Error) -> NativePlayerError {
    if let native = error as? NativePlayerError { return native }
    return YlFELFailure.make("decoder.dolby_vision_fel_invalid", String(describing: type(of: error)))
  }

  private static func sample(_ data: Data, format: CMVideoFormatDescription,
                             pts: Int64, dts: Int64, duration: Int64, keyframe: Bool) throws -> CMSampleBuffer {
    var block: CMBlockBuffer?
    var result = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
      memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
    guard result == noErr, let block else { throw YlFELFailure.make("decoder.dolby_vision_fel_invalid", "FEL block allocation") }
    result = data.withUnsafeBytes { bytes in
      CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
    }
    guard result == noErr else { throw YlFELFailure.make("decoder.dolby_vision_fel_invalid", "FEL block copy") }
    var timing = CMSampleTimingInfo(duration: duration > 0 ? CMTime(value: duration, timescale: 1_000_000) : .invalid,
      presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000),
      decodeTimeStamp: dts == Int64.min ? .invalid : CMTime(value: dts, timescale: 1_000_000))
    var size = data.count
    var sample: CMSampleBuffer?
    result = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
      formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
    guard result == noErr, let sample else { throw YlFELFailure.make("decoder.dolby_vision_fel_invalid", "FEL sample creation") }
    if !keyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
      attachments.first?[kCMSampleAttachmentKey_NotSync] = true
    }
    return sample
  }

  deinit { dispose() }

  static func pixelFormat(for format: CMVideoFormatDescription) -> OSType {
    let full = CMFormatDescriptionGetExtension(format,
      extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool == true
    return full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
      : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
  }
}
