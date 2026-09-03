import AudioToolbox
import AVFAudio
import Foundation

enum YlAudioCodec: Equatable {
  case aac
  case unsupported
}

struct YlAudioStreamConfiguration: Equatable {
  let codec: YlAudioCodec
  let sampleRate: Double
  let channelCount: Int
  let magicCookie: Data
  let generation: UInt64
}

struct YlCompressedAudioPacket {
  let data: Data
  let ptsUs: Int64
  let durationUs: Int64
  let generation: UInt64
}

struct YlAudioBufferEstimate: Equatable {
  let durationUs: Int64
  let byteCount: Int
}

struct YlScheduledAudioBuffer {
  let payload: AnyObject
  let ptsUs: Int64
  let durationUs: Int64
  let byteCount: Int
  let generation: UInt64
}

enum YlAudioEnqueueResult: Equatable {
  case scheduled
  case wouldExceedDuration
  case wouldExceedBytes
  case staleGeneration
}

protocol YlAudioPacketConverting: AnyObject {
  func configure(stream: YlAudioStreamConfiguration) throws
  func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate
  func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer
}

protocol YlAudioOutputDriving: AnyObject {
  var volume: Float { get set }
  var rate: Float { get set }
  var renderedAudioTime: YlRenderedAudioTime? { get }
  func configure(sampleRate: Double, channelCount: Int) throws
  func schedule(_ buffer: YlScheduledAudioBuffer, completion: @escaping () -> Void)
  func play() throws
  func pause()
  func reset()
  func dispose()
}

protocol YlAudioRendering: AnyObject {
  func configure(stream: YlAudioStreamConfiguration) throws
  func enqueue(packet: YlCompressedAudioPacket) throws -> YlAudioEnqueueResult
  func play() throws
  func pause()
  func seek(to positionUs: Int64)
  func setVolume(_ volume: Float)
  func setRate(_ rate: Float)
  func flush()
  func dispose()
}

final class YlAudioRenderer: YlAudioRendering {
  private let lock = NSLock()
  private let maxScheduledDurationUs: Int64
  private let maxScheduledBytes: Int
  private let converter: YlAudioPacketConverting
  private let output: YlAudioOutputDriving
  private var configuredGeneration: UInt64?
  private var completionGeneration: UInt64 = 0
  private var scheduledBufferCount = 0
  private var disposed = false
  private var scheduledDuration = Int64(0)
  private var scheduledByteCount = 0
  private var underruns = 0

  init(
    maxScheduledDurationUs: Int64 = 500_000,
    maxScheduledBytes: Int = 2 * 1024 * 1024,
    converter: YlAudioPacketConverting = YlAppleAACConverter(),
    output: YlAudioOutputDriving = YlSystemAudioOutput()
  ) {
    precondition(maxScheduledDurationUs >= 0)
    precondition(maxScheduledBytes >= 0)
    self.maxScheduledDurationUs = maxScheduledDurationUs
    self.maxScheduledBytes = maxScheduledBytes
    self.converter = converter
    self.output = output
  }

  var scheduledDurationUs: Int64 {
    lock.withLock { scheduledDuration }
  }

  var scheduledBytes: Int {
    lock.withLock { scheduledByteCount }
  }

  var underrunCount: Int {
    lock.withLock { underruns }
  }

  var renderedAudioTime: YlRenderedAudioTime? {
    output.renderedAudioTime
  }

  func configure(stream: YlAudioStreamConfiguration) throws {
    guard lock.withLock({ !disposed }) else {
      throw NativePlayerError(
        category: "internal",
        code: "internal.fallback_invariant",
        message: "A disposed audio renderer cannot be configured."
      )
    }
    do {
      try converter.configure(stream: stream)
      try output.configure(
        sampleRate: stream.sampleRate,
        channelCount: stream.channelCount
      )
    } catch {
      throw NativePlayerError(
        category: "decoder",
        code: "decoder.audio_aac_unsupported",
        message: "The AAC audio configuration is unsupported.",
        diagnostic: String(describing: error)
      )
    }
    flush()
    lock.lock()
    configuredGeneration = stream.generation
    lock.unlock()
  }

