import AudioToolbox
import AVFAudio
import Foundation
import YlFFmpegBridge

enum YlAudioFormatPolicy {
  static let usesInterleavedPCM = YlAppleCompatibility.current.usesInterleavedPCM

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
  case dts
  case ac3
  case eac3
  case flac
  case opus
  case vorbis
  case unsupported

  init(bridgeCodec: Int32) {
    switch Int(bridgeCodec) {
    case YLFCodecAAC: self = .aac
    case YLFCodecMP3: self = .mp3
    case YLFCodecDTS: self = .dts
    case YLFCodecAC3: self = .ac3
    case YLFCodecEAC3: self = .eac3
    case YLFCodecFLAC: self = .flac
    case YLFCodecOpus: self = .opus
    case YLFCodecVorbis: self = .vorbis
    default: self = .unsupported
    }
  }

  var label: String {
    switch self {
    case .aac: return "AAC"
    case .mp3: return "MP3"
    case .dts: return "DTS"
    case .ac3: return "AC-3"
    case .eac3: return "E-AC-3"
    case .flac: return "FLAC"
    case .opus: return "Opus"
    case .vorbis: return "Vorbis"
    case .unsupported: return "Compressed"
    }
  }
}

/// Resolve missing packet duration only for the inspected AAC-LC configuration.
/// AudioSpecificConfig's frameLengthFlag selects 1024 or 960 samples. Other
/// objects, absent bits and rate mismatches are not guessed for bounded timing.
struct YlAACLCConfiguration {
  let sampleRate: Int32
  let channelCount: Int32
  let framesPerPacket: Int
}

func ylInspectedAACLCConfiguration(cookie: Data) -> YlAACLCConfiguration? {
  var offset = 0
  func bits(_ count: Int) -> Int? {
    guard offset + count <= cookie.count * 8 else { return nil }
    var value = 0
    for _ in 0..<count {
      value = value * 2 + Int((cookie[cookie.startIndex + offset / 8] >> (7 - offset % 8)) & 1)
      offset += 1
    }
    return value
  }
  guard bits(5) == 2, let frequencyIndex = bits(4) else { return nil }
  let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
  let frequency: Int
  if frequencyIndex == 15 { guard let explicit = bits(24) else { return nil }; frequency = explicit }
  else { guard frequencyIndex < rates.count else { return nil }; frequency = rates[frequencyIndex] }
  guard frequency > 0, let channels = bits(4), (1...7).contains(channels),
        let shortFrame = bits(1), bits(1) == 0, bits(1) == 0 else { return nil }
  // Ordinary LC may carry an explicit backwards-compatible SBR sync extension.
  // Accept only a complete extension proving SBR absent; other objects, active
  // SBR/PS, truncation and nonzero/oversized trailing data are not plain LC.
  if cookie.count * 8 - offset > 7 {
    guard bits(11) == 0x2b7, bits(5) == 5, bits(1) == 0 else { return nil }
  }
  guard cookie.count * 8 - offset <= 7 else { return nil }
  while offset < cookie.count * 8 { guard bits(1) == 0 else { return nil } }
  return YlAACLCConfiguration(sampleRate: Int32(frequency), channelCount: Int32(channels == 7 ? 8 : channels),
    framesPerPacket: shortFrame == 0 ? 1024 : 960)
}

func ylBoundedAACPacketDurationUs(sampleRate: Double, cookie: Data) -> Int64? {
  guard sampleRate > 0, sampleRate.isFinite, let inspected = ylInspectedAACLCConfiguration(cookie: cookie),
        Double(inspected.sampleRate) == sampleRate else { return nil }
  return Int64((Double(inspected.framesPerPacket) * 1_000_000 / sampleRate).rounded(.up))
}

struct YlAudioStreamConfiguration: Equatable {
  let codec: YlAudioCodec
  let sampleRate: Double
  let channelCount: Int
  let magicCookie: Data
  let generation: UInt64
  var channelMask: UInt64 = 0
}

struct YlCompressedAudioPacket {
  var reservation: YlManagedBufferLedger.Token? = nil
  let data: Data
  let ptsUs: Int64
  let durationUs: Int64
  let generation: UInt64
  var skipSamples: UInt32 = 0
  var discardSamples: UInt32 = 0
  var presentationStartUs: Int64? = nil
}

struct YlAudioBufferEstimate: Equatable {
  let durationUs: Int64
  let byteCount: Int
}

