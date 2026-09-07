import AudioToolbox
import AVFAudio
import Foundation

enum YlAudioFormatPolicy {
  static let usesInterleavedPCM = false

  static func byteCount(
    frameCount: Int,
    bytesPerFrame: Int,
    channelCount: Int
  ) -> Int {
    frameCount * bytesPerFrame * (usesInterleavedPCM ? 1 : channelCount)
  }
}

enum YlAudioCodec: Equatable {
  case aac
  case mp3
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
  case buffered
  case wouldExceedDuration
  case wouldExceedBytes
  case staleGeneration
}

protocol YlAudioPacketConverting: AnyObject {
  func configure(stream: YlAudioStreamConfiguration) throws
  func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate
  func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer?
  func reset()
}

extension YlAudioPacketConverting {
  func reset() {}
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
  private static let targetScheduledWallClockDurationUs: Int64 = 1_000_000
  private let lock = NSLock()
  // Converter and output controls share an order across demux and UI threads.
  private let operations = NSRecursiveLock()
  private let maxScheduledDurationUs: Int64
  private let maxScheduledBytes: Int
  private let converter: YlAudioPacketConverting
  private let output: YlAudioOutputDriving
  private var configuredGeneration: UInt64?
  private var configuredCodec: YlAudioCodec?
  private var completionGeneration: UInt64 = 0
  private var scheduledBufferCount = 0
  private var disposed = false
  private var scheduledDuration = Int64(0)
  private var scheduledByteCount = 0
  private var underruns = 0
  private var playbackRate: Float = 1
  private var playbackRequested = false
  private var waitingForAudio = false

  init(
    maxScheduledDurationUs: Int64 = 500_000,
    maxScheduledBytes: Int = 2 * 1024 * 1024,
    converter: YlAudioPacketConverting = YlAppleCompressedAudioConverter(),
    output: YlAudioOutputDriving = YlSystemAudioOutput()
  ) {
    precondition(maxScheduledDurationUs >= 0)
    precondition(maxScheduledBytes >= 0)
    self.maxScheduledDurationUs = maxScheduledDurationUs
    self.maxScheduledBytes = maxScheduledBytes
    self.converter = converter
    self.output = output
  }

  convenience init(
    bufferBudget: YlFallbackBufferBudget,
    converter: YlAudioPacketConverting = YlAppleCompressedAudioConverter(),
    output: YlAudioOutputDriving = YlSystemAudioOutput()
  ) {
    self.init(
      maxScheduledDurationUs: Self.targetScheduledWallClockDurationUs,
      maxScheduledBytes: bufferBudget.scheduledAudioBytes,
      converter: converter,
      output: output
    )
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
    operations.lock()
    defer { operations.unlock() }
    return output.renderedAudioTime
  }

  func configure(stream: YlAudioStreamConfiguration) throws {
    operations.lock()
    defer { operations.unlock() }
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
        category: "decoderUnsupported",
        code: Self.unsupportedCode(stream.codec),
        message: "The \(Self.codecName(stream.codec)) audio configuration is unsupported.",
        diagnostic: String(describing: error)
      )
    }
    flush()
    lock.lock()
    configuredGeneration = stream.generation
    configuredCodec = stream.codec
    lock.unlock()
  }

  func enqueue(packet: YlCompressedAudioPacket) throws -> YlAudioEnqueueResult {
    operations.lock()
    defer { operations.unlock() }
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
      guard let converted = try converter.convert(packet: packet) else {
        return .buffered
      }
      buffer = converted
    } catch {
      let codecName = lock.withLock {
        Self.codecName(configuredCodec ?? .unsupported)
      }
      throw NativePlayerError(
        category: "decoderFailure",
        code: "decoder.audio_failed",
        message: "\(codecName) audio conversion failed.",
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
    let shouldRestartOutput = playbackRequested && scheduledBufferCount == 0
    scheduledDuration += max(0, buffer.durationUs)
    scheduledByteCount += max(0, buffer.byteCount)
    scheduledBufferCount += 1
    if shouldRestartOutput { waitingForAudio = false }
    lock.unlock()

    output.schedule(buffer) { [weak self] in
      self?.complete(
        durationUs: buffer.durationUs,
        byteCount: buffer.byteCount,
        completionGeneration: token
      )
    }
    if shouldRestartOutput, lock.withLock({
      !disposed && playbackRequested && completionGeneration == token
    }) {
      try startOutput()
    }
    return .scheduled
  }

  func play() throws {
    operations.lock()
    defer { operations.unlock() }
    lock.lock()
    guard !disposed else {
      lock.unlock()
      return
    }
    playbackRequested = true
    if scheduledBufferCount == 0, !waitingForAudio {
      underruns += 1
      waitingForAudio = true
    }
    lock.unlock()
    try startOutput()
  }

  private func startOutput() throws {
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
    operations.lock()
    defer { operations.unlock() }
    lock.withLock {
      playbackRequested = false
      waitingForAudio = false
    }
    output.pause()
  }

  func seek(to positionUs: Int64) {
    operations.lock()
    defer { operations.unlock() }
    _ = positionUs
    flush()
  }

  func setVolume(_ volume: Float) {
    operations.lock()
    defer { operations.unlock() }
    output.volume = min(max(volume, 0), 1)
  }

  func setRate(_ rate: Float) {
    operations.lock()
    defer { operations.unlock() }
    let clampedRate = min(max(rate, 0.25), 4)
    lock.withLock { playbackRate = clampedRate }
    output.rate = clampedRate
  }

  func flush() {
    operations.lock()
    defer { operations.unlock() }
    lock.lock()
    guard !disposed else {
      lock.unlock()
      return
    }
    completionGeneration &+= 1
    scheduledDuration = 0
    scheduledByteCount = 0
    scheduledBufferCount = 0
    waitingForAudio = playbackRequested
    lock.unlock()
    converter.reset()
    output.reset()
  }

  func reset(generation: UInt64) {
    operations.lock()
    defer { operations.unlock() }
    flush()
    lock.withLock {
      if !disposed { configuredGeneration = generation }
    }
  }

  func dispose() {
    operations.lock()
    defer { operations.unlock() }
    lock.lock()
    guard !disposed else {
      lock.unlock()
      return
    }
    disposed = true
    configuredGeneration = nil
    configuredCodec = nil
    completionGeneration &+= 1
    scheduledDuration = 0
    scheduledByteCount = 0
    scheduledBufferCount = 0
    playbackRequested = false
    waitingForAudio = false
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
    let rateAdjustedDurationLimit = Int64(
      (Double(maxScheduledDurationUs) * Double(playbackRate)).rounded(.up)
    )
    if nextDuration.overflow || nextDuration.partialValue > rateAdjustedDurationLimit {
      return .wouldExceedDuration
    }
    return .scheduled
  }

  private static func codecName(_ codec: YlAudioCodec) -> String {
    switch codec {
    case .aac: return "AAC"
    case .mp3: return "MP3"
    case .unsupported: return "Compressed"
    }
  }

  private static func unsupportedCode(_ codec: YlAudioCodec) -> String {
    codec == .mp3
      ? "decoder.audio_mp3_unsupported"
      : "decoder.audio_aac_unsupported"
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
    if scheduledBufferCount == 0, playbackRequested, !waitingForAudio {
      underruns += 1
      waitingForAudio = true
    }
    lock.unlock()
  }

  deinit {
    dispose()
  }
}