  func enqueue(packet: YlCompressedAudioPacket) throws -> YlAudioEnqueueResult {
    let estimate = converter.estimateOutput(for: packet)
    lock.lock()
    guard !disposed, configuredGeneration == packet.generation else {
      lock.unlock()
      return .staleGeneration
    }
    let estimatedCapacity = capacityResult(
      durationUs: estimate.durationUs,
      byteCount: estimate.byteCount
    )
    lock.unlock()
    guard estimatedCapacity == .scheduled else { return estimatedCapacity }

    let buffer: YlScheduledAudioBuffer
    do {
      buffer = try converter.convert(packet: packet)
    } catch {
      throw NativePlayerError(
        category: "decoder",
        code: "decoder.audio_failed",
        message: "AAC audio conversion failed.",
        diagnostic: String(describing: error)
      )
    }

    lock.lock()
    guard !disposed, configuredGeneration == packet.generation else {
      lock.unlock()
      return .staleGeneration
    }
    let exactCapacity = capacityResult(
      durationUs: buffer.durationUs,
      byteCount: buffer.byteCount
    )
    guard exactCapacity == .scheduled else {
      lock.unlock()
      return exactCapacity
    }
    let token = completionGeneration
    scheduledDuration += max(0, buffer.durationUs)
    scheduledByteCount += max(0, buffer.byteCount)
    scheduledBufferCount += 1
    lock.unlock()

    output.schedule(buffer) { [weak self] in
      self?.complete(
        durationUs: buffer.durationUs,
        byteCount: buffer.byteCount,
        completionGeneration: token
      )
    }
    return .scheduled
  }

  func play() throws {
    lock.lock()
    guard !disposed else {
      lock.unlock()
      return
    }
    if scheduledBufferCount == 0 { underruns += 1 }
    lock.unlock()
    do {
      try output.play()
    } catch {
      throw NativePlayerError(
        category: "render",
        code: "render.audio_engine_failed",
        message: "The native audio engine could not start.",
        diagnostic: String(describing: error)
      )
    }
  }

  func pause() {
    output.pause()
  }

  func seek(to positionUs: Int64) {
    _ = positionUs
    flush()
  }

  func setVolume(_ volume: Float) {
    output.volume = min(max(volume, 0), 1)
  }

  func setRate(_ rate: Float) {
    output.rate = min(max(rate, 0.25), 4)
  }

  func flush() {
    lock.lock()
    guard !disposed else {
      lock.unlock()
      return
    }
    completionGeneration &+= 1
    scheduledDuration = 0
    scheduledByteCount = 0
    scheduledBufferCount = 0
    lock.unlock()
    output.reset()
  }

  func reset(generation: UInt64) {
    flush()
    lock.withLock {
      if !disposed { configuredGeneration = generation }
    }
  }

  func dispose() {
    lock.lock()
    guard !disposed else {
      lock.unlock()
      return
    }
    disposed = true
    configuredGeneration = nil
    completionGeneration &+= 1
    scheduledDuration = 0
    scheduledByteCount = 0
    scheduledBufferCount = 0
    lock.unlock()
    output.dispose()
  }

  private func capacityResult(
    durationUs: Int64,
    byteCount: Int
  ) -> YlAudioEnqueueResult {
    let nextBytes = scheduledByteCount.addingReportingOverflow(max(0, byteCount))
    if nextBytes.overflow || nextBytes.partialValue > maxScheduledBytes {
      return .wouldExceedBytes
    }
    let nextDuration = scheduledDuration.addingReportingOverflow(max(0, durationUs))
    if nextDuration.overflow || nextDuration.partialValue > maxScheduledDurationUs {
      return .wouldExceedDuration
    }
    return .scheduled
  }

  private func complete(
    durationUs: Int64,
    byteCount: Int,
    completionGeneration: UInt64
  ) {
    lock.lock()
    guard !disposed, self.completionGeneration == completionGeneration else {
      lock.unlock()
      return
    }
    scheduledDuration = max(0, scheduledDuration - max(0, durationUs))
    scheduledByteCount = max(0, scheduledByteCount - max(0, byteCount))
    scheduledBufferCount = max(0, scheduledBufferCount - 1)
    lock.unlock()
  }

  deinit {
    dispose()
  }
}

final class YlAppleAACConverter: YlAudioPacketConverting {
  private var converter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?
  private var outputFormat: AVAudioFormat?