struct YlScheduledAudioBuffer {
  var reservation: YlManagedBufferLedger.Token? = nil
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
  var pcmFormat: AVAudioFormat? { get }
  func configure(stream: YlAudioStreamConfiguration) throws
  func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate
  func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer?
  func reset()
}

extension YlAudioPacketConverting {
  var pcmFormat: AVAudioFormat? { nil }
  func reset() {}
}

protocol YlAudioOutputDriving: AnyObject {
  var supportsTerminalCompletion: Bool { get }
  var volume: Float { get set }
  var rate: Float { get set }
  var renderedAudioTime: YlRenderedAudioTime? { get }
  func configure(sampleRate: Double, channelCount: Int) throws
  func configure(format: AVAudioFormat) throws
  func schedule(_ buffer: YlScheduledAudioBuffer, completion: @escaping () -> Void)
  func schedule(_ buffer: YlScheduledAudioBuffer, callbacks: YlAudioOutputCallbacks)
  func schedule(_ buffer: YlScheduledAudioBuffer, mode: YlAudioOutputCompletionMode,
                callbacks: YlAudioOutputCallbacks)
  func play() throws
  func pause()
  func reset()
  func dispose()
}

extension YlAudioOutputDriving {
  // A legacy driver cannot supply independent rendered/terminal notifications.
  var supportsTerminalCompletion: Bool { false }

  func schedule(_ buffer: YlScheduledAudioBuffer, mode: YlAudioOutputCompletionMode,
                callbacks: YlAudioOutputCallbacks) {
    schedule(buffer, callbacks: callbacks)
  }

  // Existing outputs still signal both phases from their played-back callback.
  func schedule(_ buffer: YlScheduledAudioBuffer, callbacks: YlAudioOutputCallbacks) {
    schedule(buffer, completion: callbacks.playedBack)
  }

  func configure(format: AVAudioFormat) throws {
    try configure(sampleRate: format.sampleRate, channelCount: Int(format.channelCount))
  }
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
  var onOutputFailure: ((NativePlayerError) -> Void)?
  private static let targetScheduledWallClockDurationUs: Int64 = 1_000_000
  private let lock = NSLock()
  // Converter and output controls share an order across demux and UI threads.
  private let operations = NSRecursiveLock()
  private let maxScheduledDurationUs: Int64
  private let maxScheduledBytes: Int
  private let converter: YlAudioPacketConverting
  private let output: YlAudioOutputDriving
  private let completions = YlAudioCompletionGroup()
  private let bufferScope: YlManagedBufferScope?
  private let boundedPlan: YlBoundedBufferPlan?
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
  // Completion callbacks can arrive in bursts. Follow the player sample clock
  // between callbacks, capped by scheduled PCM so starvation cannot advance video.
  private var playedPositionUs: Int64?
  private var renderAnchor: (nodeUs: Double, mediaUs: Int64)?
  private var scheduledEndUs: Int64?
  private var lastNodeUs: Double = 0
  private var inputFinished = false
  private var silenceHostTimeUs: Int64?

