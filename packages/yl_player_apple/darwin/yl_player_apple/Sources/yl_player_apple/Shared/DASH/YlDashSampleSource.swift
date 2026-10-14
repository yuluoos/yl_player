import CoreMedia
import Foundation
import YlFFmpegBridge

/// Owns exactly one initialization/fragment pair. The existing FFmpeg demuxer
/// sees a seekable in-memory file; all network I/O happened through the managed
/// supplier before opening it. No MP4 bytes or decode timestamps are rewritten.
final class YlDashSampleSource {
  typealias Time = YlDashProgramTime
  final class Packet {
    let pts: Time
    let dts: Time?
    let duration: Time
    let keyframe: Bool
    let byteCount: Int
    private let owner: YlDashSampleSource
    private var packet: YLFPacketRef?
    private var reservation: YlManagedBufferLedger.Token?
    fileprivate init(owner: YlDashSampleSource, packet: YLFPacketRef, pts: Time,
                     dts: Time?, duration: Time, reservation: YlManagedBufferLedger.Token) {
      self.owner = owner; self.packet = packet; self.pts = pts; self.dts = dts
      self.duration = duration; self.reservation = reservation
      keyframe = ylf_packet_is_keyframe(packet); byteCount = ylf_packet_size(packet)
    }
    /// Makes the sole owned packet-to-CoreMedia transfer; retiming occurs only at
    /// the output boundary after exact rational window decisions.
    func videoSample(format: CMVideoFormatDescription, pts: CMTime, dts: CMTime,
                     duration: CMTime) throws -> CMSampleBuffer {
      var ownedSample: Unmanaged<CMSampleBuffer>?
      guard ylf_create_video_sample_buffer(&packet, format, &ownedSample) == 0, let ownedSample else { throw YlDashSampleSource.invalid() }
      let sample = ownedSample.takeRetainedValue()
      var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: dts)
      guard let originalBlock = CMSampleBufferGetDataBuffer(sample) else { throw YlDashSampleSource.invalid() }
      var pointer: UnsafeMutablePointer<Int8>?
      var length = 0, total = 0
      guard CMBlockBufferGetDataPointer(originalBlock, atOffset: 0, lengthAtOffsetOut: &length,
        totalLengthOut: &total, dataPointerOut: &pointer) == noErr,
        let pointer, length == total else { throw YlDashSampleSource.invalid() }
      let owner = Unmanaged.passRetained(SampleOwner(sample: sample, reservation: reservation))
      var callbacks = CMBlockBufferCustomBlockSource(version: kCMBlockBufferCustomBlockSourceVersion,
        AllocateBlock: nil, FreeBlock: { reference, _, _ in
          if let reference { Unmanaged<SampleOwner>.fromOpaque(reference).release() }
        }, refCon: owner.toOpaque())
      var block: CMBlockBuffer?
      let status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
        memoryBlock: pointer, blockLength: total, blockAllocator: kCFAllocatorNull,
        customBlockSource: &callbacks, offsetToData: 0, dataLength: total,
        flags: 0, blockBufferOut: &block)
      guard status == noErr, let block else { owner.release(); throw YlDashSampleSource.invalid() }
      var size = total, retimed: CMSampleBuffer?
      guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
        formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
        sampleBufferOut: &retimed) == noErr, let retimed else { throw YlDashSampleSource.invalid() }
      if let attachments = CMSampleBufferGetSampleAttachmentsArray(retimed, createIfNecessary: true) as? [NSMutableDictionary],
         let first = attachments.first { first[kCMSampleAttachmentKey_NotSync] = !keyframe }
      // A private object attachment is not serializable to the decoder service.
      // Block ownership instead follows the actual bytes through asynchronous VT.
      self.reservation = nil
      return retimed
    }
    private final class SampleOwner {
      let sample: CMSampleBuffer
      let reservation: YlManagedBufferLedger.Token?
      init(sample: CMSampleBuffer, reservation: YlManagedBufferLedger.Token?) {
        self.sample = sample; self.reservation = reservation
      }
    }
    /// Audio conversion consumes a copy; retain this packet until conversion has
    /// completed so its reservation covers the transient copy as well.
    func audioBytes() throws -> Data {
      guard let packet, let bytes = ylf_packet_data(packet) else { throw YlDashSampleSource.invalid() }
      return Data(bytes: bytes, count: byteCount)
    }
    deinit { ylf_packet_release(&packet) }
  }

  let stream: YLFStreamInfo
  let videoFormat: CMVideoFormatDescription?
  let codecConfiguration: Data
  private var context: YLFMediaContextRef?
  private let input: Input
  private let scope: YlManagedBufferScope
  private let workspace: YlManagedBufferLedger.Token

  init(initialization: YlDashProgramResources.Payload, fragment: YlDashProgramResources.Payload,
       kind: YlDashProgram.Track.Kind, cancellation: YlOpenCancellationToken,
       scope: YlManagedBufferScope) throws {
    try cancellation.throwIfCancelled()
    self.scope = scope
    workspace = try scope.require(category: .compressedPackets, bytes: 512 * 1024)
    input = Input(initialization, fragment, cancellation)
    var opened: YLFMediaContextRef?, info = YLFMediaInfo()
    let result = ylf_open_callbacks(Unmanaged.passUnretained(input).toOpaque(), dashRead, dashSeek, dashCancel, &opened, &info)
    guard result == 0, let opened else { try cancellation.throwIfCancelled(); throw Self.invalid() }
    var committed = false
    defer { if !committed { var value: YLFMediaContextRef? = opened; ylf_close(&value) } }
    // A Representation is a single elementary stream. Reject multiplexed or
    // unexpected hidden tracks before a selected decoder is admitted.
    var stream = YLFStreamInfo()
    guard info.stream_count == 1, ylf_copy_stream_info(opened, 0, &stream) == 0,
          stream.time_base_num > 0, stream.time_base_den > 0,
          (kind == .video && stream.kind == YLFStreamVideo) || (kind == .audio && stream.kind == YLFStreamAudio) else { throw Self.invalid() }
    self.stream = stream
    let size = ylf_stream_codec_config_size(opened, stream.index)
    guard size <= 1024 * 1024 else { throw Self.invalid() }
    var config = Data(count: size)
    if size > 0 {
      let status = config.withUnsafeMutableBytes { ylf_copy_stream_codec_config(opened, stream.index, $0.bindMemory(to: UInt8.self).baseAddress, size) }
      guard status == 0 else { throw Self.invalid() }
    }
    codecConfiguration = config
    if kind == .video {
      var format: Unmanaged<CMVideoFormatDescription>?
      guard ylf_copy_video_format_description(opened, stream.index, &format) == 0, let format else { throw Self.invalid() }
      videoFormat = format.takeRetainedValue()
    } else { videoFormat = nil }
    try cancellation.throwIfCancelled()
    context = opened; committed = true
  }

  /// Serial demux-worker API. Returned packets keep their context and input alive.
  func next() throws -> Packet? {
    try input.cancellation.throwIfCancelled()
    var packet: YLFPacketRef?
    let result = ylf_read_packet(context, &packet)
    if result == YLFResultEOF { return nil }
    guard result == 0, let owned = packet else { try input.cancellation.throwIfCancelled(); throw Self.invalid() }
    var transferred = false
    defer { if !transferred { ylf_packet_release(&packet) } }
    let bytes = ylf_packet_size(owned)
    guard bytes > 0, bytes <= 8 * 1024 * 1024 else { throw Self.invalid() }
    let reservation = try scope.require(category: .compressedPackets, bytes: bytes * 2)
    var pts: Int64 = 0, dts: Int64 = 0, duration: Int64 = 0
    guard ylf_packet_raw_timestamps(owned, &pts, &dts, &duration) == 0,
          pts != Int64.min, duration > 0 else { throw Self.invalid() }
    let value = try Packet(owner: self, packet: owned, pts: time(pts),
      dts: dts == Int64.min ? nil : time(dts), duration: time(duration), reservation: reservation)
    transferred = true
    return value
  }
  private func time(_ ticks: Int64) throws -> Time {
    let reduced = try Time(ticks, Int64(stream.time_base_den))
    let (value, overflow) = reduced.numerator.multipliedReportingOverflow(by: Int64(stream.time_base_num))
    guard !overflow else { throw YlDashProgramError.overflow }
    return try Time(value, reduced.denominator)
  }
  deinit { ylf_close(&context) }
  private static func invalid() -> NativePlayerError {
    NativePlayerError(category: "container", code: "container.dash_sample_invalid",
      message: "The DASH fragment does not provide a supported exact sample timeline.")
  }

  fileprivate final class Input {
    let initialization: YlDashProgramResources.Payload
    let fragment: YlDashProgramResources.Payload
    let cancellation: YlOpenCancellationToken
    var cursor = 0
    var length: Int { initialization.data.count + fragment.data.count }
    init(_ initialization: YlDashProgramResources.Payload, _ fragment: YlDashProgramResources.Payload, _ cancellation: YlOpenCancellationToken) {
      self.initialization = initialization; self.fragment = fragment; self.cancellation = cancellation
    }
    func read(_ destination: UnsafeMutablePointer<UInt8>, _ capacity: Int) -> Int32 {
      if cancellation.isCancelled { return Int32(YLFCallbackCancelled) }
      guard capacity > 0, cursor < length else { return 0 }
      let first = cursor < initialization.data.count
      let bytes = first ? initialization.data : fragment.data
      let offset = first ? cursor : cursor - initialization.data.count
      let count = min(capacity, bytes.count - offset)
      bytes.withUnsafeBytes { memory in
        destination.update(from: memory.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: count)
      }
      cursor += count; return Int32(count)
    }
    func seek(_ offset: Int64, _ whence: Int32) -> Int64 {
      if cancellation.isCancelled { return Int64(YLFCallbackCancelled) }
      if whence == 0x10000 { return Int64(length) }
      let base: Int64
      switch whence & ~0x20000 { case 0: base = 0; case 1: base = Int64(cursor); case 2: base = Int64(length); default: return Int64(YLFCallbackSeekUnsupported) }
      let (target, overflow) = base.addingReportingOverflow(offset)
      guard !overflow, target >= 0, target <= Int64(length) else { return Int64(YLFCallbackError) }
      cursor = Int(target); return target
    }
  }
}

private func dashInput(_ pointer: UnsafeMutableRawPointer?) -> YlDashSampleSource.Input? {
  pointer.map { Unmanaged<YlDashSampleSource.Input>.fromOpaque($0).takeUnretainedValue() }
}
private func dashRead(_ pointer: UnsafeMutableRawPointer?, _ bytes: UnsafeMutablePointer<UInt8>?, _ capacity: Int32) -> Int32 {
  guard let input = dashInput(pointer), let bytes else { return Int32(YLFCallbackError) }
  return input.read(bytes, Int(capacity))
}
private func dashSeek(_ pointer: UnsafeMutableRawPointer?, _ offset: Int64, _ whence: Int32) -> Int64 {
  dashInput(pointer)?.seek(offset, whence) ?? Int64(YLFCallbackError)
}
private func dashCancel(_ pointer: UnsafeMutableRawPointer?) {
  // FFmpeg closing one fragment must not cancel the programme's shared command.
  // Its callbacks are synchronous and the input token already interrupts reads.
}
