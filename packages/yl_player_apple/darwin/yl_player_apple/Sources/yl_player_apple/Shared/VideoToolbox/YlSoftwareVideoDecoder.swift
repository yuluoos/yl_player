import CoreMedia
import CoreVideo
import Darwin
import Foundation
import YlFFmpegBridge

extension YlSoftwareVideoConfiguration {
  func key(model: String, osBuild: String, decoderBuild: String, threads: Int,
           outputPixelFormat: OSType) -> YlSoftwareDecodeKey {
    .init(model: model, osBuild: osBuild, decoderBuild: decoderBuild, codec: descriptor.codec,
      profile: descriptor.profile, bitDepth: Int(descriptor.bit_depth), chroma: Int(descriptor.chroma),
      width: Int(descriptor.width), height: Int(descriptor.height), fpsNumerator: Int(descriptor.fps_num),
      fpsDenominator: Int(descriptor.fps_den), threads: threads, outputPixelFormat: outputPixelFormat)
  }
}

private final class YlSoftwareAllocation {
  let software: YlSoftwareDecodeBudget.Token
  let managed: YlManagedBufferLedger.Token?
  init(_ software: YlSoftwareDecodeBudget.Token, _ managed: YlManagedBufferLedger.Token?) {
    self.software = software; self.managed = managed
  }
}
private final class YlSoftwareAccounting {
  let budget: YlSoftwareDecodeBudget
  let scope: YlManagedBufferScope?
  init(_ budget: YlSoftwareDecodeBudget, _ scope: YlManagedBufferScope?) { self.budget = budget; self.scope = scope }
}

/// Serialized C decoder with process accounting and retained CVPixelBuffer ownership.
/// Callbacks run after unlocking. A failure is terminal and emitted once. Reset
/// discards references; old images continue owning their allocation receipts.
final class YlSoftwareVideoDecoder: YlVideoDecoderResource {
  typealias Observe = (UInt64) -> YlSoftwareDecodeObservation
  private let lock = NSLock()
  private var handle: YLFSoftwareVideoDecoderRef?
  private let accounting: YlSoftwareAccounting
  private let compressed: YlVideoDecodeBudget
  private let observe: Observe
  private let onFrame: (YlVideoFrame) -> Void
  private let onError: (NativePlayerError) -> Void
  private var generation: UInt64?
  private var minimumGeneration: UInt64 = 0
  private var failed = false
  private var monitor: DispatchSourceTimer?
  private var pendingKeyframes = [Int64: Bool]()
  private var pendingTiming = [Int64: YlManagedBufferLedger.Token]()
  private let pixelFormat: OSType
  let hardwareEvidence: YlHardwareDecoderEvidence
  var usesHardwareDecoder: Bool { false }