  func configure(stream: YlAudioStreamConfiguration) throws {
    guard stream.codec == .aac,
          stream.sampleRate > 0,
          (1...8).contains(stream.channelCount),
          !stream.magicCookie.isEmpty else {
      throw YlAudioImplementationError.invalidConfiguration
    }
    var description = AudioStreamBasicDescription(
      mSampleRate: stream.sampleRate,
      mFormatID: kAudioFormatMPEG4AAC,
      mFormatFlags: AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue),
      mBytesPerPacket: 0,
      mFramesPerPacket: 1024,
      mBytesPerFrame: 0,
      mChannelsPerFrame: UInt32(stream.channelCount),
      mBitsPerChannel: 0,
      mReserved: 0
    )
    guard let input = AVAudioFormat(streamDescription: &description),
          let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: stream.sampleRate,
            channels: AVAudioChannelCount(stream.channelCount),
            interleaved: true
          ),
          let converter = AVAudioConverter(from: input, to: output) else {
      throw YlAudioImplementationError.invalidConfiguration
    }
    converter.magicCookie = stream.magicCookie
    self.inputFormat = input
    self.outputFormat = output
    self.converter = converter
  }

  func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate {
    guard let outputFormat else {
      return YlAudioBufferEstimate(durationUs: 0, byteCount: 0)
    }
    let durationUs = packet.durationUs > 0
      ? packet.durationUs
      : Int64((1024 * 1_000_000 / outputFormat.sampleRate).rounded(.up))
    let frameCount = max(1, Int((Double(durationUs) * outputFormat.sampleRate / 1_000_000).rounded(.up)))
    return YlAudioBufferEstimate(
      durationUs: durationUs,
      byteCount: frameCount * Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
    )
  }

  func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer {
    guard let converter, let inputFormat, let outputFormat, !packet.data.isEmpty else {
      throw YlAudioImplementationError.notConfigured
    }
    let maximumPacketSize = UInt32(clamping: packet.data.count)
    let compressed = AVAudioCompressedBuffer(
      format: inputFormat,
      packetCapacity: 1,
      maximumPacketSize: Int(maximumPacketSize)
    )
    packet.data.withUnsafeBytes { bytes in
      if let source = bytes.baseAddress {
        memcpy(compressed.data, source, packet.data.count)
      }
    }
    compressed.byteLength = maximumPacketSize
    compressed.packetCount = 1
    compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
      mStartOffset: 0,
      mVariableFramesInPacket: 0,
      mDataByteSize: maximumPacketSize
    )

    let estimate = estimateOutput(for: packet)
    let bytesPerFrame = max(1, Int(outputFormat.streamDescription.pointee.mBytesPerFrame))
    let frameCapacity = AVAudioFrameCount(max(1024, estimate.byteCount / bytesPerFrame + 1024))
    guard let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
      throw YlAudioImplementationError.allocationFailed
    }
    var suppliedInput = false
    var conversionError: NSError?
    let status: AVAudioConverterOutputStatus = converter.convert(
      to: pcm,
      error: &conversionError
    ) { _, inputStatus in
      if suppliedInput {
        inputStatus.pointee = .noDataNow
        return nil
      }
      suppliedInput = true
      inputStatus.pointee = .haveData
      return compressed
    }
    guard status != AVAudioConverterOutputStatus.error, pcm.frameLength > 0 else {
      if let conversionError { throw conversionError }
      throw YlAudioImplementationError.conversionFailed
    }
    let durationUs = Int64(
      (Double(pcm.frameLength) * 1_000_000 / pcm.format.sampleRate).rounded(.towardZero)
    )
    return YlScheduledAudioBuffer(
      payload: pcm,
      ptsUs: packet.ptsUs,
      durationUs: durationUs,
      byteCount: Int(pcm.frameLength) * bytesPerFrame,
      generation: packet.generation
    )
  }
}

final class YlSystemAudioOutput: YlAudioOutputDriving {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let timePitch = AVAudioUnitTimePitch()
  private var configured = false
  private var disposed = false

  init() {
    engine.attach(player)
    engine.attach(timePitch)
  }

  var volume: Float {
    get { player.volume }
    set { player.volume = newValue }
  }

  var rate: Float {
    get { timePitch.rate }
    set { timePitch.rate = newValue }
  }

  var renderedAudioTime: YlRenderedAudioTime? {
    guard let nodeTime = player.lastRenderTime,
          let playerTime = player.playerTime(forNodeTime: nodeTime) else {
      return nil
    }
    return YlRenderedAudioTime(
      sampleTime: playerTime.sampleTime,
      sampleRate: playerTime.sampleRate
    )
  }

  func configure(sampleRate: Double, channelCount: Int) throws {
    guard !disposed,
          let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: true
          ) else {
      throw YlAudioImplementationError.invalidConfiguration
    }
    engine.stop()
    player.stop()
    engine.disconnectNodeOutput(player)
    engine.disconnectNodeOutput(timePitch)
    engine.connect(player, to: timePitch, format: format)
    engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    engine.prepare()
    configured = true
  }

  func schedule(_ buffer: YlScheduledAudioBuffer, completion: @escaping () -> Void) {
    guard configured, !disposed, let pcm = buffer.payload as? AVAudioPCMBuffer else {
      completion()
      return
    }
    player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { _ in
      completion()
    }
  }

  func play() throws {
    guard configured, !disposed else {
      throw YlAudioImplementationError.notConfigured
    }
    if !engine.isRunning {
      try engine.start()
    }
    player.play()
  }

  func pause() {
    player.pause()
  }

  func reset() {
    player.stop()
    player.reset()
  }

  func dispose() {
    guard !disposed else { return }
    disposed = true
    player.stop()
    engine.stop()
    engine.disconnectNodeOutput(player)
    engine.disconnectNodeOutput(timePitch)
    engine.detach(player)
    engine.detach(timePitch)
  }

  deinit {
    dispose()
  }
}

private enum YlAudioImplementationError: Error {
  case invalidConfiguration
  case notConfigured
  case allocationFailed
  case conversionFailed
}

private extension NSLock {
  func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
