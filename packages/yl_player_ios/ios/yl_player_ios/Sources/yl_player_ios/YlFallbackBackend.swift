import AVFoundation
import CoreMedia
import CoreVideo
import Flutter
import QuartzCore
import UIKit
import YlFFmpegBridge

struct YlFallbackLifecycleTransaction {
  let pauseClock: () throws -> Void
  let advanceGeneration: () throws -> UInt64
  let stopDemux: () throws -> Void
  let clearBuffers: (UInt64) -> Void
  let seekDemux: (Int64) throws -> Void
  let resetAudio: (UInt64) throws -> Void
  let recreateVideo: (UInt64) throws -> Void
  let suppressFramesBefore: (Int64) -> Void
  let restartDemux: () throws -> Void

  func seek(toUs targetUs: Int64) throws {
    try pauseClock()
    let generation = try advanceGeneration()
    try stopDemux()
    clearBuffers(generation)
    try seekDemux(targetUs)
    try resetAudio(generation)
    try recreateVideo(generation)
    suppressFramesBefore(targetUs)
    try restartDemux()
  }
}

struct YlFallbackTeardownTransaction {
  let cancelInput: () -> Void
  let joinAndRelease: () -> Void

  func run() {
    cancelInput()
    joinAndRelease()
  }
}

struct YlFallbackSeekPolicy {
  let isSeekable: Bool
  let perform: (Int64) throws -> Void

  func seek(toUs targetUs: Int64) throws {
    guard isSeekable else {
      throw NativePlayerError(
        category: "network",
        code: "network.range_not_supported",
        message: "This network source does not support random access."
      )
    }
    try perform(targetUs)
  }
}

struct YlFallbackMediaPolicy: Equatable {
  let container: YlFallbackContainer
  let isLive: Bool
  let isSeekable: Bool
  let requiresInitialVideoKeyframe: Bool

  init(container: YlFallbackContainer, sourceSupportsRandomAccess: Bool) {
    self.container = container
    switch container {
    case .matroska:
      isLive = false
      isSeekable = sourceSupportsRandomAccess
      requiresInitialVideoKeyframe = false
    case .flv:
      isLive = true
      isSeekable = false
      requiresInitialVideoKeyframe = true
    }
  }

  func durationMs(mediaDurationUs: Int64) -> Int64? {
    guard !isLive, mediaDurationUs > 0 else { return nil }
    return mediaDurationUs / 1_000
  }
}

struct YlInitialKeyframeGate {
  private(set) var isOpen = false

  mutating func accepts(isVideo: Bool, isKeyframe: Bool) -> Bool {
    if isOpen || !isVideo { return isOpen }
    if isKeyframe { isOpen = true }
    return isOpen
  }

  mutating func reset() {
    isOpen = false
  }
}

enum YlFallbackCommandPolicy {
  static func requiresBackgroundExecution(
    isNetwork: Bool,
    isActive: Bool,
    name: String
  ) -> Bool {
    isNetwork && isActive && (name == "seekTo" || name == "selectAudioTrack")
  }
}

enum YlFallbackRetryEvent {
  static func envelope(
    playerId: Int64,
    attempt: Int,
    delayMs: Int64,
    error: NativePlayerError
  ) -> [String: Any?] {
    [
      "playerId": playerId,
      "type": "retry",
      "attempt": attempt,
      "delayMs": delayMs,
      "error": errorMap(
        category: error.category,
        code: error.code,
        message: error.message,
        diagnostic: error.diagnostic
      ),
    ]
  }
}

struct YlFallbackResumeState: Equatable {
  let positionUs: Int64
  let selectedAudioStreamIndex: Int32?
  let shouldPlay: Bool
}

enum YlFallbackReactivationPolicy {
  static func resolve(
    isSeekable: Bool,
    savedPositionUs: Int64,
    selectedAudioStreamIndex: Int32?,
    shouldPlay: Bool
  ) -> YlFallbackResumeState {
    YlFallbackResumeState(
      positionUs: isSeekable ? max(0, savedPositionUs) : 0,
      selectedAudioStreamIndex: selectedAudioStreamIndex,
      shouldPlay: isSeekable && shouldPlay
    )
  }
}

struct YlFallbackReplacementGenerations: Equatable {
  let videoGeneration: UInt64
  let audioGeneration: UInt64
}

enum YlFallbackReplacementGenerationPolicy {
  static func quiesce(
    videoGeneration: UInt64,
    audioGeneration: UInt64
  ) -> YlFallbackReplacementGenerations {
    // Decoded video callbacks can still arrive after VideoToolbox is paused, so
    // invalidate them. The retained audio renderer, however, remains configured
    // for its current generation and must accept the first packet after rollback.
    YlFallbackReplacementGenerations(
      videoGeneration: videoGeneration &+ 1,
      audioGeneration: audioGeneration
    )
  }
}

final class YlPostSeekGate {
  private let lock = NSLock()
  private var minimumVideoPtsUs: Int64?
  private var minimumAudioPtsUs: Int64?

  func reset(targetUs: Int64?) {
    lock.withLock {
      minimumVideoPtsUs = targetUs
      minimumAudioPtsUs = targetUs
    }
  }

  func acceptsVideo(ptsUs: Int64) -> Bool {
    lock.withLock {
      guard let minimumVideoPtsUs else { return true }
      guard ptsUs >= minimumVideoPtsUs else { return false }
      self.minimumVideoPtsUs = nil
      return true
    }
  }

  func acceptsAudio(ptsUs: Int64) -> Bool {
    lock.withLock {
      guard let minimumAudioPtsUs else { return true }
      guard ptsUs >= minimumAudioPtsUs else { return false }
      self.minimumAudioPtsUs = nil
      return true
    }
  }
}

final class YlPreparedFallback {
  let sourceRecipe: YlFallbackSourceRecipe
  let policy: YlFallbackMediaPolicy
  let mediaInfo: YLFMediaInfo
  let videoStream: YLFStreamInfo
  let audioStreams: [YLFStreamInfo]
  let videoFormat: CMVideoFormatDescription
  let audioCookies: [Int32: Data]
  let sessionConfiguration: URLSessionConfiguration
  var container: YlFallbackContainer { policy.container }
  var isSeekable: Bool { policy.isSeekable }
  private(set) var resumeState: YlFallbackResumeState?
  private var openedMedia: YlOpenedMedia?
  private var cancellationToken: YlOpenCancellationToken?

  init(
    source: [String: Any?],
    requireHardwareProbe: Bool = true,
    configuration: PlayerConfiguration = PlayerConfiguration(map: [:]),
    sessionConfiguration: URLSessionConfiguration = .ephemeral,
    cancellationToken: YlOpenCancellationToken? = nil,
    onRetry: YlNetworkByteSource.RetryCallback? = nil
  ) throws {
    self.sessionConfiguration = sessionConfiguration
    try cancellationToken?.throwIfCancelled()
    guard let uri = source["uri"] as? String,
          let url = URL(string: uri) else {
      throw NativePlayerError(
        category: "source",
        code: "source.invalid_uri",
        message: "A valid fallback media URI is required."
      )
    }
    let formatHint = source["formatHint"] as? String ?? "automatic"
    let container: YlFallbackContainer = formatHint == "httpFlv"
      || formatHint == "flv"
      || (formatHint == "automatic" && url.pathExtension.lowercased() == "flv")
      ? .flv : .matroska
    if url.isFileURL {
      sourceRecipe = .local(path: url.path, container: container)
    } else if let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" {
      let headers = stringMap(source["headers"]).compactMapValues { $0 as? String }
      sourceRecipe = .network(request: YlNetworkRequestRecipe(
        url: url,
        headers: headers,
        configuration: configuration.network,
        mode: container == .flv ? .sequentialLive : .randomAccessVOD
      ), container: container)
    } else {
      throw NativePlayerError(
        category: "source",
        code: "source.invalid_uri",
        message: "Only file, HTTP, and HTTPS fallback media URIs are supported."
      )
    }
    let budget = try YlFallbackBufferBudget.make(configuration: configuration)
    let opened = try YlOpenedMedia(
      recipe: sourceRecipe,
      networkBufferBytes: budget.networkBytes,
      sessionConfiguration: sessionConfiguration,
      onRetry: onRetry,
      onSourceCreated: { source in
        cancellationToken?.onCancel { source.cancel() }
      }
    )
    try cancellationToken?.throwIfCancelled()
    mediaInfo = opened.info
    policy = YlFallbackMediaPolicy(
      container: container,
      sourceSupportsRandomAccess: opened.supportsRandomAccess
    )
    guard let validContext = opened.context else {
      opened.close()
      throw NativePlayerError(
        category: "internal",
        code: "internal.fallback_invariant",
        message: "The opened fallback media context was unavailable."
      )
    }
    var mediaNeedsClose = true
    defer {
      if mediaNeedsClose { opened.close() }
    }