  init(configuration: YlSoftwareVideoConfiguration, key: YlSoftwareDecodeKey,
       admission: YlSoftwareDecodeAdmission, pool: YlSoftwareDecodePool = .shared,
       maxInFlightBytes: Int, bufferScope: YlManagedBufferScope? = nil,
       observe: @escaping Observe = YlSoftwareVideoDecoder.processObservation,
       monitoringIntervalNs: UInt64? = nil,
       onFrame: @escaping (YlVideoFrame) -> Void, onError: @escaping (NativePlayerError) -> Void) throws {
    guard (1...16).contains(key.threads),
      configuration.key(model: key.model, osBuild: key.osBuild, decoderBuild: key.decoderBuild,
        threads: key.threads, outputPixelFormat: key.outputPixelFormat) == key,
      let limits = admission.limits(for: key), limits.maxFrames <= Int(UInt32.max),
      limits.maxPacketBytes <= Int(UInt32.max) else { throw YlHardwareDecoderEvidence.unavailable() }
    if let interval = monitoringIntervalNs {
      guard interval > 0, interval <= limits.windowNs / 2, interval <= UInt64(Int.max) else {
        throw YlHardwareDecoderEvidence.unavailable()
      }
    }
    let budget = try YlSoftwareDecodeBudget(limits: limits, pool: pool)
    accounting = YlSoftwareAccounting(budget, bufferScope)
    compressed = YlVideoDecodeBudget(maxBytes: maxInFlightBytes)
    self.observe = observe; self.onFrame = onFrame; self.onError = onError
    pixelFormat = key.outputPixelFormat
    hardwareEvidence = .init(software: Int(key.codec) == YLFCodecAV1 ? .dav1d : .ffmpegVP9)
    try budget.observe(using: { observe(0) })
    var native = YLFSoftwareVideoLimits()
    native.max_owned_bytes = UInt64(limits.maxOwnedBytes); native.max_frames = UInt32(limits.maxFrames)
    native.max_packet_bytes = UInt32(limits.maxPacketBytes); native.threads = UInt32(key.threads)
    native.account_context = Unmanaged.passUnretained(accounting).toOpaque()
    native.reserve = { context, bytes, frames, output in
      guard let context, let output, bytes <= UInt64(Int.max) else { return Int32(YLFResultResourceExhausted) }
      output.pointee = nil
      let owner = Unmanaged<YlSoftwareAccounting>.fromOpaque(context).takeUnretainedValue()
      do {
        let token = try owner.budget.reserve(bytes: Int(bytes), frames: Int(frames))
        let managed = owner.scope?.reserve(category: frames > 0 ? .queuedVideoFrames : .compressedPackets, bytes: Int(bytes))
        guard owner.scope == nil || managed != nil else { return Int32(YLFResultResourceExhausted) }
        output.pointee = Unmanaged.passRetained(YlSoftwareAllocation(token, managed)).toOpaque()
        return Int32(YLFResultOK)
      } catch { return Int32(YLFResultResourceExhausted) }
    }
    native.release = { token in
      if let token { Unmanaged<YlSoftwareAllocation>.fromOpaque(token).release() }
    }
    let start = DispatchTime.now().uptimeNanoseconds
    let result = ylf_software_video_create_from_configuration(configuration.handle, native, &handle)
    do {
      try budget.observe(using: { observe(DispatchTime.now().uptimeNanoseconds - start) })
      guard result == YLFResultOK, handle != nil else { throw Self.error(result) }
    } catch {
      if let handle { ylf_software_video_free(handle); self.handle = nil }
      budget.retire(); throw error
    }
    if let interval = monitoringIntervalNs {
      // Continue sampling while paused; a quiet decoder must not create an
      // unobserved CPU window on resume. This never preempts a native C call.
      let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.ylplayer.software-budget", qos: .utility))
      timer.schedule(deadline: .now() + .nanoseconds(Int(interval)), repeating: .nanoseconds(Int(interval)),
        leeway: .nanoseconds(Int(interval / 8)))
      timer.setEventHandler { [weak self] in
        self?.run { _, _ in
          guard let self else { return }
          try self.accounting.budget.observe(using: { self.observe(0) })
        }
      }
      monitor = timer; timer.resume()
    }
  }