  init(
    maxScheduledDurationUs: Int64 = 500_000,
    maxScheduledBytes: Int = 2 * 1024 * 1024,
    bufferScope: YlManagedBufferScope? = nil,
    boundedPlan: YlBoundedBufferPlan? = nil,
    converter: YlAudioPacketConverting = YlAppleCompressedAudioConverter(),
    output: YlAudioOutputDriving = YlSystemAudioOutput()
  ) {
    precondition(maxScheduledDurationUs >= 0)
    precondition(maxScheduledBytes >= 0)
    self.bufferScope = bufferScope
    self.boundedPlan = boundedPlan
    (converter as? YlAppleCompressedAudioConverter)?.bufferScope = bufferScope
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
      maxScheduledDurationUs: YlAppleCompatibility.current.audioDurationUs,
      maxScheduledBytes: bufferBudget.scheduledAudioBytes,
      bufferScope: bufferBudget.bufferScope, boundedPlan: bufferBudget.boundedPlan,
      converter: converter,
      output: output
    )
  }

  var scheduledDurationUs: Int64 {
    lock.withLock { scheduledDuration }
  }

  // Output completion is independent of duration statistics and render progress.
  // Flush/dispose invalidate this generation before clearing its pending count.
  var hasPendingPlayback: Bool {
    lock.withLock { scheduledBufferCount > 0 }
  }

  var scheduledBytes: Int {
    lock.withLock { scheduledByteCount }
  }

  var underrunCount: Int {
    lock.withLock { underruns }
  }

  var renderedAudioTime: YlRenderedAudioTime? {
    let generation = lock.withLock { completionGeneration }
    // Do not hold the state lock while consulting the native audio graph.
    let nodeUs = Self.nodeMicroseconds(output.renderedAudioTime)
    return lock.withLock {
      guard !disposed, playedPositionUs != nil,
            !(inputFinished && scheduledBufferCount == 0) else { return nil }
      if completionGeneration == generation {
        updatePlayedPosition(nodeUs: nodeUs)
      }
      return YlRenderedAudioTime(sampleTime: playedPositionUs!, sampleRate: 1_000_000)
    }
  }

  private static func nodeMicroseconds(_ time: YlRenderedAudioTime?) -> Double? {
    guard let time, time.sampleRate.isFinite, time.sampleRate > 0 else { return nil }
    let value = Double(time.sampleTime) * 1_000_000 / time.sampleRate
    return value.isFinite ? value : nil
  }

  // Caller holds lock. Player sample time already accounts for speed and pause.
  private func updatePlayedPosition(nodeUs: Double?) {
    if let nodeUs { lastNodeUs = nodeUs }
    guard playbackRequested, scheduledBufferCount > 0,
          let nodeUs, let renderAnchor, let scheduledEndUs else { return }
    let elapsed = max(0, nodeUs - renderAnchor.nodeUs)
    let remaining = max(0, scheduledEndUs - renderAnchor.mediaUs)
    let advance = elapsed >= Double(remaining) ? remaining : Int64(elapsed.rounded(.towardZero))
    let position = renderAnchor.mediaUs + advance
    playedPositionUs = max(playedPositionUs ?? 0, position)
  }

  func finishInput() {
    lock.withLock { inputFinished = true }
  }

  // An audio gap or video-only tail must not block demux behind a full video
  // queue. Fill only time covered by decoded video, never unbounded device time.
  func advanceSilence(through videoPTS: Int64?, atHostTimeUs now: Int64) {
    lock.withLock {
      defer { silenceHostTimeUs = playbackRequested ? now : nil }
      guard !disposed, playbackRequested, scheduledBufferCount == 0,
            let previousHost = silenceHostTimeUs, let videoPTS,
            let position = playedPositionUs, videoPTS > position else { return }
      let elapsed = max(0, now - previousHost)
      let advance = min(Double(videoPTS - position), Double(elapsed) * Double(playbackRate))
      playedPositionUs = position + Int64(advance.rounded(.towardZero))
    }
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
      if let format = converter.pcmFormat {
        try output.configure(format: format)
      } else {
        try output.configure(
          sampleRate: stream.sampleRate,
          channelCount: stream.codec == .dts ? 2 : stream.channelCount
        )
      }
    } catch {
      throw NativePlayerError(
        category: "decoderUnsupported",
        code: Self.unsupportedCode(stream.codec),
        message: "The \(Self.codecName(stream.codec)) audio configuration is unsupported.",
        diagnostic: YlAppleSafeDiagnostics.diagnostic(error)
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
    if let boundedPlan, estimate.durationUs > boundedPlan.maxDurationUs || estimate.byteCount > boundedPlan.maxBytes {
      throw YlManagedBufferLedger.unsupported()
    }
    guard estimatedCapacity == .scheduled else { return estimatedCapacity }

    // System converter accounts exact allocations itself. Test/custom converters
    // use their declared conservative estimate before entering conversion.
    let reservation = converter is YlAppleCompressedAudioConverter ? nil
      : bufferScope?.reserve(category: .scheduledAudio, bytes: max(0, estimate.byteCount))
    if !(converter is YlAppleCompressedAudioConverter), bufferScope != nil, reservation == nil { return .wouldExceedBytes }
    var buffer: YlScheduledAudioBuffer
    do {
      guard let converted = try converter.convert(packet: packet) else {
        return .buffered
      }
      buffer = converted
      if buffer.reservation == nil { buffer.reservation = reservation }
    } catch let error as NativePlayerError where ["policy.unsupported", "decoder.audio_opus_unsupported", "decoder.audio_opus_failed", "decoder.audio_vorbis_unsupported", "decoder.audio_vorbis_failed"].contains(error.code) {
      throw error
    } catch {
      let codecName = lock.withLock {
        Self.codecName(configuredCodec ?? .unsupported)
      }
      throw NativePlayerError(
        category: "decoderFailure",
        code: "decoder.audio_failed",
        message: "\(codecName) audio conversion failed.",
        diagnostic: YlAppleSafeDiagnostics.diagnostic(error)
      )
    }

    guard buffer.reservation?.mediaEpoch != nil || (buffer.reservation?.carryTiming(ptsUs: buffer.ptsUs, durationUs: buffer.durationUs, from: packet.reservation) ?? true) else {
      throw YlManagedBufferLedger.unsupported()
    }
    if !(converter is YlAppleCompressedAudioConverter) { packet.reservation?.endQueuedTiming() }
    let nodeUs = Self.nodeMicroseconds(output.renderedAudioTime)
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
    let shouldRestartOutput = YlAppleCompatibility.current.batchesAudioInput && playbackRequested && scheduledBufferCount == 0
    let startUs = max(0, buffer.ptsUs)
    let end = startUs.addingReportingOverflow(max(0, buffer.durationUs))
    updatePlayedPosition(nodeUs: nodeUs)
    var needsAnchor = scheduledBufferCount == 0
    if let renderAnchor, let scheduledEndUs {
      // Callback delivery can lag behind actual exhaustion of scheduled PCM,
      // including when refill happens while the player is paused.
      needsAnchor = needsAnchor || lastNodeUs - renderAnchor.nodeUs >= Double(scheduledEndUs - renderAnchor.mediaUs)
    }
    if needsAnchor {
      // Exclude silent node time on refill. Pause preserves the last node time;
      // only stop/reset makes a missing render timestamp mean sample zero.
      renderAnchor = (nodeUs ?? lastNodeUs, startUs)
      scheduledEndUs = startUs
    }
    scheduledEndUs = max(scheduledEndUs ?? startUs, end.overflow ? Int64.max : end.partialValue)
    scheduledDuration += max(0, buffer.durationUs)
    scheduledByteCount += max(0, buffer.byteCount)
    scheduledBufferCount += 1
    if playedPositionUs == nil { playedPositionUs = max(0, buffer.ptsUs) }
    if shouldRestartOutput { waitingForAudio = false }
    lock.unlock()

    // Only the resource phase captures PCM. Playback keeps scalar metadata and
    // the conservative reservation so early resource release cannot free the
    // global timing/byte budget while audio may still be downstream.
    let ptsUs = buffer.ptsUs
    let durationUs = buffer.durationUs
    let playbackReservation = buffer.reservation
    let callbacks = completions.makeCallbacks(releaseResources: { [weak self] in
      self?.retireResources(byteCount: buffer.byteCount, completionGeneration: token)
      withExtendedLifetime(buffer) {}
    }, completePlayback: { [weak self] in
      playbackReservation?.endQueuedTiming()
      self?.completePlayback(ptsUs: ptsUs, durationUs: durationUs, completionGeneration: token)
    })
    output.schedule(buffer, callbacks: callbacks)
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
    if scheduledBufferCount == 0, !waitingForAudio || !YlAppleCompatibility.current.batchesAudioInput {
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
      let failure = NativePlayerError(
        category: "render",
        code: "render.audio_engine_failed",
        message: "The native audio engine could not start.",
        diagnostic: YlAppleSafeDiagnostics.diagnostic(error)
      )
      onOutputFailure?(failure)
      throw failure
    }
  }

  func pause() {
    operations.lock()
    defer { operations.unlock() }
    // playerTime(forNodeTime:) becomes nil after the player is paused.
    let nodeUs = Self.nodeMicroseconds(output.renderedAudioTime)
    lock.withLock {
      updatePlayedPosition(nodeUs: nodeUs)
      playbackRequested = false
      waitingForAudio = false
      silenceHostTimeUs = nil
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
    playedPositionUs = nil
    renderAnchor = nil
    scheduledEndUs = nil
    lastNodeUs = 0
    silenceHostTimeUs = nil
    inputFinished = false
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
    playedPositionUs = nil
    renderAnchor = nil
    scheduledEndUs = nil
    lastNodeUs = 0
    silenceHostTimeUs = nil
    inputFinished = false
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
    let rateAdjustedDurationLimit = boundedPlan?.maxDurationUs ?? Int64(
      (Double(maxScheduledDurationUs) * Double(YlAppleCompatibility.current.scalesAudioDuration ? playbackRate : 1)).rounded(.up)
    )
    if nextDuration.overflow || nextDuration.partialValue > rateAdjustedDurationLimit {
      return .wouldExceedDuration
    }
    return .scheduled
  }

  private static func codecName(_ codec: YlAudioCodec) -> String {
    codec.label
  }

  private static func unsupportedCode(_ codec: YlAudioCodec) -> String {
    switch codec {
    case .aac: return "decoder.audio_aac_unsupported"
    case .mp3: return "decoder.audio_mp3_unsupported"
    case .dts: return "decoder.audio_dts_unsupported"
    case .ac3: return "decoder.audio_ac3_unsupported"
    case .eac3: return "decoder.audio_eac3_unsupported"
    case .flac: return "decoder.audio_flac_unsupported"
    case .opus: return "decoder.audio_opus_unsupported"
    case .vorbis: return "decoder.audio_vorbis_unsupported"
    case .unsupported: return "decoder.audio_unsupported"
    }
  }

  private func retireResources(byteCount: Int, completionGeneration: UInt64) {
    lock.withLock {
      guard !disposed, self.completionGeneration == completionGeneration else { return }
      scheduledByteCount = max(0, scheduledByteCount - max(0, byteCount))
    }
  }

  private func completePlayback(
    ptsUs: Int64,
    durationUs: Int64,
    completionGeneration: UInt64
  ) {
    lock.lock()
    guard !disposed, self.completionGeneration == completionGeneration else {
      lock.unlock()
      return
    }
    updatePositionAfterPlayback(ptsUs: ptsUs, durationUs: durationUs)
    retirePlayback(durationUs: durationUs)
    lock.unlock()
  }

  // Caller holds the state lock and has validated the completion generation.
  private func updatePositionAfterPlayback(ptsUs: Int64, durationUs: Int64) {
    guard playbackRequested else { return }
    let end = max(0, ptsUs).addingReportingOverflow(max(0, durationUs))
    if !end.overflow { playedPositionUs = max(playedPositionUs ?? 0, end.partialValue) }
  }

  // Playback duration/count remain pending until output completion, even if PCM
  // resources were released earlier. This phase owns underrun/drain decisions.
  private func retirePlayback(durationUs: Int64) {
    scheduledDuration = max(0, scheduledDuration - max(0, durationUs))
    scheduledBufferCount = max(0, scheduledBufferCount - 1)
    if scheduledBufferCount == 0 { silenceHostTimeUs = nil }
    if YlAppleCompatibility.current.batchesAudioInput, scheduledBufferCount == 0, playbackRequested, !waitingForAudio {
      underruns += 1
      waitingForAudio = true
    }
  }

  deinit {
    dispose()
  }
}

final class YlAppleCompressedAudioConverter: YlAudioPacketConverting {
  private var dtsConverter: YlDtsAudioConverter?
  private var opusConverter: YlOpusAudioConverter?
  private var vorbisConverter: YlVorbisAudioConverter?
  var bufferScope: YlManagedBufferScope?
  private var converter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?
  private var outputFormat: AVAudioFormat?
  var pcmFormat: AVAudioFormat? { vorbisConverter?.pcmFormat ?? opusConverter?.pcmFormat ?? (dtsConverter == nil ? outputFormat : nil) }
  private var framesPerPacket: UInt32 = 0
  private var batchesInput = YlAppleCompatibility.current.batchesAudioInput
  private var variablePacketFrames = false
  private var flacConfiguration: YlFLACConfiguration?
  private var pendingPackets: [YlCompressedAudioPacket] = []
  private var pendingOutputPackets: [YlCompressedAudioPacket] = []

  func configure(stream: YlAudioStreamConfiguration) throws {
    dtsConverter = nil
    opusConverter = nil
    vorbisConverter = nil
    flacConfiguration = nil
    if stream.codec == .vorbis {
      let vorbis = YlVorbisAudioConverter()
      vorbis.bufferScope = bufferScope
      try vorbis.configure(stream: stream)
      vorbisConverter = vorbis
      return
    }
    if stream.codec == .opus {
      let opus = YlOpusAudioConverter()
      opus.bufferScope = bufferScope
      try opus.configure(stream: stream)
      opusConverter = opus
      return
    }
    if stream.codec == .dts {
      let dts = YlDtsAudioConverter()
      dts.bufferScope = bufferScope
      try dts.configure(stream: stream)
      dtsConverter = dts
      return
    }
    let isDolby = stream.codec == .ac3 || stream.codec == .eac3
    let flac = stream.codec == .flac ? YlFLACConfiguration(stream: stream) : nil
    guard stream.codec == .aac || stream.codec == .mp3 || isDolby || flac != nil,
          stream.sampleRate > 0,
          (1...8).contains(stream.channelCount),
          stream.codec != .aac || !stream.magicCookie.isEmpty else {
      throw YlAudioImplementationError.invalidConfiguration
    }
    let formatID: AudioFormatID
    switch stream.codec {
    case .aac: formatID = kAudioFormatMPEG4AAC
    case .mp3: formatID = kAudioFormatMPEGLayer3
    case .ac3: formatID = kAudioFormatAC3
    case .eac3: formatID = kAudioFormatEnhancedAC3
    case .flac: formatID = kAudioFormatFLAC
    default: throw YlAudioImplementationError.invalidConfiguration
    }
    let formatFlags: AudioFormatFlags = flac?.formatFlags ?? (stream.codec == .aac && !YlAppleCompatibility.current.batchesAudioInput
      ? AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue) : 0)
    let inputFramesPerPacket: UInt32 = flac?.maxBlockSize ?? (isDolby ? 1536 : (stream.codec == .aac ? 1024 : 1152))
    let magicCookie = flac?.coreAudioCookie ?? (stream.codec == .aac && YlAppleCompatibility.current.batchesAudioInput
      ? Self.aacMagicCookie(audioSpecificConfig: stream.magicCookie)
      : stream.magicCookie)
    var description = AudioStreamBasicDescription(
      mSampleRate: stream.sampleRate,
      mFormatID: formatID,
      mFormatFlags: formatFlags,
      mBytesPerPacket: 0,
      mFramesPerPacket: stream.codec == .eac3 ? 0 : inputFramesPerPacket,
      mBytesPerFrame: 0,
      mChannelsPerFrame: UInt32(stream.channelCount),
      mBitsPerChannel: 0,
      mReserved: 0
    )
    if stream.codec == .aac && YlAppleCompatibility.current.batchesAudioInput {
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
    let layout: AVAudioChannelLayout?
    let output: AVAudioFormat?
    if isDolby {
      let speakers = try Self.dolbyChannelLayout(mask: stream.channelMask, channelCount: stream.channelCount)
      layout = speakers
      output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
        sampleRate: stream.sampleRate, interleaved: YlAudioFormatPolicy.usesInterleavedPCM,
        channelLayout: speakers)
    } else if stream.channelCount > 2 {
      // A channel count alone is insufficient for surround AVAudioFormats.
      // Read the encoded speaker order from ESDS, including any AAC PCE, and
      // preserve that layout through PCM conversion and the output graph.
      guard stream.codec == .aac else { throw YlAudioImplementationError.invalidConfiguration }
      let surround = try Self.aacChannelLayout(
        audioSpecificConfig: stream.magicCookie, channelCount: stream.channelCount)
      layout = surround
      output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
        sampleRate: stream.sampleRate, interleaved: YlAudioFormatPolicy.usesInterleavedPCM,
        channelLayout: surround)
    } else {
      layout = nil
      output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
        sampleRate: stream.sampleRate, channels: AVAudioChannelCount(stream.channelCount),
        interleaved: YlAudioFormatPolicy.usesInterleavedPCM)
    }
    guard let input = AVAudioFormat(streamDescription: &description, channelLayout: layout),
          let output,
          let converter = AVAudioConverter(from: input, to: output) else {
      throw YlAudioImplementationError.invalidConfiguration
    }
    if stream.codec == .aac || flac != nil {
      converter.magicCookie = magicCookie
    }
    // Dolby and FLAC frames are self-contained; preserve one packet's timing per
    // output instead of applying the macOS AAC look-ahead batching policy.
    batchesInput = YlAppleCompatibility.current.batchesAudioInput && !isDolby && flac == nil
    variablePacketFrames = stream.codec == .eac3 || flac != nil
    if isDolby || flac != nil { converter.primeMethod = .none }
    flacConfiguration = flac
    self.inputFormat = input
    self.outputFormat = output
    self.converter = converter
    framesPerPacket = inputFramesPerPacket
    pendingPackets.removeAll(keepingCapacity: true)
    pendingOutputPackets.removeAll(keepingCapacity: true)
  }

  func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate {
    if let vorbisConverter { return vorbisConverter.estimateOutput(for: packet) }
    if let opusConverter { return opusConverter.estimateOutput(for: packet) }
    if let dtsConverter { return dtsConverter.estimateOutput(for: packet) }
    guard let outputFormat else {
      return YlAudioBufferEstimate(durationUs: 0, byteCount: 0)
    }
    let flacFrames = flacConfiguration?.frameCount(packet: packet.data)
    let durationUs = flacConfiguration != nil
      ? Int64((Double(flacFrames ?? 0) * 1_000_000 / outputFormat.sampleRate).rounded(.up))
      : packet.durationUs > 0
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
    if let vorbisConverter { return try vorbisConverter.convert(packet: packet) }
    if let opusConverter { return try opusConverter.convert(packet: packet) }
    if let dtsConverter { return try dtsConverter.convert(packet: packet) }
    guard let converter, let inputFormat, let outputFormat, !packet.data.isEmpty else {
      throw YlAudioImplementationError.notConfigured
    }
    let flacFrames = flacConfiguration?.frameCount(packet: packet.data)
    if flacConfiguration != nil, flacFrames == nil {
      throw YlAudioImplementationError.conversionFailed
    }
    pendingPackets.append(packet)
    let packetBatch = Array(pendingPackets.prefix(batchesInput ? 2 : 1))
    let copiedBytes = packetBatch.reduce(0) { $0 + $1.data.count }
    let copyReservation = try bufferScope?.require(category: .compressedPackets, bytes: copiedBytes)
    defer { withExtendedLifetime(copyReservation) {} }
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
        mVariableFramesInPacket: flacFrames ?? (batchesInput || variablePacketFrames ? 0 : framesPerPacket),
        mDataByteSize: packetSize
      )
      compressed.byteLength = packetSize
      compressed.packetCount = 1
      return compressed
    }

    let bytesPerFrame = max(1, Int(outputFormat.streamDescription.pointee.mBytesPerFrame))
    let estimate = estimateOutput(for: packet)
    let bytesPerSampleFrame = YlAudioFormatPolicy.byteCount(
      frameCount: 1, bytesPerFrame: bytesPerFrame,
      channelCount: Int(outputFormat.channelCount)
    )
    let frameCapacity = flacFrames ?? (batchesInput
      ? AVAudioFrameCount(framesPerPacket)
      : AVAudioFrameCount(max(Int(framesPerPacket), estimate.byteCount / bytesPerSampleFrame + Int(framesPerPacket))))
    let allocatedBytes = YlAudioFormatPolicy.byteCount(frameCount: Int(frameCapacity), bytesPerFrame: bytesPerFrame,
      channelCount: Int(outputFormat.channelCount))
    let pcmReservation = try bufferScope?.require(category: .scheduledAudio, bytes: allocatedBytes)
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
    // Input callbacks have returned: those compressed samples are consumed.
    // Retained bookkeeping Data remains byte-charged, but no longer represents
    // media queued for input. PCM gets its own interval below.
    for consumed in packetBatch.prefix(nextInputIndex) { consumed.reservation?.endQueuedTiming() }
    pendingOutputPackets.append(contentsOf: packetBatch.prefix(nextInputIndex))
    pendingPackets.removeFirst(nextInputIndex)
    if batchesInput, status == .inputRanDry, pcm.frameLength == 0 {
      return nil
    }
    guard status != AVAudioConverterOutputStatus.error, pcm.frameLength > 0 else {
      if let conversionError { throw conversionError }
      throw YlAudioImplementationError.conversionFailed
    }
    if let flacFrames, pcm.frameLength != flacFrames || nextInputIndex != 1 {
      throw YlAudioImplementationError.conversionFailed
    }
    guard !pendingOutputPackets.isEmpty else {
      throw YlAudioImplementationError.conversionFailed
    }
    let outputPacket = pendingOutputPackets.removeFirst()
    let durationUs = Int64(
      (Double(pcm.frameLength) * 1_000_000 / pcm.format.sampleRate).rounded(.towardZero)
    )
    guard pcmReservation?.carryTiming(ptsUs: outputPacket.ptsUs, durationUs: durationUs, from: outputPacket.reservation) ?? true else {
      throw YlManagedBufferLedger.unsupported("PCM timing pts=\(outputPacket.ptsUs) duration=\(durationUs)")
    }
    outputPacket.reservation?.endQueuedTiming()
    return YlScheduledAudioBuffer(
      reservation: pcmReservation,
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
    dtsConverter?.reset()
    opusConverter?.reset()
    vorbisConverter?.reset()
    converter?.reset()
    pendingPackets.removeAll(keepingCapacity: true)
    pendingOutputPackets.removeAll(keepingCapacity: true)
  }

  private static func dolbyChannelLayout(mask: UInt64, channelCount: Int) throws -> AVAudioChannelLayout {
    // FFmpeg's native mask identifies speakers, not just a channel count.
    // Keep that order in explicit CoreAudio descriptions so center/LFE and
    // side/back surrounds cannot be silently interchanged.
    let labels: [AudioChannelLabel] = [
      kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
      kAudioChannelLabel_LFEScreen, kAudioChannelLabel_RearSurroundLeft,
      kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_LeftCenter,
      kAudioChannelLabel_RightCenter, kAudioChannelLabel_CenterSurround,
      kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
    ]
    guard mask != 0, mask >> labels.count == 0, mask.nonzeroBitCount == channelCount else {
      throw YlAudioImplementationError.invalidConfiguration
    }
    let selected = labels.enumerated().compactMap { index, label in
      mask & (UInt64(1) << index) != 0 ? label : nil
    }
    let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
    let size = offset + selected.count * MemoryLayout<AudioChannelDescription>.stride
    let storage = UnsafeMutableRawPointer.allocate(byteCount: size,
      alignment: MemoryLayout<AudioChannelLayout>.alignment)
    defer { storage.deallocate() }
    storage.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    let layout = storage.assumingMemoryBound(to: AudioChannelLayout.self)
    layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
    layout.pointee.mNumberChannelDescriptions = UInt32(selected.count)
    let descriptions = storage.advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
    for (index, label) in selected.enumerated() { descriptions[index].mChannelLabel = label }
    return AVAudioChannelLayout(layout: layout)
  }

  private static func aacChannelLayout(
    audioSpecificConfig: Data, channelCount: Int
  ) throws -> AVAudioChannelLayout {
    let cookie = aacMagicCookie(audioSpecificConfig: audioSpecificConfig)
    return try cookie.withUnsafeBytes { bytes in
      var size: UInt32 = 0
      guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutFromESDS,
        UInt32(bytes.count), bytes.baseAddress, &size) == noErr,
        size >= MemoryLayout<AudioChannelLayout>.size, size <= 4096 else {
        throw YlAudioImplementationError.invalidConfiguration
      }
      let storage = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
      defer { storage.deallocate() }
      guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutFromESDS,
        UInt32(bytes.count), bytes.baseAddress, &size, storage) == noErr else {
        throw YlAudioImplementationError.invalidConfiguration
      }
      let layout = AVAudioChannelLayout(layout: storage.assumingMemoryBound(to: AudioChannelLayout.self))
      guard layout.channelCount == channelCount else {
        throw YlAudioImplementationError.invalidConfiguration
      }
      return layout
    }
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
  var supportsTerminalCompletion: Bool { true }
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let timePitch = AVAudioUnitTimePitch()
  private var configured = false
  private var disposed = false

  init() {
    engine.attach(player)
    engine.attach(timePitch)
    if YlAppleCompatibility.current.batchesAudioInput {
      timePitch.pitch = 0
      timePitch.overlap = 8
    }
  }

  var volume: Float {
    get { player.volume }
    set { player.volume = newValue }
  }

  var rate: Float {
    get { timePitch.rate }
    set {
      timePitch.rate = newValue
      timePitch.bypass = newValue == 1
    }
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
    try configure(format: format)
  }

  func configure(format: AVAudioFormat) throws {
    guard !disposed else { throw YlAudioImplementationError.invalidConfiguration }
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

  func schedule(_ buffer: YlScheduledAudioBuffer, mode: YlAudioOutputCompletionMode,
                callbacks: YlAudioOutputCallbacks) {
    guard configured, !disposed, let pcm = buffer.payload as? AVAudioPCMBuffer else {
      // Nothing was submitted: retire the owner without inventing playback.
      // Candidate callers must fence invalidated output separately.
      callbacks.resourcesReleased()
      return
    }
    let callbackType: AVAudioPlayerNodeCompletionCallbackType
    let completion: () -> Void
    switch mode {
    case .renderedResource:
      callbackType = .dataRendered
      completion = callbacks.resourcesReleased
    case .playedBack:
      callbackType = .dataPlayedBack
      completion = callbacks.playedBack
    }
    // Forward on the native callback thread. The caller owns serialization;
    // this adapter must not synchronously wait for renderer/control locks.
    player.scheduleBuffer(pcm, completionCallbackType: callbackType) { _ in
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