    var selectedVideo: YLFStreamInfo?
    var selectedAudio: [YLFStreamInfo] = []
    var sawUnsupportedAudio = false
    for index in 0..<mediaInfo.stream_count {
      var stream = YLFStreamInfo()
      guard ylf_copy_stream_info(validContext, index, &stream) == 0 else { continue }
      if Int(stream.kind) == YLFStreamVideo,
         (Int(stream.codec) == YLFCodecH264 || Int(stream.codec) == YLFCodecHEVC),
         selectedVideo == nil {
        selectedVideo = stream
      } else if Int(stream.kind) == YLFStreamAudio {
        if Int(stream.codec) == YLFCodecAAC || Int(stream.codec) == YLFCodecMP3 {
          selectedAudio.append(stream)
        } else {
          sawUnsupportedAudio = true
        }
      }
    }
    guard let selectedVideo else {
      throw NativePlayerError(
        category: "decoderUnsupported",
        code: "decoder.video_hardware_unavailable",
        message: "The file does not contain supported H.264 or H.265 video."
      )
    }
    if selectedAudio.isEmpty && sawUnsupportedAudio {
      throw NativePlayerError(
        category: "decoderUnsupported",
        code: "decoder.audio_aac_unsupported",
        message: container == .flv
          ? "The selected FLV audio track is not AAC or MP3."
          : "The selected Matroska audio track is not AAC."
      )
    }
    videoStream = selectedVideo
    audioStreams = selectedAudio
    videoFormat = try YlVideoToolboxDecoder.makeFormatDescription(
      context: validContext,
      streamIndex: selectedVideo.index
    )

    var copiedAudioCookies: [Int32: Data] = [:]
    for audioStream in selectedAudio where Int(audioStream.codec) == YLFCodecAAC {
      let size = ylf_stream_codec_config_size(validContext, audioStream.index)
      guard size > 0 else {
        throw NativePlayerError(
          category: "decoderUnsupported",
          code: "decoder.audio_aac_unsupported",
          message: "The AAC codec configuration is missing."
        )
      }
      var bytes = [UInt8](repeating: 0, count: size)
      guard ylf_copy_stream_codec_config(
        validContext,
        audioStream.index,
        &bytes,
        bytes.count
      ) == 0 else {
        throw NativePlayerError(
          category: "decoderUnsupported",
          code: "decoder.audio_aac_unsupported",
          message: "The AAC codec configuration is invalid."
        )
      }
      copiedAudioCookies[audioStream.index] = Data(bytes)
    }
    audioCookies = copiedAudioCookies

    if requireHardwareProbe {
      let probe = try YlVideoToolboxDecoder(
        formatDescription: videoFormat,
        onFrame: { _ in },
        onError: { _ in }
      )
      probe.dispose()
    }
    openedMedia = opened
    self.cancellationToken = cancellationToken
    mediaNeedsClose = false
  }

  func takeMedia() throws -> YlOpenedMedia {
    guard let openedMedia else {
      throw NativePlayerError(
        category: "internal",
        code: "internal.fallback_invariant",
        message: "The prepared Matroska context was already consumed."
      )
    }
    self.openedMedia = nil
    return openedMedia
  }

  func prepareForReactivation(_ requested: YlFallbackResumeState) throws {
    guard let openedMedia else {
      throw NativePlayerError(
        category: "internal",
        code: "internal.fallback_invariant",
        message: "The prepared Matroska context was already consumed."
      )
    }
    let resolved = YlFallbackReactivationPolicy.resolve(
      isSeekable: isSeekable,
      savedPositionUs: requested.positionUs,
      selectedAudioStreamIndex: requested.selectedAudioStreamIndex,
      shouldPlay: requested.shouldPlay
    )
    if resolved.positionUs > 0 {
      try openedMedia.seek(toMediaTimeUs: resolved.positionUs)
    }
    resumeState = resolved
  }

  func takeCancellationToken() -> YlOpenCancellationToken? {
    defer { cancellationToken = nil }
    return cancellationToken
  }

  func discard() {
    cancellationToken?.cancel()
    cancellationToken = nil
    openedMedia?.close()
    openedMedia = nil
  }

  deinit {
    discard()
  }
}

private final class YlFallbackOutputRelay {
  weak var backend: YlFallbackBackend?
  func frame(_ frame: YlVideoFrame) { backend?.receive(frame) }
  func error(_ error: NativePlayerError) { backend?.fail(error) }
}

private struct YlFallbackReconnectPipeline {
  let media: YlOpenedMedia
  let info: YLFMediaInfo
  let videoStream: YLFStreamInfo
  let audioStreams: [YLFStreamInfo]
  let audioCookies: [Int32: Data]
  let videoFormat: CMVideoFormatDescription
  let selectedAudioStream: YLFStreamInfo?
  let decoder: YlVideoToolboxDecoder
  let audioRenderer: YlAudioRenderer

  func discard() {
    decoder.dispose()
    audioRenderer.dispose()
    media.cancelInput()
    media.close()
  }
}

final class YlFallbackBackend: NSObject, YlPlaybackBackend {
  let playerId: Int64
  var textureId: Int64 = -1
  var isActive: Bool { stateLock.withLock { active } }
  var requiresAsyncActivation: Bool {
    guard context == nil else { return false }
    if case .network = sourceRecipe { return true }
    return false
  }

  func requiresAsyncCommand(_ name: String) -> Bool {
    let isNetwork: Bool
    if case .network = sourceRecipe { isNetwork = true } else { isNetwork = false }
    return YlFallbackCommandPolicy.requiresBackgroundExecution(
      isNetwork: isNetwork,
      isActive: isActive,
      name: name
    )
  }

  func interruptControlOperation() {
    stateLock.withLock { openedMedia }?.interruptRead()
  }

  func resumeControlOperation() {
    stateLock.withLock { openedMedia }?.resumeReads()
  }

  private let textures: FlutterTextureRegistry
  private let configuration: PlayerConfiguration
  private let emit: ([String: Any?]) -> Void
  private let sourceRecipe: YlFallbackSourceRecipe
  private let sessionConfiguration: URLSessionConfiguration
  private let mediaPolicy: YlFallbackMediaPolicy
  private let bufferBudget: YlFallbackBufferBudget
  private var mediaInfo: YLFMediaInfo
  private var videoStream: YLFStreamInfo
  private var audioStreams: [YLFStreamInfo]
  private var audioCookies: [Int32: Data]
  private var isSeekable: Bool
  private var videoFormat: CMVideoFormatDescription
  private let worker = DispatchQueue(label: "dev.ylplayer.ios.fallback.demux")
  private let stateLock = NSLock()
  private let frameScheduler = YlFrameScheduler()
  private let postSeekGate = YlPostSeekGate()
  private let liveReconnectController: YlLiveReconnectController
  private var initialKeyframeGate = YlInitialKeyframeGate()
  private var audioRenderer: YlAudioRenderer!
  private let outputRelay = YlFallbackOutputRelay()
  private var mediaClock: YlMediaClock!
  private var decoder: YlVideoToolboxDecoder?
  private var openedMedia: YlOpenedMedia?
  private var sourceCancellationToken: YlOpenCancellationToken?
  private var context: YLFMediaContextRef? {
    stateLock.withLock { openedMedia }?.context
  }
  private var displayLink: CADisplayLink?
  private var currentPixelBuffer: CVPixelBuffer?
  private var active = false
  private var playing = false
  private var disposed = false
  private var pumping = false
  private var reconfiguring = false
  private var reconnectWorkItem: DispatchWorkItem?
  private var awaitingReconnectFirstFrame = false
  private var generation: UInt64
  private var audioGeneration: UInt64
  private var selectedAudioStream: YLFStreamInfo?
  private var desiredVolume: Float = 1
  private var desiredRate: Float = 1
  private var savedPositionUs: Int64 = 0
  private var status = "ready"
  private var firstFrameSent = false
  private var prebufferedVideoSample = false
  private var demuxEOF = false
  private var completionSent = false
  private var audioAnchored = false
  private var pendingAudioPacket: YlCompressedAudioPacket?
  private var openStartedAt = CACurrentMediaTime()
  private var openDurationMs: Int64?
  private var firstFrameDurationMs: Int64?
  private var reconnectCount = 0
  private var currentError: [String: Any?]?
  private var lastStateEmitAt = CFTimeInterval(0)