  /// Conservative process CPU includes all decoder workers and other app work.
  static func processObservation(wall: UInt64) -> YlSoftwareDecodeObservation {
    var usage = rusage()
    let valid = getrusage(RUSAGE_SELF, &usage) == 0
    let cpu = valid ? UInt64(max(0, usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)) * 1_000_000_000
      + UInt64(max(0, usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)) * 1_000 : 0
    return .init(monotonicNs: DispatchTime.now().uptimeNanoseconds, cumulativeCpuNs: cpu,
      decodeWallNs: wall, thermalNominal: valid ? ProcessInfo.processInfo.thermalState == .nominal : nil)
  }
  func reserve(byteCount: Int, shouldCancel: () -> Bool) throws -> YlVideoDecodeReservation? {
    try compressed.reserve(byteCount: byteCount, shouldCancel: shouldCancel)
  }
  func reserveSubmission(byteCount: Int, shouldCancel: () -> Bool) throws -> YlVideoDecodeReservation? {
    try compressed.reservePending(byteCount: byteCount, shouldCancel: shouldCancel)
  }
  private static func error(_ status: Int32) -> NativePlayerError {
    if status == YLFResultResourceExhausted {
      return .init(category: "resource", code: "resource.exhausted", message: "Software decoding exceeded its measured resource budget.")
    }
    return .init(category: "decoderFailure", code: "decoder.video_configuration_invalid", message: "Software decoding rejected the video configuration.")
  }
  private func measured(_ work: () -> Int32) throws -> Int32 {
    try accounting.budget.observe(using: { observe(0) })
    let start = DispatchTime.now().uptimeNanoseconds
    let result = work()
    try accounting.budget.observe(using: { observe(DispatchTime.now().uptimeNanoseconds - start) })
    return result
  }
  private func receive(_ decoder: YLFSoftwareVideoDecoderRef, frames: inout [YlVideoFrame]) throws {
    while true {
      var image: Unmanaged<CVPixelBuffer>?; var pts = CMTime.invalid; var duration = CMTime.invalid
      let result: Int32
      do { result = try measured { ylf_software_video_receive(decoder, &image, &pts, &duration) } }
      catch {
        // The C call may already have returned +1 before the post-call CPU or
        // thermal check failed. Consume that ownership on this error path too.
        if let image { _ = image.takeRetainedValue() }
        throw error
      }
      // Always consume a returned +1 image, even if validation later fails.
      let pixel = image?.takeRetainedValue()
      if result == YLFResultWouldBlock || result == YLFResultEOF { return }
      guard result == YLFResultOK, let pixel, let generation,
        CVPixelBufferGetPixelFormatType(pixel) == pixelFormat else { throw Self.error(result) }
      let ptsUs = CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value
      let durationUs = CMTimeConvertScale(duration, timescale: 1_000_000, method: .default).value
      let timing = accounting.scope?.reserve(category: .queuedVideoFrames, bytes: 0)
      if accounting.scope != nil {
        guard let timing, timing.carryTiming(ptsUs: ptsUs, durationUs: durationUs, from: pendingTiming[ptsUs]) else {
          throw Self.error(Int32(YLFResultResourceExhausted))
        }
      }
      let keyframe = pendingKeyframes.removeValue(forKey: ptsUs) ?? false
      pendingKeyframes = pendingKeyframes.filter { $0.key > ptsUs }
      pendingTiming = pendingTiming.filter { $0.key > ptsUs }
      frames.append(.init(pixelBuffer: pixel, ptsUs: ptsUs, durationUs: durationUs,
        keyframe: keyframe, generation: generation, ownershipToken: nil, reservation: timing))
    }
  }
  private func run(_ work: (YLFSoftwareVideoDecoderRef, inout [YlVideoFrame]) throws -> Void) {
    var frames = [YlVideoFrame](); var failure: NativePlayerError?
    lock.lock()
    if let handle, !failed {
      do { try work(handle, &frames) }
      catch {
        failed = true; frames.removeAll(); pendingTiming.removeAll(); pendingKeyframes.removeAll()
        monitor?.cancel(); monitor = nil
        accounting.budget.retire()
        failure = (error as? NativePlayerError) ?? Self.error(Int32(YLFResultResourceExhausted))
      }
    }
    lock.unlock()
    for frame in frames { onFrame(frame) }
    if let failure { onError(failure) }
  }
  func decode(sample: CMSampleBuffer, generation: UInt64, reservation: YlVideoDecodeReservation?) {
    defer { reservation?.release() }
    run { decoder, frames in
      guard generation >= minimumGeneration else { return }
      if let current = self.generation, current != generation {
        guard generation > current else { return }
        ylf_software_video_reset(decoder); pendingTiming.removeAll(); pendingKeyframes.removeAll()
      }
      self.generation = generation
      // Match sample sync metadata to displayed PTS, including delayed output.
      // Bound the metadata even when no managed byte receipt is requested.
      guard pendingKeyframes.count < 256 else { throw Self.error(Int32(YLFResultResourceExhausted)) }
      let samplePts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 1_000_000, method: .default).value
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
      pendingKeyframes[samplePts] = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
      if let payload = reservation?.managedPayload {
        guard pendingTiming.count < 256 else { throw Self.error(Int32(YLFResultResourceExhausted)) }
        let pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 1_000_000, method: .default).value
        pendingTiming[pts] = payload
      }
      var result = try measured { ylf_software_video_send(decoder, sample) }
      if result == YLFResultWouldBlock {
        try receive(decoder, frames: &frames)
        result = try measured { ylf_software_video_send(decoder, sample) }
      }
      guard result == YLFResultOK else { throw Self.error(result) }
      try receive(decoder, frames: &frames)
    }
  }
  func drain() {
    run { decoder, frames in
      var result = try measured { ylf_software_video_finish(decoder) }
      if result == YLFResultWouldBlock {
        try receive(decoder, frames: &frames)
        result = try measured { ylf_software_video_finish(decoder) }
      }
      guard result == YLFResultOK || result == YLFResultEOF else { throw Self.error(result) }
      try receive(decoder, frames: &frames); pendingTiming.removeAll(); pendingKeyframes.removeAll()
    }
  }
  func flush() {
    lock.lock(); defer { lock.unlock() }
    if let handle { ylf_software_video_reset(handle) }
    if let generation { minimumGeneration = generation == UInt64.max ? generation : generation + 1 }
    generation = nil; pendingTiming.removeAll(); pendingKeyframes.removeAll(); compressed.reset()
  }
  func dispose() {
    lock.lock(); defer { lock.unlock() }
    monitor?.cancel(); monitor = nil
    if let handle { ylf_software_video_free(handle); self.handle = nil }
    pendingTiming.removeAll(); pendingKeyframes.removeAll(); accounting.budget.retire(); compressed.reset()
  }
  deinit { dispose() }
}