final class YlAppleCompressedAudioConverter: YlAudioPacketConverting {
  private var converter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?
  private var outputFormat: AVAudioFormat?
  private var framesPerPacket: UInt32 = 0
  private var pendingPackets: [YlCompressedAudioPacket] = []
  private var pendingOutputPackets: [YlCompressedAudioPacket] = []

  func configure(stream: YlAudioStreamConfiguration) throws {
    guard stream.codec == .aac || stream.codec == .mp3,
          stream.sampleRate > 0,
          (1...8).contains(stream.channelCount),
          stream.codec != .aac || !stream.magicCookie.isEmpty else {
      throw YlAudioImplementationError.invalidConfiguration
    }
    let formatID: AudioFormatID = stream.codec == .aac
      ? kAudioFormatMPEG4AAC
      : kAudioFormatMPEGLayer3
    let formatFlags: AudioFormatFlags = 0
    let inputFramesPerPacket: UInt32 = stream.codec == .aac ? 1024 : 1152
    let magicCookie = stream.codec == .aac
      ? Self.aacMagicCookie(audioSpecificConfig: stream.magicCookie)
      : stream.magicCookie
    var description = AudioStreamBasicDescription(
      mSampleRate: stream.sampleRate,
      mFormatID: formatID,
      mFormatFlags: formatFlags,
      mBytesPerPacket: 0,
      mFramesPerPacket: inputFramesPerPacket,
      mBytesPerFrame: 0,
      mChannelsPerFrame: UInt32(stream.channelCount),
      mBitsPerChannel: 0,
      mReserved: 0
    )
    if stream.codec == .aac {
      var descriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      let formatResult = magicCookie.withUnsafeBytes { cookie in
        AudioFormatGetProperty(
          kAudioFormatProperty_FormatInfo,
          UInt32(clamping: cookie.count),
          cookie.baseAddress,
          &descriptionSize,
          &description
        )
      }
      guard formatResult == noErr else {
        throw YlAudioImplementationError.invalidConfiguration
      }
    }
    guard let input = AVAudioFormat(streamDescription: &description),
          let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: stream.sampleRate,
            channels: AVAudioChannelCount(stream.channelCount),
            interleaved: YlAudioFormatPolicy.usesInterleavedPCM
          ),
          let converter = AVAudioConverter(from: input, to: output) else {
      throw YlAudioImplementationError.invalidConfiguration
    }
    if stream.codec == .aac {
      converter.magicCookie = magicCookie
    }
    self.inputFormat = input
    self.outputFormat = output
    self.converter = converter
    framesPerPacket = inputFramesPerPacket
    pendingPackets.removeAll(keepingCapacity: true)
    pendingOutputPackets.removeAll(keepingCapacity: true)
  }

  func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate {
    guard let outputFormat else {
      return YlAudioBufferEstimate(durationUs: 0, byteCount: 0)
    }
    let durationUs = packet.durationUs > 0
      ? packet.durationUs
      : Int64(
        (Double(framesPerPacket) * 1_000_000 / outputFormat.sampleRate).rounded(.up)
      )
    let frameCount = max(1, Int((Double(durationUs) * outputFormat.sampleRate / 1_000_000).rounded(.up)))
    return YlAudioBufferEstimate(
      durationUs: durationUs,
      byteCount: YlAudioFormatPolicy.byteCount(
        frameCount: frameCount,
        bytesPerFrame: Int(outputFormat.streamDescription.pointee.mBytesPerFrame),
        channelCount: Int(outputFormat.channelCount)
      )
    )
  }

  func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer? {
    guard let converter, let inputFormat, let outputFormat, !packet.data.isEmpty else {
      throw YlAudioImplementationError.notConfigured
    }
    pendingPackets.append(packet)
    let packetBatch = Array(pendingPackets.prefix(2))
    let compressedBuffers = packetBatch.map { queuedPacket in
      let packetSize = UInt32(clamping: queuedPacket.data.count)
      let compressed = AVAudioCompressedBuffer(
        format: inputFormat,
        packetCapacity: 1,
        maximumPacketSize: Int(packetSize)
      )
      queuedPacket.data.withUnsafeBytes { bytes in
        if let source = bytes.baseAddress {
          memcpy(compressed.data, source, queuedPacket.data.count)
        }
      }
      compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
        mStartOffset: 0,
        mVariableFramesInPacket: 0,
        mDataByteSize: packetSize
      )
      compressed.byteLength = packetSize
      compressed.packetCount = 1
      return compressed
    }

    let bytesPerFrame = max(1, Int(outputFormat.streamDescription.pointee.mBytesPerFrame))
    let frameCapacity = AVAudioFrameCount(framesPerPacket)
    guard let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
      throw YlAudioImplementationError.allocationFailed
    }
    var nextInputIndex = 0
    var conversionError: NSError?
    let status: AVAudioConverterOutputStatus = converter.convert(
      to: pcm,
      error: &conversionError
    ) { _, inputStatus in
      guard nextInputIndex < compressedBuffers.count else {
        inputStatus.pointee = .noDataNow
        return nil
      }
      let input = compressedBuffers[nextInputIndex]
      nextInputIndex += 1
      inputStatus.pointee = .haveData
      return input
    }
    pendingOutputPackets.append(contentsOf: packetBatch.prefix(nextInputIndex))
    pendingPackets.removeFirst(nextInputIndex)
    if status == .inputRanDry, pcm.frameLength == 0 {
      return nil
    }
    guard status != AVAudioConverterOutputStatus.error, pcm.frameLength > 0 else {
      if let conversionError { throw conversionError }
      throw YlAudioImplementationError.conversionFailed
    }
    guard !pendingOutputPackets.isEmpty else {
      throw YlAudioImplementationError.conversionFailed
    }
    let outputPacket = pendingOutputPackets.removeFirst()
    let durationUs = Int64(
      (Double(pcm.frameLength) * 1_000_000 / pcm.format.sampleRate).rounded(.towardZero)
    )
    return YlScheduledAudioBuffer(
      payload: pcm,
      ptsUs: outputPacket.ptsUs,
      durationUs: durationUs,
      byteCount: YlAudioFormatPolicy.byteCount(
        frameCount: Int(pcm.frameLength),
        bytesPerFrame: bytesPerFrame,
        channelCount: Int(pcm.format.channelCount)
      ),
      generation: outputPacket.generation
    )
  }

  func reset() {
    converter?.reset()
    pendingPackets.removeAll(keepingCapacity: true)
    pendingOutputPackets.removeAll(keepingCapacity: true)
  }

  private static func aacMagicCookie(audioSpecificConfig: Data) -> Data {
    var cookie = Data()
    func appendDescriptor(tag: UInt8, payloadSize: Int) {
      cookie.append(tag)
      for shift in stride(from: 21, through: 7, by: -7) {
        cookie.append(UInt8((payloadSize >> shift) & 0x7F) | 0x80)
      }
      cookie.append(UInt8(payloadSize & 0x7F))
    }

    appendDescriptor(
      tag: 0x03,
      payloadSize: 3 + 5 + 13 + 5 + audioSpecificConfig.count
    )
    cookie.append(contentsOf: [0x00, 0x00, 0x00])
    appendDescriptor(tag: 0x04, payloadSize: 13 + 5 + audioSpecificConfig.count)
    cookie.append(contentsOf: [
      0x40, 0x15,
      0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00,
    ])
    appendDescriptor(tag: 0x05, payloadSize: audioSpecificConfig.count)
    cookie.append(audioSpecificConfig)
    return cookie
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
    timePitch.pitch = 0
    timePitch.overlap = 8
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
          let playerTime = player.playerTime(forNodeTime: nodeTime),
          playerTime.sampleRate > 0 else {
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
            interleaved: YlAudioFormatPolicy.usesInterleavedPCM
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