  init(
    playerId: Int64,
    textureId: Int64,
    textures: FlutterTextureRegistry,
    configuration: PlayerConfiguration,
    prepared: YlPreparedFallback,
    generation: UInt64,
    emit: @escaping ([String: Any?]) -> Void
  ) throws {
    self.playerId = playerId
    self.textureId = textureId
    self.textures = textures
    self.configuration = configuration
    self.sourceRecipe = prepared.sourceRecipe
    self.sessionConfiguration = prepared.sessionConfiguration
    self.mediaPolicy = prepared.policy
    self.bufferBudget = try YlFallbackBufferBudget.make(configuration: configuration)
    self.liveReconnectController = YlLiveReconnectController(
      configuration: configuration.network
    )
    self.mediaInfo = prepared.mediaInfo
    self.videoStream = prepared.videoStream
    self.audioStreams = prepared.audioStreams
    self.audioCookies = prepared.audioCookies
    self.isSeekable = prepared.isSeekable
    let resumeState = prepared.resumeState
    self.selectedAudioStream = resumeState?.selectedAudioStreamIndex.flatMap { index in
      prepared.audioStreams.first { $0.index == index }
    } ?? prepared.audioStreams.first
    self.videoFormat = prepared.videoFormat
    self.generation = generation
    self.audioGeneration = generation
    self.emit = emit
    self.openedMedia = try prepared.takeMedia()
    self.sourceCancellationToken = prepared.takeCancellationToken()
    self.playing = resumeState?.shouldPlay ?? false
    self.savedPositionUs = resumeState?.positionUs ?? 0
    super.init()

    audioRenderer = YlAudioRenderer(bufferBudget: bufferBudget)
    mediaClock = YlMediaClock(audioTime: { [weak self] in
      self?.audioRenderer?.renderedAudioTime
    })
    mediaClock.seek(to: savedPositionUs)
    outputRelay.backend = self
    do {
      decoder = try YlVideoToolboxDecoder(
        formatDescription: videoFormat,
        onFrame: { [outputRelay] frame in outputRelay.frame(frame) },
        onError: { [outputRelay] error in outputRelay.error(error) }
      )
      if let audioStream = selectedAudioStream {
        try audioRenderer.configure(stream: audioConfiguration(
          for: audioStream,
          generation: audioGeneration
        ))
      }
    } catch {
      decoder?.dispose()
      decoder = nil
      audioRenderer?.dispose()
      audioRenderer = nil
      openedMedia?.close()
      openedMedia = nil
      throw error
    }
    frameScheduler.flush(generation: generation)
    openDurationMs = Int64((CACurrentMediaTime() - openStartedAt) * 1_000)
    installDisplayLink(paused: true)
  }

