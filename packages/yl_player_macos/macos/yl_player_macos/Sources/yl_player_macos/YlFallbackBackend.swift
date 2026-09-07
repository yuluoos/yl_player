import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import FlutterMacOS
import QuartzCore
import YlFFmpegBridge

func ylFallbackPacketReadError(
  result: Int32,
  inputError: NativePlayerError?,
  container: YlFallbackContainer
) -> NativePlayerError {
  if result == Int32(YLFResultCallbackFailed), let inputError {
    return inputError
  }
  return NativePlayerError(
    category: "container",
    code: container == .flv
      ? "container.flv_malformed" : "container.mkv_malformed",
    message: container == .flv
      ? "The FLV packet stream is malformed."
      : "The Matroska packet stream is malformed.",
    diagnostic: "YlFFmpegBridge result \(result)"
  )
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
  var playbackIntent: Bool { stateLock.withLock { playing } }
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

  private weak var displayView: NSView?
  private let textures: FlutterTextureRegistry
  private let videoSessionFactory: YlVTSessionFactory
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
  private var qualityConstraint: YlFallbackQualityConstraint
  private let worker = DispatchQueue(label: "dev.ylplayer.macos.fallback.demux")
  private let videoSubmissions = YlVideoSubmissionQueue()
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
  private var displayLink: YlDisplayTimer?
  private var currentPixelBuffer: CVPixelBuffer?
  private var active = false
  private var playing = false
  private var stopped = false
  private var resetting = false
  private var disposed = false
  private var pumping = false
  private var reconfiguring = false
  private var reconnectWorkItem: DispatchWorkItem?
  private var awaitingReconnectFirstFrame = false
  private var generation: UInt64
  private var channelGeneration = YlMacosChannelGeneration.next()
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

  private var currentAudioRenderer: YlAudioRenderer? {
    stateLock.withLock { audioRenderer }
  }

  init(
    playerId: Int64,
    textureId: Int64,
    textures: FlutterTextureRegistry,
    configuration: PlayerConfiguration,
    prepared: YlPreparedFallback,
    qualityConstraint: YlFallbackQualityConstraint = .unconstrained,
    generation: UInt64,
    videoSessionFactory: YlVTSessionFactory = YlHardwareVTSessionFactory(),
    mediaClock: YlMediaClock? = nil,
    displayView: NSView? = nil,
    emit: @escaping ([String: Any?]) -> Void
  ) throws {
    try YlFallbackQualityPolicy.validate(
      constraint: qualityConstraint,
      stream: Self.videoDescriptor(prepared.videoStream)
    )
    self.playerId = playerId
    self.textureId = textureId
    self.displayView = displayView
    self.textures = textures
    self.configuration = configuration
    self.videoSessionFactory = videoSessionFactory
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
    self.qualityConstraint = qualityConstraint
    self.generation = generation
    self.audioGeneration = generation
    self.emit = emit
    self.openedMedia = try prepared.takeMedia()
    self.sourceCancellationToken = prepared.takeCancellationToken()
    self.playing = resumeState?.shouldPlay ?? false
    self.savedPositionUs = resumeState?.positionUs ?? 0
    super.init()

    audioRenderer = YlAudioRenderer(bufferBudget: bufferBudget)
    self.mediaClock = mediaClock ?? YlMediaClock(audioTime: { [weak self] in
      guard let self else { return nil }
      let renderer = self.stateLock.withLock { self.audioRenderer }
      return renderer?.renderedAudioTime
    })
    self.mediaClock.seek(to: savedPositionUs)
    outputRelay.backend = self
    do {
      decoder = try YlVideoToolboxDecoder(
        formatDescription: videoFormat,
        maxInFlightBytes: bufferBudget.inFlightPacketBytes,
        factory: videoSessionFactory,
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
    guard !stateLock.withLock({ stopped }) else { return }
    let shouldActivate = try stateLock.withLock {
      try YlFallbackActivationPolicy.shouldActivate(
        disposed: disposed,
        active: active,
        hasTerminalError: currentError != nil
      )
    }
    guard shouldActivate else { return }
    if requiresAsyncActivation {
      throw NativePlayerError(
        category: "internal",
        code: "macos.async_activation_required",
        message: "Network Matroska reactivation requires background preparation."
      )
    }
    if context == nil || audioRenderer == nil {
      try rebuildPipeline(positionUs: savedPositionUs)
    } else if decoder == nil {
      decoder = try makeDecoder()
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
    releaseMediaForStopOrDeactivation(stopping: false)
  }

  func stop() {
    releaseMediaForStopOrDeactivation(stopping: true)
  }

  private func releaseMediaForStopOrDeactivation(stopping: Bool) {
    stateLock.lock()
    guard !disposed,
          stopping || active || openedMedia != nil || decoder != nil || audioRenderer != nil else {
      stateLock.unlock()
      return
    }
    if active && !stopping {
      savedPositionUs = mediaClock.position(atHostTimeUs: Self.hostTimeUs())
    }
    resetting = stopping
    if stopping { stopped = true; playing = false }
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
    if stopping { liveReconnectController.cancel() }
    reconnectToCancel?.cancel()
    displayLink?.invalidate()
    displayLink = nil
    currentAudioRenderer?.pause()
    mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
    YlFallbackTeardownTransaction(
      cancelInput: { [self] in
        tokenToCancel?.cancel()
        mediaToClose?.cancelInput()
      },
      joinAndRelease: { [self] in
        worker.sync {
          pendingAudioPacket = nil
          cancelVideoSubmissions()
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
    if stopping {
      channelGeneration = YlMacosChannelGeneration.next()
      savedPositionUs = 0
      openDurationMs = nil
      firstFrameDurationMs = nil
      firstFrameSent = false
      reconnectCount = 0
      awaitingReconnectFirstFrame = false
      currentError = nil
      selectedAudioStream = nil
      audioStreams.removeAll()
      audioCookies.removeAll()
      isSeekable = false
    }
    mediaClock.seek(to: savedPositionUs)
    status = stopping ? "idle" : "paused"
    resetting = false
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
    let reconnectTokenToCancel = media == nil ? sourceCancellationToken : nil
    if reconnectTokenToCancel != nil { sourceCancellationToken = nil }
    stateLock.unlock()

    reconnectToCancel?.cancel()
    reconnectTokenToCancel?.cancel()

    displayLink?.invalidate()
    displayLink = nil
    currentAudioRenderer?.pause()
    mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
    media?.interruptRead()
    worker.sync {
      pendingAudioPacket = nil
      cancelVideoSubmissions()
      decoder?.dispose()
      decoder = nil
    }
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

  func reportRestorationFailure(_ error: NativePlayerError) {
    deactivate()
    let details = errorMap(
      category: error.category,
      code: error.code,
      message: error.message,
      diagnostic: error.diagnostic
    )
    let shouldEmit = stateLock.withLock { () -> Bool in
      guard !disposed, !stopped, currentError == nil else { return false }
      active = false
      playing = false
      reconfiguring = false
      pumping = false
      status = "error"
      currentError = details
      return true
    }
    guard shouldEmit else { return }
    emit(YlFallbackErrorEvent(playerId: playerId, error: details).eventMap)
    emitState()
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
    if stateLock.withLock({ stopped }),
       !["setVolume", "setPlaybackSpeed", "stop"].contains(name) { return }
    switch name {
    case "stop":
      stop()
    case "open":
      emitState()
    case "play":
      let wasPlaying = stateLock.withLock { () -> Bool in
        let previous = playing
        playing = true
        return previous
      }
      if !wasPlaying {
        if selectedAudioStream != nil { try currentAudioRenderer?.play() }
        mediaClock.play(atHostTimeUs: Self.hostTimeUs())
      }
      status = "playing"
      emitState()
      requestPump()
    case "pause":
      stateLock.withLock { playing = false }
      if selectedAudioStream != nil { currentAudioRenderer?.pause() }
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
      mediaClock.setRate(Double(rate), atHostTimeUs: Self.hostTimeUs())
      if selectedAudioStream != nil { currentAudioRenderer?.setRate(rate) }
    case "setVolume":
      desiredVolume = float(arguments["volume"]) ?? 1
      if selectedAudioStream != nil {
        currentAudioRenderer?.setVolume(desiredVolume)
      }
    case "selectAudioTrack":
      try selectAudioTrack(
        arguments["trackId"] as? String,
        cancellationToken: cancellationToken
      )
    case "setQualityConstraint":
      let constraint = try YlFallbackQualityConstraint(
        validating: stringMap(arguments["constraint"])
      )
      let currentStream = stateLock.withLock { videoStream }
      try YlFallbackQualityPolicy.validate(
        constraint: constraint,
        stream: Self.videoDescriptor(currentStream)
      )
      stateLock.withLock { qualityConstraint = constraint }
    default:
      throw NativePlayerError(
        category: "internal",
        code: "macos.command_unknown",
        message: "Unknown player command: \(name)"
      )
    }
  }

  func emitState() {
    guard !stateLock.withLock({ disposed || resetting }) else { return }
    if stateLock.withLock({ stopped }) {
      emit(YlMacosChannel.fullState(
        playerId: playerId, generation: channelGeneration,
        state: [
          "status": "idle", "positionMs": Int64(0), "durationMs": nil,
          "bufferedPositionMs": Int64(0), "isLive": false, "isSeekable": false,
          "isAtLiveEdge": false, "liveOffsetMs": nil, "dvrStartMs": nil, "dvrEndMs": nil,
          "videoWidth": nil, "videoHeight": nil, "engine": "nativeFallback",
          "isHardwareDecoding": false, "decoderName": nil,
          "audioTracks": [], "videoTracks": [], "error": nil,
          "capabilities": YlMacosChannel.deviceCapabilities,
          "metrics": YlMacosChannel.fallbackMetrics(
            openDurationMs: nil, firstFrameDurationMs: nil, bufferedDurationMs: 0,
            bufferedBytes: 0, droppedVideoFrames: 0, audioUnderruns: 0, reconnectCount: 0
          ),
        ]
      ))
      return
    }
    let positionUs = mediaClock.position(atHostTimeUs: Self.hostTimeUs())
    let durationMs = mediaPolicy.durationMs(mediaDurationUs: mediaInfo.duration_us)
    let renderer = currentAudioRenderer
    let scheduledAudioDurationUs = renderer?.scheduledDurationUs ?? 0
    let scheduledAudioBytes = renderer?.scheduledBytes ?? 0
    let audioUnderruns = renderer?.underrunCount ?? 0
    let metrics = YlMacosChannel.fallbackMetrics(
      openDurationMs: openDurationMs,
      firstFrameDurationMs: firstFrameDurationMs,
      bufferedDurationMs: scheduledAudioDurationUs / 1_000,
      bufferedBytes: scheduledAudioBytes,
      droppedVideoFrames: frameScheduler.lateFrameDropCount,
      audioUnderruns: audioUnderruns,
      reconnectCount: reconnectCount
    )
    emit(YlMacosChannel.fullState(
      playerId: playerId,
      generation: channelGeneration,
      state: YlFallbackStateSnapshot(
        status: status,
        positionMs: positionUs / 1_000,
        durationMs: durationMs,
        bufferedPositionMs: (positionUs + scheduledAudioDurationUs) / 1_000,
        isLive: mediaPolicy.isLive,
        isSeekable: isSeekable,
        isAtLiveEdge: mediaPolicy.isLive,
        liveOffsetMs: nil,
        dvrStartMs: nil,
        dvrEndMs: nil,
        videoWidth: Int(videoStream.width),
        videoHeight: Int(videoStream.height),
        engine: "nativeFallback",
        isHardwareDecoding: true,
        decoderName: "VideoToolbox",
        audioTracks: audioTracks,
        videoTracks: videoTracks,
        capabilities: YlMacosChannel.deviceCapabilities,
        metrics: metrics,
        error: currentError
      ).fullMap
    ))
  }

  private func emitStateDelta() {
    guard !stateLock.withLock({ disposed || stopped || resetting }) else { return }
    let positionUs = mediaClock.position(atHostTimeUs: Self.hostTimeUs())
    let renderer = currentAudioRenderer
    let scheduledAudioDurationUs = renderer?.scheduledDurationUs ?? 0
    let scheduledAudioBytes = renderer?.scheduledBytes ?? 0
    let audioUnderruns = renderer?.underrunCount ?? 0
    let metrics = YlMacosChannel.fallbackMetrics(
      openDurationMs: openDurationMs,
      firstFrameDurationMs: firstFrameDurationMs,
      bufferedDurationMs: scheduledAudioDurationUs / 1_000,
      bufferedBytes: scheduledAudioBytes,
      droppedVideoFrames: frameScheduler.lateFrameDropCount,
      audioUnderruns: audioUnderruns,
      reconnectCount: reconnectCount
    )
    emit(YlMacosChannel.stateDelta(
      playerId: playerId,
      generation: channelGeneration,
      delta: YlFallbackDynamicSnapshot(
        positionMs: positionUs / 1_000,
        bufferedPositionMs: (positionUs + scheduledAudioDurationUs) / 1_000,
        isAtLiveEdge: mediaPolicy.isLive,
        liveOffsetMs: nil,
        metrics: metrics
      ).deltaMap
    ))
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
          cancelVideoSubmissions()
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
      DispatchQueue.main.async { [weak self] in
        guard let self, self.stateLock.withLock({ self.active && self.generation == frame.generation }) else { return }
        self.emitState()
      }
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
    setFailure(error)
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
      emitStateDelta()
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
        } else if enqueueResult == .buffered {
          self.pendingAudioPacket = nil
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
      if selectedAudioStream == nil {
        decoder?.drain()
      } else if let decoder {
        scheduleVideoDrain(decoder: decoder, generation: packetGeneration)
      }
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
        fail(ylFallbackPacketReadError(
          result: result,
          inputError: inputError,
          container: mediaPolicy.container
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
      guard let decoder else {
        ylf_packet_release(&packet)
        stateLock.withLock { pumping = false }
        fail(NativePlayerError(
          category: "internal",
          code: "internal.fallback_invariant",
          message: "The video decoder became unavailable."
        ))
        return
      }
      do {
        let byteCount = ylf_packet_size(ownedPacket)
        let shouldCancel = { [weak self] in
          guard let self else { return true }
          return self.stateLock.withLock {
            self.disposed || !self.active || self.reconfiguring
              || self.generation != packetGeneration
          }
        }
        // Charge the sample before either the sample buffer or queue can own it.
        let reservation = try selectedAudioStream == nil
          ? decoder.reserve(byteCount: byteCount, shouldCancel: shouldCancel)
          : decoder.reserveSubmission(byteCount: byteCount, shouldCancel: shouldCancel)
        guard let reservation else {
          ylf_packet_release(&packet)
          stateLock.withLock { pumping = false }
          return
        }
        var unmanagedSample: Unmanaged<CMSampleBuffer>?
        let sampleResult = ylf_create_video_sample_buffer(
          &packet,
          videoFormat,
          &unmanagedSample
        )
        if sampleResult == 0, let unmanagedSample {
          stateLock.withLock { prebufferedVideoSample = true }
          let sample = unmanagedSample.takeRetainedValue()
          if selectedAudioStream == nil {
            decoder.decode(
              sample: sample, generation: packetGeneration, reservation: reservation
            )
          } else {
            scheduleVideoDecode(
              sample,
              generation: packetGeneration,
              decoder: decoder,
              reservation: reservation
            )
          }
        } else {
          ylf_packet_release(&packet)
        }
      } catch let error as NativePlayerError {
        ylf_packet_release(&packet)
        stateLock.withLock { pumping = false }
        fail(error)
        return
      } catch {
        ylf_packet_release(&packet)
        stateLock.withLock { pumping = false }
        fail(NativePlayerError(
          category: "internal",
          code: "internal.fallback_invariant",
          message: "The video decoder buffer reservation failed.",
          diagnostic: String(describing: error)
        ))
        return
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

  private func scheduleVideoDecode(
    _ sample: CMSampleBuffer,
    generation packetGeneration: UInt64,
    decoder: YlVideoToolboxDecoder,
    reservation: YlVideoDecodeReservation
  ) {
    videoSubmissions.submit { [weak self, decoder] in
      guard let self else { return }
      do {
        guard try reservation.beginDecoding(shouldCancel: {
          self.stateLock.withLock {
            self.disposed || !self.active || self.generation != packetGeneration
          }
        }) else { return }
        decoder.decode(sample: sample, generation: packetGeneration, reservation: reservation)
      } catch let error as NativePlayerError {
        if self.shouldReportVideoFailure(generation: packetGeneration) { self.fail(error) }
      } catch {
        if self.shouldReportVideoFailure(generation: packetGeneration) {
          self.fail(NativePlayerError(
            category: "internal", code: "internal.fallback_invariant",
            message: "The video decoder buffer reservation failed.",
            diagnostic: String(describing: error)
          ))
        }
      }
    }
  }

  private func scheduleVideoDrain(
    decoder: YlVideoToolboxDecoder,
    generation packetGeneration: UInt64
  ) {
    videoSubmissions.submit { [weak self, decoder] in
      guard let self, self.stateLock.withLock({
        !self.disposed && self.active && self.generation == packetGeneration
      }) else { return }
      decoder.drain()
    }
  }

  private func cancelVideoSubmissions() {
    videoSubmissions.cancelPending()
    videoSubmissions.waitUntilIdle()
  }

  private func shouldReportVideoFailure(generation taskGeneration: UInt64) -> Bool {
    stateLock.withLock {
      !disposed && active && !reconfiguring && generation == taskGeneration
    }
  }

  private func beginLiveReconnect(
    after error: NativePlayerError,
    packetGeneration: UInt64
  ) {
    let transition = stateLock.withLock { () -> (
      generation: UInt64,
      media: YlOpenedMedia?,
      token: YlOpenCancellationToken?,
      decoder: YlVideoToolboxDecoder?,
      audio: YlAudioRenderer?
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
      let detachedDecoder = decoder
      decoder = nil
      let detachedAudio = audioRenderer
      audioRenderer = nil
      return (
        generation,
        detachedMedia,
        detachedToken,
        detachedDecoder,
        detachedAudio
      )
    }
    guard let transition else { return }

    transition.token?.cancel()
    transition.media?.cancelInput()
    pendingAudioPacket = nil
    prebufferedVideoSample = false
    audioAnchored = false
    frameScheduler.flush(generation: transition.generation)
    postSeekGate.reset(targetUs: nil)
    stateLock.withLock { currentPixelBuffer = nil }

    DispatchQueue.main.async { [weak self] in
      transition.audio?.pause()
      if let self {
        let isCurrent = self.stateLock.withLock {
          self.active && self.reconfiguring
            && self.generation == transition.generation
        }
        if isCurrent {
          self.mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
          self.mediaClock.seek(to: 0)
          self.status = "buffering"
          self.emitState()
        }
        self.worker.async { [weak self] in
          self?.cancelVideoSubmissions()
          transition.decoder?.dispose()
          transition.audio?.dispose()
          transition.media?.close()
          guard let self,
                self.stateLock.withLock({
                  !self.disposed && self.active && self.reconfiguring
                    && self.generation == transition.generation
                }) else { return }
          self.scheduleLiveReconnect(
            after: error,
            generation: transition.generation
          )
        }
      } else {
        transition.decoder?.dispose()
        transition.audio?.dispose()
        transition.media?.close()
      }
    }
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
            if self.selectedAudioStream != nil {
              try self.currentAudioRenderer?.play()
            }
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
    let initialGeneration = stateLock.withLock { generation }
    if cancellationToken == nil, !stateLock.withLock({ active }) {
      try onMainSync {
        try stateLock.withLock {
          guard !disposed, !stopped, generation == initialGeneration else {
            throw YlOpenCancellationToken.cancellationError()
          }
        }
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
    // Every resource commit checks while holding stateLock. Resource mutation is
    // serialized on worker with teardown; construction never blocks that queue.
    func requireCurrentSeek(_ expectedGeneration: UInt64) throws {
      try cancellationToken?.throwIfCancelled()
      guard !disposed, !stopped, active, generation == expectedGeneration,
            openedMedia === media else {
        throw YlOpenCancellationToken.cancellationError()
      }
    }
    var operationGeneration = UInt64(0)
    let transaction = YlFallbackLifecycleTransaction(
      pauseClock: { [self] in
        try onMainSync {
          try stateLock.withLock { try requireCurrentSeek(entry.generation) }
          currentAudioRenderer?.pause()
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
        worker.sync { cancelVideoSubmissions() }
        media.resumeReads()
        try cancellationToken?.throwIfCancelled()
      },
      clearBuffers: { [self] nextGeneration in
        try worker.sync {
          try stateLock.withLock {
            try requireCurrentSeek(nextGeneration)
            pendingAudioPacket = nil
            prebufferedVideoSample = false
            demuxEOF = false
            completionSent = false
            audioAnchored = false
            currentPixelBuffer = nil
          }
          frameScheduler.flush(generation: nextGeneration)
        }
      },
      seekDemux: { [self] targetUs in
        try cancellationToken?.throwIfCancelled()
        try media.seek(toMediaTimeUs: targetUs)
        try cancellationToken?.throwIfCancelled()
      },
      resetAudio: { [self] nextGeneration in
        try worker.sync {
          let renderer = try stateLock.withLock { () -> YlAudioRenderer? in
            try requireCurrentSeek(nextGeneration)
            audioGeneration = nextGeneration
            return audioRenderer
          }
          renderer?.reset(generation: nextGeneration)
        }
      },
      recreateVideo: { [self] nextGeneration in
        try worker.sync {
          let previous = try stateLock.withLock { () -> YlVideoToolboxDecoder? in
            try requireCurrentSeek(nextGeneration)
            let previous = decoder
            decoder = nil
            return previous
          }
          previous?.dispose()
        }
        let candidate = try makeDecoder()
        var installed = false
        defer { if !installed { candidate.dispose() } }
        try worker.sync {
          let previous = try stateLock.withLock { () -> YlVideoToolboxDecoder? in
            try requireCurrentSeek(nextGeneration)
            let previous = decoder
            decoder = candidate
            installed = true
            return previous
          }
          previous?.dispose()
        }
      },
      suppressFramesBefore: { [self] targetUs in
        try onMainSync {
          try stateLock.withLock { try requireCurrentSeek(operationGeneration) }
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
            if selectedAudioStream != nil { try currentAudioRenderer?.play() }
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
        try? currentAudioRenderer?.play()
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
      currentAudioRenderer?.pause()
      mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
      displayLink?.isPaused = true
      setFailure(error)
    }
  }

  private func makeDecoder() throws -> YlVideoToolboxDecoder {
    try YlVideoToolboxDecoder(
      formatDescription: videoFormat,
      maxInFlightBytes: bufferBudget.inFlightPacketBytes,
      factory: videoSessionFactory,
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

    let activeQualityConstraint = stateLock.withLock { qualityConstraint }
    try YlFallbackQualityPolicy.validate(
      constraint: activeQualityConstraint,
      stream: Self.videoDescriptor(selectedVideo)
    )

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
      maxInFlightBytes: bufferBudget.inFlightPacketBytes,
      factory: videoSessionFactory,
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
      maxInFlightBytes: bufferBudget.inFlightPacketBytes,
      factory: videoSessionFactory,
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
    let link = YlDisplayTimer(view: displayView) { [weak self] in self?.displayLinkTick() }
    link.isPaused = paused
    displayLink = link
  }

  private func completeIfDrained(atHostTimeUs hostTimeUs: Int64) {
    let shouldComplete = stateLock.withLock {
      active && playing && demuxEOF && !completionSent
        && pendingAudioPacket == nil
    }
    guard shouldComplete, videoSubmissions.isDrained,
          frameScheduler.pendingPTS.isEmpty,
          (currentAudioRenderer?.scheduledDurationUs ?? 0) == 0 else { return }
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
    let details = errorMap(
      category: error.category,
      code: error.code,
      message: error.message,
      diagnostic: error.diagnostic
    )
    let transition = stateLock.withLock { () -> (
      generation: UInt64,
      media: YlOpenedMedia?,
      token: YlOpenCancellationToken?,
      reconnect: DispatchWorkItem?
    )? in
      guard let generations = YlFallbackTerminalFailurePolicy.begin(
        disposed: disposed,
        active: active,
        hasError: currentError != nil,
        videoGeneration: generation,
        audioGeneration: audioGeneration
      ) else { return nil }
      generation = generations.videoGeneration
      audioGeneration = generations.audioGeneration
      active = false
      playing = false
      reconfiguring = true
      pumping = false
      demuxEOF = false
      completionSent = false
      awaitingReconnectFirstFrame = false
      status = "error"
      currentError = details
      let detachedMedia = openedMedia
      openedMedia = nil
      let detachedToken = sourceCancellationToken
      sourceCancellationToken = nil
      let detachedReconnect = reconnectWorkItem
      reconnectWorkItem = nil
      return (generation, detachedMedia, detachedToken, detachedReconnect)
    }
    guard let transition else { return }

    liveReconnectController.cancel()
    transition.reconnect?.cancel()
    transition.token?.cancel()
    transition.media?.cancelInput()

    let finishOnMain = { [weak self] in
      guard let self else {
        transition.media?.close()
        return
      }
      guard self.stateLock.withLock({
        !self.disposed && !self.stopped && self.generation == transition.generation
      }) else {
        self.worker.async { transition.media?.close() }
        return
      }
      self.displayLink?.invalidate()
      self.displayLink = nil
      let renderer = self.stateLock.withLock { self.audioRenderer }
      renderer?.pause()
      self.mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
      self.frameScheduler.flush(generation: transition.generation)
      self.postSeekGate.reset(targetUs: nil)
      self.stateLock.withLock { self.currentPixelBuffer = nil }
      self.emit(YlFallbackErrorEvent(playerId: self.playerId, error: details).eventMap)
      self.emitState()

      self.worker.async { [weak self] in
        guard let self else {
          transition.media?.close()
          return
        }
        let resources = self.stateLock.withLock { () -> (
          decoder: YlVideoToolboxDecoder?,
          audio: YlAudioRenderer?
        ) in
          guard self.generation == transition.generation, !self.active else {
            return (nil, nil)
          }
          let detachedDecoder = self.decoder
          self.decoder = nil
          let detachedAudio = self.audioRenderer
          self.audioRenderer = nil
          self.pendingAudioPacket = nil
          self.prebufferedVideoSample = false
          self.audioAnchored = false
          return (detachedDecoder, detachedAudio)
        }
        self.cancelVideoSubmissions()
        resources.decoder?.dispose()
        resources.audio?.dispose()
        transition.media?.close()
      }
    }
    if Thread.isMainThread {
      finishOnMain()
    } else {
      DispatchQueue.main.async(execute: finishOnMain)
    }
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

    let initialGeneration = stateLock.withLock { generation }
    if cancellationToken == nil, !stateLock.withLock({ active }) {
      try onMainSync {
        try stateLock.withLock {
          guard !disposed, !stopped, generation == initialGeneration else {
            throw YlOpenCancellationToken.cancellationError()
          }
        }
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
        try? currentAudioRenderer?.play()
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
      sampleTime: currentAudioRenderer?.renderedAudioTime?.sampleTime ?? 0
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
    YlFallbackTrackCatalog.audioTracks(
      streams: audioStreams,
      selectedIndex: selectedAudioStream?.index,
      codecName: audioCodecName
    )
  }

  private var videoTracks: [[String: Any?]] {
    [YlFallbackTrackCatalog.videoTrack(
      stream: videoStream,
      codecName: Int(videoStream.codec) == YLFCodecHEVC ? "hevc" : "h264",
      bitrate: nil
    )]
  }

  private static func hostTimeUs() -> Int64 {
    Int64(CACurrentMediaTime() * 1_000_000)
  }

  private static func videoDescriptor(
    _ stream: YLFStreamInfo
  ) -> YlFallbackVideoDescriptor {
    YlFallbackVideoDescriptor(
      width: Int(stream.width),
      height: Int(stream.height),
      bitrate: nil
    )
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