  func activate() throws {
    stateLock.lock()
    guard !disposed, !active else {
      stateLock.unlock()
      return
    }
    stateLock.unlock()
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .moviePlayback)
      try session.setActive(true)
    } catch {
      throw NativePlayerError(
        category: "resource",
        code: "ios.audio_session_failed",
        message: "The playback audio session could not be activated.",
        diagnostic: String(describing: error)
      )
    }
    if requiresAsyncActivation {
      throw NativePlayerError(
        category: "internal",
        code: "ios.async_activation_required",
        message: "Network Matroska reactivation requires background preparation."
      )
    }
    if context == nil || decoder == nil || audioRenderer == nil {
      try rebuildPipeline(positionUs: savedPositionUs)
    }
    if displayLink == nil { installDisplayLink(paused: false) }
    stateLock.withLock {
      active = true
      reconfiguring = false
    }
    displayLink?.isPaused = false
    if playing {
      if selectedAudioStream != nil { try audioRenderer.play() }
      mediaClock.play(atHostTimeUs: Self.hostTimeUs())
      status = "playing"
    }
    emit([
      "playerId": playerId,
      "type": "fallbackActivated",
      "engine": "nativeFallback",
    ])
    emitState()
    requestPump()
  }

  func deactivate() {
    stateLock.lock()
    guard !disposed, active else {
      stateLock.unlock()
      return
    }
    savedPositionUs = mediaClock.position(atHostTimeUs: Self.hostTimeUs())
    active = false
    reconfiguring = true
    generation &+= 1
    audioGeneration &+= 1
    let currentGeneration = generation
    let reconnectToCancel = reconnectWorkItem
    reconnectWorkItem = nil
    let mediaToClose = openedMedia
    openedMedia = nil
    let tokenToCancel = sourceCancellationToken
    sourceCancellationToken = nil
    stateLock.unlock()
    reconnectToCancel?.cancel()
    displayLink?.invalidate()
    displayLink = nil
    audioRenderer?.pause()
    mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
    YlFallbackTeardownTransaction(
      cancelInput: { [self] in
        tokenToCancel?.cancel()
        mediaToClose?.cancelInput()
      },
      joinAndRelease: { [self] in
        worker.sync {
          pendingAudioPacket = nil
          decoder?.dispose()
          decoder = nil
          audioRenderer?.dispose()
          audioRenderer = nil
        }
        mediaToClose?.close()
      }
    ).run()
    frameScheduler.flush(generation: currentGeneration)
    stateLock.withLock {
      currentPixelBuffer = nil
      pumping = false
      demuxEOF = false
      completionSent = false
      prebufferedVideoSample = false
      audioAnchored = false
      reconfiguring = false
    }
    postSeekGate.reset(targetUs: nil)
    mediaClock.seek(to: savedPositionUs)
    status = "paused"
    emitState()
  }

  func quiesceForReplacement() {
    stateLock.lock()
    guard !disposed, active else {
      stateLock.unlock()
      return
    }
    savedPositionUs = mediaClock.position(atHostTimeUs: Self.hostTimeUs())
    active = false
    reconfiguring = true
    let generations = YlFallbackReplacementGenerationPolicy.quiesce(
      videoGeneration: generation,
      audioGeneration: audioGeneration
    )
    generation = generations.videoGeneration
    audioGeneration = generations.audioGeneration
    let currentGeneration = generation
    let reconnectToCancel = reconnectWorkItem
    reconnectWorkItem = nil
    let media = openedMedia
    stateLock.unlock()

    reconnectToCancel?.cancel()

    displayLink?.invalidate()
    displayLink = nil
    audioRenderer?.pause()
    mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
    media?.interruptRead()
    worker.sync { pendingAudioPacket = nil }
    media?.resumeReads()
    frameScheduler.flush(generation: currentGeneration)
    stateLock.withLock {
      currentPixelBuffer = nil
      pumping = false
      demuxEOF = false
      completionSent = false
      prebufferedVideoSample = false
      audioAnchored = false
      reconfiguring = false
    }
    postSeekGate.reset(targetUs: nil)
    mediaClock.seek(to: savedPositionUs)
    status = "paused"
    emitState()
  }

  func reactivationState(forcePlay: Bool) -> YlFallbackResumeState {
    stateLock.withLock {
      YlFallbackResumeState(
        positionUs: savedPositionUs,
        selectedAudioStreamIndex: selectedAudioStream?.index,
        shouldPlay: forcePlay || playing
      )
    }
  }

  func handleMemoryWarning() {
    stateLock.withLock { openedMedia }?.handleMemoryWarning()
    deactivate()
  }

  func command(name: String, arguments: [String: Any?]) throws {
    try command(name: name, arguments: arguments, cancellationToken: nil)
  }

  func command(
    name: String,
    arguments: [String: Any?],
    cancellationToken: YlOpenCancellationToken?
  ) throws {
    switch name {
    case "open":
      emitState()
    case "play":
      let wasPlaying = stateLock.withLock { () -> Bool in
        let previous = playing
        playing = true
        return previous
      }
      if !wasPlaying {
        if selectedAudioStream != nil { try audioRenderer?.play() }
        mediaClock.play(atHostTimeUs: Self.hostTimeUs())
      }
      status = "playing"
      emitState()
      requestPump()
    case "pause":
      stateLock.withLock { playing = false }
      if selectedAudioStream != nil { audioRenderer?.pause() }
      mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
      status = "paused"
      emitState()
    case "seekTo":
      try seek(
        toMs: int64(arguments["positionMs"]) ?? 0,
        cancellationToken: cancellationToken
      )
    case "seekToLiveEdge":
      if mediaPolicy.isLive {
        throw NativePlayerError(
          category: "network",
          code: "network.range_not_supported",
          message: "HTTP-FLV does not expose a seekable live window."
        )
      }
      throw NativePlayerError(
        category: "source",
        code: "source.not_live",
        message: "Matroska playback is not live."
      )
    case "setPlaybackSpeed":
      let rate = float(arguments["speed"]) ?? 1
      guard rate >= 0.25, rate <= 4 else {
        throw NativePlayerError(
          category: "source",
          code: "playback.speed_invalid",
          message: "Playback speed must be between 0.25 and 4.0."
        )
      }
      desiredRate = rate
      if selectedAudioStream != nil { audioRenderer?.setRate(rate) }
      mediaClock.setRate(Double(rate), atHostTimeUs: Self.hostTimeUs())
    case "setVolume":
      desiredVolume = float(arguments["volume"]) ?? 1
      if selectedAudioStream != nil {
        audioRenderer?.setVolume(desiredVolume)
      }
    case "selectAudioTrack":
      try selectAudioTrack(
        arguments["trackId"] as? String,
        cancellationToken: cancellationToken
      )
    case "setQualityConstraint":
      return
    default:
      throw NativePlayerError(
        category: "internal",
        code: "ios.command_unknown",
        message: "Unknown player command: \(name)"
      )
    }
  }

  func emitState() {
    guard !stateLock.withLock({ disposed }) else { return }
    let positionUs = mediaClock.position(atHostTimeUs: Self.hostTimeUs())
    let durationMs = mediaPolicy.durationMs(mediaDurationUs: mediaInfo.duration_us)
    let scheduledAudioDurationUs = audioRenderer?.scheduledDurationUs ?? 0
    let scheduledAudioBytes = audioRenderer?.scheduledBytes ?? 0
    let audioUnderruns = audioRenderer?.underrunCount ?? 0
    emit([
      "playerId": playerId,
      "type": "state",
      "state": [
        "status": status,
        "positionMs": positionUs / 1_000,
        "durationMs": durationMs,
        "bufferedPositionMs": (positionUs + scheduledAudioDurationUs) / 1_000,
        "isLive": mediaPolicy.isLive,
        "isSeekable": isSeekable,
        "isAtLiveEdge": mediaPolicy.isLive,
        "liveOffsetMs": nil,
        "dvrStartMs": nil,
        "dvrEndMs": nil,
        "videoWidth": Int(videoStream.width),
        "videoHeight": Int(videoStream.height),
        "engine": "nativeFallback",
        "isHardwareDecoding": true,
        "decoderName": "VideoToolbox",
        "audioTracks": audioTracks,
        "videoTracks": videoTracks,
        "capabilities": [
          "hardwareVideoCodecs": ["h264", "hevc"],
          "supportedFormats": ["matroska", "httpFlv", "flv"],
          "maxConcurrentVideoDecoders": 1,
        ],
        "metrics": [
          "openDurationMs": openDurationMs,
          "firstFrameDurationMs": firstFrameDurationMs,
          "rebufferCount": 0,
          "rebufferDurationMs": 0,
          "bufferedDurationMs": scheduledAudioDurationUs / 1_000,
          "bufferedBytes": scheduledAudioBytes,
          "droppedFrames": frameScheduler.lateFrameDropCount,
          "audioUnderruns": audioUnderruns,
          "reconnectCount": reconnectCount,
        ],
        "error": currentError,
      ],
    ])
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    stateLock.lock()
    let buffer = currentPixelBuffer
    stateLock.unlock()
    return buffer.map(Unmanaged.passRetained)
  }

  func dispose() {
    stateLock.lock()
    guard !disposed else {
      stateLock.unlock()
      return
    }
    disposed = true
    active = false
    playing = false
    reconfiguring = true
    generation &+= 1
    audioGeneration &+= 1
    let reconnectToCancel = reconnectWorkItem
    reconnectWorkItem = nil
    let mediaToClose = openedMedia
    openedMedia = nil
    let tokenToCancel = sourceCancellationToken
    sourceCancellationToken = nil
    stateLock.unlock()
    liveReconnectController.cancel()
    reconnectToCancel?.cancel()
    displayLink?.invalidate()
    displayLink = nil
    YlFallbackTeardownTransaction(
      cancelInput: { [self] in
        tokenToCancel?.cancel()
        mediaToClose?.cancelInput()
      },
      joinAndRelease: { [self] in
        worker.sync {
          pendingAudioPacket = nil
          decoder?.dispose()
          decoder = nil
          audioRenderer?.dispose()
          audioRenderer = nil
          frameScheduler.dispose()
        }
        mediaToClose?.close()
      }
    ).run()
    stateLock.withLock { currentPixelBuffer = nil }
  }

  fileprivate func receive(_ frame: YlVideoFrame) {
    guard stateLock.withLock({ active && generation == frame.generation }),
          postSeekGate.acceptsVideo(ptsUs: frame.ptsUs) else { return }
    let accepted = frameScheduler.enqueue(YlFrameEnvelope(
      payload: frame.pixelBuffer,
      ptsUs: frame.ptsUs == .min ? 0 : frame.ptsUs,
      durationUs: frame.durationUs,
      keyframe: frame.keyframe,
      generation: frame.generation
    ))
    guard accepted else { return }
    let completedReconnect = stateLock.withLock { () -> Bool in
      guard awaitingReconnectFirstFrame, generation == frame.generation else {
        return false
      }
      awaitingReconnectFirstFrame = false
      reconnectCount += 1
      return true
    }
    if completedReconnect {
      liveReconnectController.markFirstFrame()
      DispatchQueue.main.async { [weak self] in self?.emitState() }
    }
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.firstFrameSent,
            self.stateLock.withLock({ self.active && self.generation == frame.generation })
      else { return }
      self.present(frame.pixelBuffer)
      self.firstFrameSent = true
      self.firstFrameDurationMs = Int64(
        (CACurrentMediaTime() - self.openStartedAt) * 1_000
      )
      self.emit([
        "playerId": self.playerId,
        "type": "firstFrame",
        "width": Int(self.videoStream.width),
        "height": Int(self.videoStream.height),
      ])
      self.emitState()
    }
  }

  fileprivate func fail(_ error: NativePlayerError) {
    DispatchQueue.main.async { [weak self] in self?.setFailure(error) }
  }

  @objc private func displayLinkTick() {
    let now = Self.hostTimeUs()
    let position = mediaClock.position(atHostTimeUs: now)
    let currentGeneration = stateLock.withLock { generation }
    if let frame = frameScheduler.frame(at: position, generation: currentGeneration) {
      let pixelBuffer = unsafeBitCast(frame.payload, to: CVPixelBuffer.self)
      present(pixelBuffer)
    }
    completeIfDrained(atHostTimeUs: now)
    let wallNow = CACurrentMediaTime()
    if wallNow - lastStateEmitAt >= Double(configuration.positionEventIntervalMs) / 1_000 {
      lastStateEmitAt = wallNow
      emitState()
    }
  }

  private func present(_ pixelBuffer: CVPixelBuffer) {
    stateLock.withLock { currentPixelBuffer = pixelBuffer }
    if textureId >= 0 { textures.textureFrameAvailable(textureId) }
  }

  private func requestPump(after delay: TimeInterval = 0) {
    stateLock.lock()
    guard !disposed, active, !reconfiguring, !pumping, !demuxEOF else {
      stateLock.unlock()
      return
    }
    pumping = true
    stateLock.unlock()
    worker.asyncAfter(deadline: .now() + delay) { [weak self] in self?.pumpOne() }
  }

  private func pumpOne() {
    stateLock.lock()
    let shouldContinue = !disposed && active && !reconfiguring
      && (playing || !prebufferedVideoSample)
    let packetGeneration = generation
    if !shouldContinue {
      pumping = false
      stateLock.unlock()
      return
    }
    stateLock.unlock()

    if let pendingAudioPacket {
      do {
        guard let audioRenderer else {
          stateLock.withLock { pumping = false }
          return
        }
        let enqueueResult = try audioRenderer.enqueue(packet: pendingAudioPacket)
        if enqueueResult == .scheduled {
          self.pendingAudioPacket = nil
          anchorAudioIfNeeded(pendingAudioPacket)
          stateLock.withLock { pumping = false }
          requestPump()
        } else if enqueueResult == .wouldExceedBytes || enqueueResult == .wouldExceedDuration {
          stateLock.withLock { pumping = false }
          requestPump(after: 0.02)
        } else {
          self.pendingAudioPacket = nil
          stateLock.withLock { pumping = false }
        }
      } catch let error as NativePlayerError {
        self.pendingAudioPacket = nil
        stateLock.withLock { pumping = false }
        fail(error)
      } catch {
        self.pendingAudioPacket = nil
        stateLock.withLock { pumping = false }
        fail(NativePlayerError(
          category: "decoderFailure",
          code: "decoder.audio_failed",
          message: "\(selectedAudioCodecName) audio conversion failed.",
          diagnostic: String(describing: error)
        ))
      }
      return
    }

    var packet: YLFPacketRef?
    let result = ylf_read_packet(context, &packet)
    if result == Int32(YLFResultEOF) {
      if mediaPolicy.isLive {
        beginLiveReconnect(
          after: NativePlayerError(
            category: "network",
            code: "network.http_status",
            message: "The HTTP-FLV connection ended."
          ),
          packetGeneration: packetGeneration
        )
        return
      }
      stateLock.withLock {
        pumping = false
        demuxEOF = true
      }
      decoder?.flush()
      return
    }
    guard result == Int32(YLFResultOK), let ownedPacket = packet else {
      let inputError = stateLock.withLock { openedMedia?.lastInputError }
      if mediaPolicy.isLive, result == Int32(YLFResultCallbackFailed) {
        ylf_packet_release(&packet)
        beginLiveReconnect(
          after: inputError ?? NativePlayerError(
            category: "network",
            code: "network.http_status",
            message: "The HTTP-FLV network input failed.",
            diagnostic: "YlFFmpegBridge result \(result)"
          ),
          packetGeneration: packetGeneration
        )
        return
      }
      let shouldReport = stateLock.withLock { () -> Bool in
        pumping = false
        return !disposed && active && !reconfiguring && generation == packetGeneration
      }
      ylf_packet_release(&packet)
      if shouldReport {
        fail(NativePlayerError(
          category: "container",
          code: mediaPolicy.container == .flv
            ? "container.flv_malformed" : "container.mkv_malformed",
          message: mediaPolicy.container == .flv
            ? "The FLV packet stream is malformed."
            : "The Matroska packet stream is malformed.",
          diagnostic: "YlFFmpegBridge result \(result)"
        ))
      }
      return
    }

    do {
      try bufferBudget.validateInFlightPacket(size: ylf_packet_size(ownedPacket))
    } catch let error as NativePlayerError {
      ylf_packet_release(&packet)
      stateLock.withLock { pumping = false }
      fail(error)
      return
    } catch {
      ylf_packet_release(&packet)
      stateLock.withLock { pumping = false }
      return
    }

    let streamIndex = ylf_packet_stream_index(ownedPacket)
    if mediaPolicy.requiresInitialVideoKeyframe {
      let isVideo = streamIndex == videoStream.index
      let accepted = stateLock.withLock {
        initialKeyframeGate.accepts(
          isVideo: isVideo,
          isKeyframe: isVideo && ylf_packet_is_keyframe(ownedPacket)
        )
      }
      if !accepted {
        ylf_packet_release(&packet)
        stateLock.withLock { pumping = false }
        requestPump()
        return
      }
    }
    var retryDelay = TimeInterval(0)
    if streamIndex == videoStream.index {
      var unmanagedSample: Unmanaged<CMSampleBuffer>?
      let sampleResult = ylf_create_video_sample_buffer(
        &packet,
        videoFormat,
        &unmanagedSample
      )
      if sampleResult == 0, let unmanagedSample {
        stateLock.withLock { prebufferedVideoSample = true }
        decoder?.decode(
          sample: unmanagedSample.takeRetainedValue(),
          generation: packetGeneration
        )
      } else {
        ylf_packet_release(&packet)
      }
    } else if streamIndex == selectedAudioStream?.index,
              let bytes = ylf_packet_data(ownedPacket) {
      let audioPacket = YlCompressedAudioPacket(
        data: Data(bytes: bytes, count: ylf_packet_size(ownedPacket)),
        ptsUs: ylf_packet_pts_us(ownedPacket),
        durationUs: ylf_packet_duration_us(ownedPacket),
        generation: stateLock.withLock { audioGeneration }
      )
      ylf_packet_release(&packet)
      if !postSeekGate.acceptsAudio(ptsUs: audioPacket.ptsUs) {
        stateLock.withLock { pumping = false }
        requestPump()
        return
      }
      do {
        guard let audioRenderer else {
          stateLock.withLock { pumping = false }
          return
        }
        let enqueueResult = try audioRenderer.enqueue(packet: audioPacket)
        if enqueueResult == .wouldExceedBytes || enqueueResult == .wouldExceedDuration {
          pendingAudioPacket = audioPacket
          retryDelay = 0.02
        } else if enqueueResult == .scheduled {
          anchorAudioIfNeeded(audioPacket)
        }
      } catch let error as NativePlayerError {
        fail(error)
      } catch {
        fail(NativePlayerError(
          category: "decoderFailure",
          code: "decoder.audio_failed",
          message: "\(selectedAudioCodecName) audio conversion failed.",
          diagnostic: String(describing: error)
        ))
      }
    } else {
      ylf_packet_release(&packet)
    }

    stateLock.withLock { pumping = false }
    requestPump(after: retryDelay)
  }

  private func beginLiveReconnect(
    after error: NativePlayerError,
    packetGeneration: UInt64
  ) {
    let transition = stateLock.withLock { () -> (
      generation: UInt64,
      media: YlOpenedMedia?,
      token: YlOpenCancellationToken?
    )? in
      guard mediaPolicy.isLive, !disposed, active, !reconfiguring,
            generation == packetGeneration else { return nil }
      generation &+= 1
      audioGeneration &+= 1
      reconfiguring = true
      pumping = false
      demuxEOF = false
      completionSent = false
      awaitingReconnectFirstFrame = false
      let detachedMedia = openedMedia
      openedMedia = nil
      let detachedToken = sourceCancellationToken
      sourceCancellationToken = nil
      return (generation, detachedMedia, detachedToken)
    }
    guard let transition else { return }

    transition.token?.cancel()
    transition.media?.cancelInput()
    pendingAudioPacket = nil
    decoder?.dispose()
    decoder = nil
    audioRenderer?.pause()
    audioRenderer?.dispose()
    audioRenderer = nil
    transition.media?.close()
    prebufferedVideoSample = false
    audioAnchored = false
    frameScheduler.flush(generation: transition.generation)
    postSeekGate.reset(targetUs: nil)
    stateLock.withLock { currentPixelBuffer = nil }

    DispatchQueue.main.async { [weak self] in
      guard let self,
            self.stateLock.withLock({
              self.active && self.reconfiguring
                && self.generation == transition.generation
            }) else { return }
      self.mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
      self.mediaClock.seek(to: 0)
      self.status = "buffering"
      self.emitState()
    }
    scheduleLiveReconnect(after: error, generation: transition.generation)
  }

  private func scheduleLiveReconnect(
    after error: NativePlayerError,
    generation reconnectGeneration: UInt64
  ) {
    guard stateLock.withLock({
      !disposed && active && reconfiguring && generation == reconnectGeneration
    }) else { return }
    guard let delayMs = liveReconnectController.nextDelayMs() else {
      finishLiveReconnectExhausted(error, generation: reconnectGeneration)
      return
    }

    let attempt = liveReconnectController.attempt
    DispatchQueue.main.async { [weak self] in
      guard let self,
            self.stateLock.withLock({
              self.active && self.reconfiguring
                && self.generation == reconnectGeneration
            }) else { return }
      self.emit(YlFallbackRetryEvent.envelope(
        playerId: self.playerId,
        attempt: attempt,
        delayMs: delayMs,
        error: error
      ))
    }

    let workItem = DispatchWorkItem { [weak self] in
      self?.performLiveReconnect(generation: reconnectGeneration)
    }
    let installed = stateLock.withLock { () -> Bool in
      guard !disposed, active, reconfiguring, generation == reconnectGeneration
      else { return false }
      reconnectWorkItem?.cancel()
      reconnectWorkItem = workItem
      return true
    }
    guard installed else { return }
    worker.asyncAfter(
      deadline: .now() + .milliseconds(Int(delayMs)),
      execute: workItem
    )
  }

  private func performLiveReconnect(generation reconnectGeneration: UInt64) {
    guard liveReconnectController.shouldInstall(
      reconnectGeneration: reconnectGeneration,
      currentGeneration: stateLock.withLock { generation }
    ) else { return }

    let token = YlOpenCancellationToken()
    let mayOpen = stateLock.withLock { () -> Bool in
      guard !disposed, active, reconfiguring, generation == reconnectGeneration
      else { return false }
      reconnectWorkItem = nil
      sourceCancellationToken = token
      return true
    }
    guard mayOpen else { return }

    do {
      let candidate = try makeLiveReconnectPipeline(
        generation: reconnectGeneration,
        cancellationToken: token
      )
      try token.throwIfCancelled()
      let installed = stateLock.withLock { () -> Bool in
        guard !disposed, active, reconfiguring,
              generation == reconnectGeneration,
              sourceCancellationToken === token,
              liveReconnectController.shouldInstall(
                reconnectGeneration: reconnectGeneration,
                currentGeneration: generation
              ) else { return false }
        mediaInfo = candidate.info
        videoStream = candidate.videoStream
        audioStreams = candidate.audioStreams
        audioCookies = candidate.audioCookies
        videoFormat = candidate.videoFormat
        selectedAudioStream = candidate.selectedAudioStream
        openedMedia = candidate.media
        decoder = candidate.decoder
        audioRenderer = candidate.audioRenderer
        pendingAudioPacket = nil
        prebufferedVideoSample = false
        demuxEOF = false
        completionSent = false
        audioAnchored = false
        awaitingReconnectFirstFrame = true
        currentError = nil
        return true
      }
      guard installed else {
        candidate.discard()
        return
      }

      stateLock.withLock { initialKeyframeGate.reset() }
      frameScheduler.flush(generation: reconnectGeneration)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        let shouldResume = self.stateLock.withLock { () -> Bool in
          guard !self.disposed, self.active, self.reconfiguring,
                self.generation == reconnectGeneration else { return false }
          self.reconfiguring = false
          return true
        }
        guard shouldResume else { return }
        self.mediaClock.seek(to: 0)
        if self.playing {
          do {
            if self.selectedAudioStream != nil { try self.audioRenderer?.play() }
            self.mediaClock.play(atHostTimeUs: Self.hostTimeUs())
            self.status = "playing"
          } catch {
            self.setFailure(NativePlayerError(
              category: "decoderFailure",
              code: "decoder.audio_failed",
              message: "The reconnected audio renderer could not start.",
              diagnostic: String(describing: error)
            ))
            return
          }
        } else {
          self.status = "paused"
        }
        self.emit([
          "playerId": self.playerId,
          "type": "tracksChanged",
          "audioTracks": self.audioTracks,
          "videoTracks": self.videoTracks,
        ])
        self.emitState()
        self.requestPump()
      }
    } catch let error as NativePlayerError {
      let shouldRetry = stateLock.withLock { () -> Bool in
        if sourceCancellationToken === token { sourceCancellationToken = nil }
        return !disposed && active && reconfiguring
          && generation == reconnectGeneration && !token.isCancelled
      }
      if shouldRetry { scheduleLiveReconnect(after: error, generation: reconnectGeneration) }
    } catch {
      let shouldRetry = stateLock.withLock { () -> Bool in
        if sourceCancellationToken === token { sourceCancellationToken = nil }
        return !disposed && active && reconfiguring
          && generation == reconnectGeneration && !token.isCancelled
      }
      if shouldRetry {
        scheduleLiveReconnect(
          after: NativePlayerError(
            category: "network",
            code: "network.http_status",
            message: "The HTTP-FLV reconnect failed.",
            diagnostic: String(describing: error)
          ),
          generation: reconnectGeneration
        )
      }
    }
  }

  private func finishLiveReconnectExhausted(
    _ lastError: NativePlayerError,
    generation reconnectGeneration: UInt64
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let shouldFail = self.stateLock.withLock { () -> Bool in
        guard !self.disposed, self.active, self.reconfiguring,
              self.generation == reconnectGeneration else { return false }
        self.reconfiguring = false
        self.playing = false
        return true
      }
      guard shouldFail else { return }
      self.displayLink?.isPaused = true
      self.setFailure(NativePlayerError(
        category: "network",
        code: "network.retry_exhausted",
        message: "HTTP-FLV reconnect attempts were exhausted.",
        diagnostic: lastError.code
      ))
    }
  }

  private func seek(
    toMs positionMs: Int64,
    cancellationToken: YlOpenCancellationToken?
  ) throws {
    let targetUs = max(0, positionMs) * 1_000
    try YlFallbackSeekPolicy(isSeekable: isSeekable) { _ in }.seek(toUs: targetUs)
    try cancellationToken?.throwIfCancelled()
    if cancellationToken == nil, !stateLock.withLock({ active }) {
      onMainSync {
        savedPositionUs = targetUs
        mediaClock.seek(to: targetUs)
        emitState()
      }
      return
    }
    let entry = try onMainSync {
      try cancellationToken?.throwIfCancelled()
      let value = try stateLock.withLock {
        guard !disposed, active, !reconfiguring, let media = openedMedia else {
          throw YlOpenCancellationToken.cancellationError()
        }
        let entryGeneration = generation
        reconfiguring = true
        pumping = false
        return (media: media, wasPlaying: playing, generation: entryGeneration)
      }
      status = "buffering"
      emitState()
      return value
    }
    let media = entry.media
    let wasPlaying = entry.wasPlaying
    media.beginControlOperation(cancellationToken)
    var controlOperationEnded = false
    func endControlOperation() {
      guard !controlOperationEnded else { return }
      controlOperationEnded = true
      media.endControlOperation()
      media.resumeReads()
    }
    defer { endControlOperation() }
    var operationGeneration = UInt64(0)
    let transaction = YlFallbackLifecycleTransaction(
      pauseClock: { [self] in
        try onMainSync {
          try cancellationToken?.throwIfCancelled()
          audioRenderer?.pause()
          mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
        }
      },
      advanceGeneration: { [self] in
        try cancellationToken?.throwIfCancelled()
        return try stateLock.withLock {
          guard !disposed, active, generation == entry.generation,
                openedMedia === media else {
            throw YlOpenCancellationToken.cancellationError()
          }
          generation &+= 1
          operationGeneration = generation
          return operationGeneration
        }
      },
      stopDemux: { [self] in
        media.interruptRead()
        worker.sync {}
        media.resumeReads()
        try cancellationToken?.throwIfCancelled()
      },
      clearBuffers: { [self] nextGeneration in
        pendingAudioPacket = nil
        prebufferedVideoSample = false
        demuxEOF = false
        completionSent = false
        audioAnchored = false
        frameScheduler.flush(generation: nextGeneration)
        stateLock.withLock { currentPixelBuffer = nil }
      },
      seekDemux: { [self] targetUs in
        try cancellationToken?.throwIfCancelled()
        try media.seek(toMediaTimeUs: targetUs)
        try cancellationToken?.throwIfCancelled()
      },
      resetAudio: { [self] nextGeneration in
        audioRenderer?.reset(generation: nextGeneration)
        stateLock.withLock { audioGeneration = nextGeneration }
      },
      recreateVideo: { [self] _ in
        let candidate = try makeDecoder()
        let previous = decoder
        decoder = candidate
        previous?.dispose()
      },
      suppressFramesBefore: { [self] targetUs in
        onMainSync {
          postSeekGate.reset(targetUs: targetUs)
          mediaClock.seek(to: targetUs)
        }
      },
      restartDemux: { [self] in
        try onMainSync {
          try cancellationToken?.throwIfCancelled()
          guard stateLock.withLock({ active && generation == operationGeneration }) else {
            throw YlOpenCancellationToken.cancellationError()
          }
          stateLock.withLock {
            reconfiguring = false
            playing = wasPlaying
          }
          if wasPlaying {
            if selectedAudioStream != nil { try audioRenderer?.play() }
            mediaClock.play(atHostTimeUs: Self.hostTimeUs())
            status = "playing"
          } else {
            status = "paused"
          }
        }
      }
    )
    do {
      try transaction.seek(toUs: targetUs)
      try cancellationToken?.throwIfCancelled()
      endControlOperation()
      try onMainSync {
        try cancellationToken?.throwIfCancelled()
        guard stateLock.withLock({
          active && generation == operationGeneration && openedMedia === media
        }) else {
          throw YlOpenCancellationToken.cancellationError()
        }
        requestPump()
        emitState()
      }
    } catch let error as NativePlayerError {
      endControlOperation()
      if cancellationToken?.isCancelled == true || error.code == "network.cancelled" {
        transitionToCancelledSeek(
          wasPlaying: wasPlaying,
          operationGeneration: operationGeneration
        )
        throw YlOpenCancellationToken.cancellationError()
      } else {
        transitionToTerminalSeekFailure(
          error,
          operationGeneration: operationGeneration
        )
      }
      throw error
    } catch {
      let nativeError = NativePlayerError(
        category: "container",
        code: "container.mkv_seek_failed",
        message: "The Matroska media could not be seeked.",
        diagnostic: String(describing: error)
      )
      endControlOperation()
      if cancellationToken?.isCancelled == true {
        transitionToCancelledSeek(
          wasPlaying: wasPlaying,
          operationGeneration: operationGeneration
        )
        throw YlOpenCancellationToken.cancellationError()
      }
      transitionToTerminalSeekFailure(
        nativeError,
        operationGeneration: operationGeneration
      )
      throw nativeError
    }
  }

  private func transitionToCancelledSeek(
    wasPlaying: Bool,
    operationGeneration: UInt64
  ) {
    guard stateLock.withLock({ active && generation == operationGeneration }) else {
      return
    }
    onMainSync {
      let shouldRestore = stateLock.withLock { () -> Bool in
        guard active && generation == operationGeneration else { return false }
        reconfiguring = false
        pumping = false
        playing = wasPlaying
        return true
      }
      guard shouldRestore else { return }
      if wasPlaying {
        try? audioRenderer?.play()
        mediaClock.play(atHostTimeUs: Self.hostTimeUs())
        status = "playing"
      } else {
        status = "paused"
      }
      requestPump()
      emitState()
    }
  }

  private func transitionToTerminalSeekFailure(
    _ error: NativePlayerError,
    operationGeneration: UInt64
  ) {
    guard stateLock.withLock({ active && generation == operationGeneration }) else {
      return
    }
    onMainSync {
      let shouldFail = stateLock.withLock { () -> Bool in
        guard active && generation == operationGeneration else { return false }
        reconfiguring = false
        pumping = false
        playing = false
        return true
      }
      guard shouldFail else { return }
      audioRenderer?.pause()
      mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
      displayLink?.isPaused = true
      setFailure(error)
    }
  }

  private func makeDecoder() throws -> YlVideoToolboxDecoder {
    try YlVideoToolboxDecoder(
      formatDescription: videoFormat,
      onFrame: { [outputRelay] frame in outputRelay.frame(frame) },
      onError: { [outputRelay] error in outputRelay.error(error) }
    )
  }

  private func makeLiveReconnectPipeline(
    generation reconnectGeneration: UInt64,
    cancellationToken: YlOpenCancellationToken
  ) throws -> YlFallbackReconnectPipeline {
    try cancellationToken.throwIfCancelled()
    let reopenedMedia = try YlOpenedMedia(
      recipe: sourceRecipe,
      networkBufferBytes: bufferBudget.networkBytes,
      sessionConfiguration: sessionConfiguration,
      onSourceCreated: { source in
        cancellationToken.onCancel { source.cancel() }
      }
    )
    var keepMedia = false
    var candidateDecoder: YlVideoToolboxDecoder?
    var candidateAudio: YlAudioRenderer?
    defer {
      if !keepMedia {
        candidateDecoder?.dispose()
        candidateAudio?.dispose()
        reopenedMedia.cancelInput()
        reopenedMedia.close()
      }
    }
    try cancellationToken.throwIfCancelled()
    guard let validContext = reopenedMedia.context else {
      throw NativePlayerError(
        category: "internal",
        code: "internal.fallback_invariant",
        message: "The reconnected FLV context was unavailable."
      )
    }

    let info = reopenedMedia.info
    var selectedVideo: YLFStreamInfo?
    var supportedAudio: [YLFStreamInfo] = []
    var sawUnsupportedAudio = false
    for index in 0..<info.stream_count {
      var stream = YLFStreamInfo()
      guard ylf_copy_stream_info(validContext, index, &stream) == 0 else { continue }
      if Int(stream.kind) == YLFStreamVideo,
         (Int(stream.codec) == YLFCodecH264 || Int(stream.codec) == YLFCodecHEVC),
         selectedVideo == nil {
        selectedVideo = stream
      } else if Int(stream.kind) == YLFStreamAudio {
        if Int(stream.codec) == YLFCodecAAC || Int(stream.codec) == YLFCodecMP3 {
          supportedAudio.append(stream)
        } else {
          sawUnsupportedAudio = true
        }
      }
    }
    guard let selectedVideo else {
      throw NativePlayerError(
        category: "decoderUnsupported",
        code: "decoder.video_hardware_unavailable",
        message: "The reconnected FLV stream has no supported H.264 or H.265 video."
      )
    }
    if supportedAudio.isEmpty && sawUnsupportedAudio {
      throw NativePlayerError(
        category: "decoderUnsupported",
        code: "decoder.audio_aac_unsupported",
        message: "The reconnected FLV audio track is not AAC or MP3."
      )
    }

    var copiedAudioCookies: [Int32: Data] = [:]
    for audioStream in supportedAudio where Int(audioStream.codec) == YLFCodecAAC {
      let size = ylf_stream_codec_config_size(validContext, audioStream.index)
      guard size > 0 else {
        throw NativePlayerError(
          category: "decoderUnsupported",
          code: "decoder.audio_aac_unsupported",
          message: "The reconnected AAC codec configuration is missing."
        )
      }
      var bytes = [UInt8](repeating: 0, count: size)
      guard ylf_copy_stream_codec_config(
        validContext,
        audioStream.index,
        &bytes,
        bytes.count
      ) == 0 else {
        throw NativePlayerError(
          category: "decoderUnsupported",
          code: "decoder.audio_aac_unsupported",
          message: "The reconnected AAC codec configuration is invalid."
        )
      }
      copiedAudioCookies[audioStream.index] = Data(bytes)
    }

    let candidateFormat = try YlVideoToolboxDecoder.makeFormatDescription(
      context: validContext,
      streamIndex: selectedVideo.index
    )
    let newDecoder = try YlVideoToolboxDecoder(
      formatDescription: candidateFormat,
      onFrame: { [outputRelay] frame in outputRelay.frame(frame) },
      onError: { [outputRelay] error in outputRelay.error(error) }
    )
    candidateDecoder = newDecoder

    let preferredAudioIndex = selectedAudioStream?.index
    let reselectedAudio = preferredAudioIndex.flatMap { preferredIndex in
      supportedAudio.first { $0.index == preferredIndex }
    } ?? supportedAudio.first
    let newAudioRenderer = YlAudioRenderer(bufferBudget: bufferBudget)
    candidateAudio = newAudioRenderer
    if let reselectedAudio {
      try newAudioRenderer.configure(stream: YlAudioStreamConfiguration(
        codec: Int(reselectedAudio.codec) == YLFCodecAAC ? .aac : .mp3,
        sampleRate: Double(reselectedAudio.sample_rate),
        channelCount: Int(reselectedAudio.channel_count),
        magicCookie: copiedAudioCookies[reselectedAudio.index] ?? Data(),
        generation: reconnectGeneration
      ))
      newAudioRenderer.setVolume(desiredVolume)
      newAudioRenderer.setRate(desiredRate)
    }
    try cancellationToken.throwIfCancelled()

    keepMedia = true
    candidateDecoder = nil
    candidateAudio = nil
    return YlFallbackReconnectPipeline(
      media: reopenedMedia,
      info: info,
      videoStream: selectedVideo,
      audioStreams: supportedAudio,
      audioCookies: copiedAudioCookies,
      videoFormat: candidateFormat,
      selectedAudioStream: reselectedAudio,
      decoder: newDecoder,
      audioRenderer: newAudioRenderer
    )
  }

  private func rebuildPipeline(positionUs: Int64) throws {
    let reopenedMedia = try YlOpenedMedia(
      recipe: sourceRecipe,
      networkBufferBytes: bufferBudget.networkBytes,
      sessionConfiguration: sessionConfiguration
    )
    guard let validContext = reopenedMedia.context else {
      reopenedMedia.close()
      throw NativePlayerError(
        category: "internal",
        code: "internal.fallback_invariant",
        message: "The reopened Matroska context was unavailable."
      )
    }

    var mediaNeedsClose = true
    var candidateDecoder: YlVideoToolboxDecoder?
    var candidateAudio: YlAudioRenderer?
    defer {
      if mediaNeedsClose {
        candidateDecoder?.dispose()
        candidateAudio?.dispose()
        reopenedMedia.close()
      }
    }

    let candidateFormat = try YlVideoToolboxDecoder.makeFormatDescription(
      context: validContext,
      streamIndex: videoStream.index
    )
    candidateDecoder = try YlVideoToolboxDecoder(
      formatDescription: candidateFormat,
      onFrame: { [outputRelay] frame in outputRelay.frame(frame) },
      onError: { [outputRelay] error in outputRelay.error(error) }
    )
    let renderer = YlAudioRenderer(bufferBudget: bufferBudget)
    candidateAudio = renderer
    if let selectedAudioStream {
      try renderer.configure(stream: audioConfiguration(
        for: selectedAudioStream,
        generation: audioGeneration
      ))
      renderer.setVolume(desiredVolume)
      renderer.setRate(desiredRate)
    }
    if positionUs > 0 {
      try reopenedMedia.seek(toMediaTimeUs: positionUs)
      postSeekGate.reset(targetUs: positionUs)
    }

    videoFormat = candidateFormat
    openedMedia = reopenedMedia
    decoder = candidateDecoder
    candidateDecoder = nil
    audioRenderer = renderer
    candidateAudio = nil
    pendingAudioPacket = nil
    prebufferedVideoSample = false
    stateLock.withLock { initialKeyframeGate.reset() }
    demuxEOF = false
    completionSent = false
    audioAnchored = false
    frameScheduler.flush(generation: generation)
    mediaClock.seek(to: positionUs)
    mediaNeedsClose = false
  }

  private func installDisplayLink(paused: Bool) {
    guard displayLink == nil else {
      displayLink?.isPaused = paused
      return
    }
    let link = CADisplayLink(target: self, selector: #selector(displayLinkTick))
    if #available(iOS 15.0, *) {
      link.preferredFrameRateRange = CAFrameRateRange(
        minimum: 15,
        maximum: 60,
        preferred: 30
      )
    } else {
      link.preferredFramesPerSecond = 30
    }
    link.add(to: .main, forMode: .common)
    link.isPaused = paused
    displayLink = link
  }

  private func completeIfDrained(atHostTimeUs hostTimeUs: Int64) {
    let shouldComplete = stateLock.withLock {
      active && playing && demuxEOF && !completionSent && pendingAudioPacket == nil
    }
    guard shouldComplete,
          frameScheduler.pendingPTS.isEmpty,
          (audioRenderer?.scheduledDurationUs ?? 0) == 0 else { return }
    stateLock.withLock {
      guard !completionSent else { return }
      completionSent = true
      playing = false
    }
    mediaClock.pause(atHostTimeUs: hostTimeUs)
    displayLink?.isPaused = true
    status = "completed"
    emitState()
  }

  private func setFailure(_ error: NativePlayerError) {
    guard !stateLock.withLock({ disposed }) else { return }
    status = "error"
    let details = errorMap(
      category: error.category,
      code: error.code,
      message: error.message,
      diagnostic: error.diagnostic
    )
    currentError = details
    emit(["playerId": playerId, "type": "error", "error": details])
    emitState()
  }

  private func selectAudioTrack(
    _ trackId: String?,
    cancellationToken: YlOpenCancellationToken?
  ) throws {
    try cancellationToken?.throwIfCancelled()
    guard let trackId, trackId.hasPrefix("audio-"),
          let requestedIndex = Int32(trackId.dropFirst("audio-".count)),
          let requestedStream = audioStreams.first(where: { $0.index == requestedIndex }) else {
      throw NativePlayerError(
        category: "source",
        code: "track.not_found",
        message: "The requested audio track is unavailable."
      )
    }
    guard requestedStream.index != selectedAudioStream?.index else { return }

    if cancellationToken == nil, !stateLock.withLock({ active }) {
      onMainSync {
        selectedAudioStream = requestedStream
        stateLock.withLock { audioGeneration &+= 1 }
        emit([
          "playerId": playerId,
          "type": "tracksChanged",
          "audioTracks": audioTracks,
          "videoTracks": videoTracks,
        ])
        emitState()
      }
      return
    }

    let nextAudioGeneration = stateLock.withLock { audioGeneration &+ 1 }
    let candidate = YlAudioRenderer(bufferBudget: bufferBudget)
    do {
      try candidate.configure(stream: audioConfiguration(
        for: requestedStream,
        generation: nextAudioGeneration
      ))
      candidate.setVolume(desiredVolume)
      candidate.setRate(desiredRate)
    } catch {
      candidate.dispose()
      throw error
    }
    var candidateOwnedByBackend = false
    defer {
      if !candidateOwnedByBackend { candidate.dispose() }
    }

    let state = try onMainSync {
      try cancellationToken?.throwIfCancelled()
      let now = Self.hostTimeUs()
      let positionUs = mediaClock.position(atHostTimeUs: now)
      let value = try stateLock.withLock {
        guard !disposed, active, !reconfiguring, let media = openedMedia else {
          throw YlOpenCancellationToken.cancellationError()
        }
        let entryGeneration = generation
        reconfiguring = true
        pumping = false
        return (
          media: media,
          positionUs: positionUs,
          wasPlaying: playing,
          generation: entryGeneration
        )
      }
      mediaClock.pause(atHostTimeUs: now)
      return value
    }
    let media = state.media
    media.beginControlOperation(cancellationToken)
    var controlOperationEnded = false
    func endControlOperation() {
      guard !controlOperationEnded else { return }
      controlOperationEnded = true
      media.endControlOperation()
      media.resumeReads()
    }
    defer { endControlOperation() }
    media.interruptRead()
    worker.sync {}
    media.resumeReads()
    try cancellationToken?.throwIfCancelled()
    do {
      try onMainSync {
        try cancellationToken?.throwIfCancelled()
        guard stateLock.withLock({
          active && generation == state.generation && openedMedia === media
        }) else {
          throw YlOpenCancellationToken.cancellationError()
        }
        let previous = audioRenderer
        audioRenderer = candidate
        candidateOwnedByBackend = true
        selectedAudioStream = requestedStream
        pendingAudioPacket = nil
        audioAnchored = false
        stateLock.withLock {
          audioGeneration = nextAudioGeneration
          reconfiguring = false
        }
        previous?.dispose()
        mediaClock.seek(to: state.positionUs)
        if state.wasPlaying {
          try candidate.play()
          mediaClock.play(atHostTimeUs: Self.hostTimeUs())
        }
        emit([
          "playerId": playerId,
          "type": "tracksChanged",
          "audioTracks": audioTracks,
          "videoTracks": videoTracks,
        ])
      }
      try cancellationToken?.throwIfCancelled()
      endControlOperation()
      try onMainSync {
        try cancellationToken?.throwIfCancelled()
        guard stateLock.withLock({
          active && generation == state.generation && openedMedia === media
        }) else {
          throw YlOpenCancellationToken.cancellationError()
        }
        requestPump()
        emitState()
      }
    } catch let error as NativePlayerError {
      endControlOperation()
      if cancellationToken?.isCancelled == true || error.code == "network.cancelled" {
        transitionToCancelledAudioSwitch(state)
        throw YlOpenCancellationToken.cancellationError()
      }
      transitionToTerminalSeekFailure(
        error,
        operationGeneration: state.generation
      )
      throw error
    } catch {
      let nativeError = NativePlayerError(
        category: "decoderFailure",
        code: "decoder.audio_failed",
        message: "The selected \(audioCodecName(requestedStream)) track could not be started.",
        diagnostic: String(describing: error)
      )
      endControlOperation()
      if cancellationToken?.isCancelled == true {
        transitionToCancelledAudioSwitch(state)
        throw YlOpenCancellationToken.cancellationError()
      }
      transitionToTerminalSeekFailure(
        nativeError,
        operationGeneration: state.generation
      )
      throw nativeError
    }
  }

  private func transitionToCancelledAudioSwitch(
    _ state: (
      media: YlOpenedMedia,
      positionUs: Int64,
      wasPlaying: Bool,
      generation: UInt64
    )
  ) {
    guard stateLock.withLock({ active && generation == state.generation }) else {
      return
    }
    onMainSync {
      let shouldRestore = stateLock.withLock { () -> Bool in
        guard active && generation == state.generation else { return false }
        reconfiguring = false
        pumping = false
        playing = state.wasPlaying
        return true
      }
      guard shouldRestore else { return }
      mediaClock.seek(to: state.positionUs)
      if state.wasPlaying {
        try? audioRenderer?.play()
        mediaClock.play(atHostTimeUs: Self.hostTimeUs())
        status = "playing"
      } else {
        status = "paused"
      }
      requestPump()
      emitState()
    }
  }

  private func onMainSync<T>(_ body: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try body() }
    return try DispatchQueue.main.sync(execute: body)
  }

  private func anchorAudioIfNeeded(_ packet: YlCompressedAudioPacket) {
    guard !audioAnchored else { return }
    audioAnchored = true
    mediaClock.anchorAudio(
      ptsUs: max(0, packet.ptsUs),
      sampleTime: audioRenderer?.renderedAudioTime?.sampleTime ?? 0
    )
  }

  private func audioConfiguration(
    for stream: YLFStreamInfo,
    generation: UInt64
  ) -> YlAudioStreamConfiguration {
    YlAudioStreamConfiguration(
      codec: Int(stream.codec) == YLFCodecAAC
        ? .aac : (Int(stream.codec) == YLFCodecMP3 ? .mp3 : .unsupported),
      sampleRate: Double(stream.sample_rate),
      channelCount: Int(stream.channel_count),
      magicCookie: audioCookies[stream.index] ?? Data(),
      generation: generation
    )
  }

  private func audioCodecName(_ stream: YLFStreamInfo) -> String {
    Int(stream.codec) == YLFCodecMP3 ? "MP3" : "AAC"
  }

  private var selectedAudioCodecName: String {
    selectedAudioStream.map(audioCodecName) ?? "Compressed"
  }

  private var audioTracks: [[String: Any?]] {
    audioStreams.map { audioStream in
      [
        "id": "audio-\(audioStream.index)",
        "kind": "audio",
        "label": "\(audioCodecName(audioStream)) \(audioStream.index)",
        "language": nil,
        "isSelected": audioStream.index == selectedAudioStream?.index,
      ]
    }
  }

  private var videoTracks: [[String: Any?]] {
    [[
      "id": "video-\(videoStream.index)",
      "kind": "video",
      "width": Int(videoStream.width),
      "height": Int(videoStream.height),
      "bitrate": nil,
      "isSelected": true,
    ]]
  }

  private static func hostTimeUs() -> Int64 {
    Int64(CACurrentMediaTime() * 1_000_000)
  }

  deinit {
    dispose()
  }
}

private extension NSLock {
  func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
