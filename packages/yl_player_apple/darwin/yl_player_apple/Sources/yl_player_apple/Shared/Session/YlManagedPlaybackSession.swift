import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import YlFFmpegBridge

// Coordinates atomic lifecycle changes across the five resource owners. Seek,
// track replacement, recovery installation and teardown deliberately retain their
// original lock/main/worker ordering here; packet, decode, audio, presentation and
// retry algorithms live in the corresponding components.
final class YlManagedPlaybackSession: NSObject, YlVideoPipelineOutput, YlAudioPipelineOutput, YlPresentationOutput, YlRecoverySession, YlDemuxOutput {
  let playerId: Int64
  var textureId: Int64 { services.textureOutput.textureId }
  var isActive: Bool { stateLock.withLock { active } }
  var playbackIntent: Bool { stateLock.withLock { playing } }
  var requiresAsyncActivation: Bool {
    // A demux cursor alone cannot restore a retired VT session: its next packet
    // may depend on a keyframe consumed by the old video.decoder (R22).
    let needsPipeline = demux.context == nil || (services.compatibility.limitsVideoReservations && video.decoder == nil)
    guard needsPipeline else { return false }
    let sourceRecipe = demux.sourceRecipe
    if case .network = sourceRecipe { return true }
    return false
  }

  var isNetworkSource: Bool {
    let isNetwork: Bool
    let sourceRecipe = demux.sourceRecipe
    if case .network = sourceRecipe { isNetwork = true } else { isNetwork = false }
    return isNetwork
  }
  var isStopped: Bool { stateLock.withLock { stopped } }

  func validateQualityConstraint(_ constraint: YlFallbackQualityConstraint) throws {
    let currentStream = stateLock.withLock { demux.videoStream }
    try YlFallbackQualityPolicy.validate(constraint: constraint, stream: Self.videoDescriptor(currentStream))
  }

  func interruptControlOperation() {
    demux.interruptControlOperation()
  }

  func resumeControlOperation() {
    demux.resumeControlOperation()
  }

  private let recovery: YlRecoveryCoordinator
  private let presentation: YlPresentationCoordinator
  private let audio: YlAudioPipeline
  private let video: YlVideoPipeline
  private let demux: YlDemuxPipeline
  private let services: YlPlatformServices
  private let configuration: PlayerConfiguration
  private let onEvent: (YlNativeBackendCallback) -> Void
  private let bufferBudget: YlFallbackBufferBudget
  private var qualityConstraint: YlFallbackQualityConstraint
  private let stateLock = NSLock()
  private var active = false
  private var playing = false
  private var stopped = false
  private var resetting = false
  private var disposed = false
  private var pumping = false
  private var reconfiguring = false
  private var generation: UInt64
  private(set) var channelGeneration = YlBackendGeneration.next()
  private let loadRequestId: String?
  private var savedPositionUs: Int64 = 0
  private var status = "ready"
  private var prebufferedVideoSample = false
  private var demuxEOF = false
  private var completionSent = false
  private var openStartedAt = CACurrentMediaTime()
  private var openDurationMs: Int64?
  private var currentError: NativePlayerError?

  private var currentAudioRenderer: YlAudioRenderer? {
    stateLock.withLock { audio.audioRenderer }
  }

  init(
    playerId: Int64,
    services: YlPlatformServices,
    configuration: PlayerConfiguration,
    prepared: YlPreparedFallback,
    qualityConstraint: YlFallbackQualityConstraint = .unconstrained,
    generation: UInt64,
    videoSessionFactory: YlVTSessionFactory = YlHardwareVTSessionFactory(),
    mediaClock providedMediaClock: YlMediaClock? = nil,
    loadRequestId: String? = nil,
    channelIdentity: UInt64? = nil,
    emit: @escaping (YlNativeBackendCallback) -> Void
  ) throws {
    try YlFallbackQualityPolicy.validate(
      constraint: qualityConstraint,
      stream: Self.videoDescriptor(prepared.videoStream)
    )
    self.loadRequestId = loadRequestId
    if let channelIdentity { self.channelGeneration = channelIdentity }
    self.playerId = playerId
    self.services = services
    self.configuration = configuration
    self.bufferBudget = try YlFallbackBufferBudget.make(configuration: configuration)
    let resumeState = prepared.resumeState
    self.qualityConstraint = qualityConstraint
    self.generation = generation
    self.onEvent = emit
    self.demux = try YlDemuxPipeline(prepared: prepared, lock: stateLock, bufferBudget: bufferBudget)
    self.video = YlVideoPipeline(format: prepared.videoFormat, bufferBudget: bufferBudget,
      factory: videoSessionFactory)
    self.audio = YlAudioPipeline(bufferBudget: bufferBudget, lock: stateLock, generation: generation)
    self.presentation = YlPresentationCoordinator(services: services, lock: stateLock,
      openedAt: openStartedAt, positionEventIntervalMs: configuration.positionEventIntervalMs)
    self.recovery = YlRecoveryCoordinator(configuration: configuration.network,
      scheduler: YlDispatchRecoveryScheduler(queue: demux.worker))
    self.playing = resumeState?.shouldPlay ?? false
    self.savedPositionUs = resumeState?.positionUs ?? 0
    super.init()

    audio.audioRenderer = audio.makeRenderer()
    self.presentation.mediaClock = providedMediaClock ?? YlMediaClock(audioTime: { [weak self] in
      guard let self else { return nil }
      let renderer = self.stateLock.withLock { self.audio.audioRenderer }
      return renderer?.renderedAudioTime
    })
    demux.output = self
    recovery.session = self
    presentation.output = self
    audio.output = self
    audio.timeline = self.presentation.mediaClock
    self.presentation.mediaClock.seek(to: savedPositionUs)
    // Demux seeks land on an earlier keyframe; suppress that preroll just as
    // in-place pipeline restoration does before it can re-anchor the clock.
    if savedPositionUs > 0 { presentation.postSeekGate.reset(targetUs: savedPositionUs) }
    video.outputRelay.backend = self
    do {
      video.decoder = try video.makeDecoder(format: video.format)
      if let audioStream = demux.selectedAudioStream {
        try audio.audioRenderer.configure(stream: audioConfiguration(
          for: audioStream,
          generation: audio.audioGeneration
        ))
      }
    } catch {
      video.decoder?.dispose()
      video.decoder = nil
      audio.audioRenderer?.dispose()
      audio.audioRenderer = nil
      demux.openedMedia?.close()
      demux.openedMedia = nil
      throw error
    }
    presentation.frameScheduler.flush(generation: generation)
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
    if services.platform == .ios && configuration.managesAudioSession {
      do { try services.activateAudioSession() }
      catch {
        throw NativePlayerError(category: "resource", code: "ios.audio_session_failed",
          message: "The playback audio session could not be activated.", diagnostic: String(describing: error))
      }
    }
    if requiresAsyncActivation {
      throw NativePlayerError(
        category: "internal",
        code: "\(YlApplePlatform.current.rawValue).async_activation_required",
        message: "Network Matroska reactivation requires background preparation."
      )
    }
    if demux.context == nil || audio.audioRenderer == nil || (services.compatibility.limitsVideoReservations && video.decoder == nil) {
      try rebuildPipeline(positionUs: savedPositionUs)
    } else if video.decoder == nil {
      video.decoder = try makeDecoder()
    }
    if presentation.displayLink == nil { installDisplayLink(paused: false) }
    stateLock.withLock {
      active = true
      reconfiguring = false
    }
    presentation.displayLink?.isPaused = false
    if playing {
      if demux.selectedAudioStream != nil { try audio.audioRenderer.play() }
      presentation.mediaClock.play(atHostTimeUs: Self.hostTimeUs())
      status = "playing"
    }
    emit(.engineActivated(.managedFallback))
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
    // The audio-backed clock may consult stateLock; sample before owning it.
    let positionGeneration = stateLock.withLock { generation }
    let positionBeforeRelease = stopping ? nil : presentation.mediaClock.position(atHostTimeUs: Self.hostTimeUs())
    stateLock.lock()
    guard !disposed,
          stopping || active || demux.openedMedia != nil || video.decoder != nil || audio.audioRenderer != nil else {
      stateLock.unlock()
      return
    }
    if active, generation == positionGeneration, let positionBeforeRelease {
      savedPositionUs = positionBeforeRelease
    }
    let mayClearOutput = active || stopping
    resetting = stopping
    if stopping { stopped = true; playing = false }
    active = false
    reconfiguring = true
    generation &+= 1
    audio.audioGeneration &+= 1
    let currentGeneration = generation
    let reconnectToCancel = recovery.reconnectWorkItem
    recovery.reconnectWorkItem = nil
    let mediaToClose = demux.openedMedia
    demux.openedMedia = nil
    let tokenToCancel = demux.sourceCancellationToken
    demux.sourceCancellationToken = nil
    stateLock.unlock()
    if stopping { recovery.liveReconnectController.cancel() }
    reconnectToCancel?.cancel()
    presentation.displayLink?.invalidate()
    presentation.displayLink = nil
    currentAudioRenderer?.pause()
    presentation.mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
    YlFallbackTeardownTransaction(
      cancelInput: { [self] in
        tokenToCancel?.cancel()
        mediaToClose?.cancelInput()
      },
      joinAndRelease: { [self] in
        demux.worker.sync {
          audio.pendingAudioPacket = nil
          cancelVideoSubmissions()
          video.decoder?.dispose()
          video.decoder = nil
          audio.audioRenderer?.dispose()
          audio.audioRenderer = nil
        }
        mediaToClose?.close()
      }
    ).run()
    presentation.frameScheduler.flush(generation: currentGeneration)
    stateLock.withLock {
      presentation.currentPixelBuffer = nil
      if mayClearOutput { presentation.clearOutput() }
      pumping = false
      demuxEOF = false
      completionSent = false
      prebufferedVideoSample = false
      audio.audioAnchored = false
      reconfiguring = false
    }
    presentation.postSeekGate.reset(targetUs: nil)
    if stopping {
      channelGeneration = YlBackendGeneration.next()
      savedPositionUs = 0
      openDurationMs = nil
      presentation.firstFrameDurationMs = nil
      presentation.firstFrameSent = false
      recovery.reconnectCount = 0
      recovery.awaitingReconnectFirstFrame = false
      currentError = nil
      demux.selectedAudioStream = nil
      demux.audioStreams.removeAll()
      demux.audioCookies.removeAll()
      demux.isSeekable = false
    }
    presentation.mediaClock.seek(to: savedPositionUs)
    status = stopping ? "idle" : "paused"
    resetting = false
    emitState()
  }

  func quiesceForReplacement() {
    // The default audio clock consults stateLock synchronously.
    let positionGeneration = stateLock.withLock { generation }
    let positionBeforeReplacement = presentation.mediaClock.position(atHostTimeUs: Self.hostTimeUs())
    stateLock.lock()
    guard !disposed, active else {
      stateLock.unlock()
      return
    }
    if generation == positionGeneration {
      savedPositionUs = positionBeforeReplacement
    }
    active = false
    reconfiguring = true
    let generations = YlFallbackReplacementGenerationPolicy.quiesce(
      videoGeneration: generation,
      audioGeneration: audio.audioGeneration
    )
    generation = generations.videoGeneration
    audio.audioGeneration = generations.audioGeneration
    let currentGeneration = generation
    let reconnectToCancel = recovery.reconnectWorkItem
    recovery.reconnectWorkItem = nil
    let media = demux.openedMedia
    let reconnectTokenToCancel = media == nil ? demux.sourceCancellationToken : nil
    if reconnectTokenToCancel != nil { demux.sourceCancellationToken = nil }
    stateLock.unlock()

    reconnectToCancel?.cancel()
    reconnectTokenToCancel?.cancel()

    presentation.displayLink?.invalidate()
    presentation.displayLink = nil
    currentAudioRenderer?.pause()
    presentation.mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
    media?.interruptRead()
    demux.worker.sync {
      audio.pendingAudioPacket = nil
      if services.compatibility.limitsVideoReservations {
        cancelVideoSubmissions()
        video.decoder?.dispose()
        video.decoder = nil
      }
    }
    media?.resumeReads()
    presentation.frameScheduler.flush(generation: currentGeneration)
    stateLock.withLock {
      presentation.currentPixelBuffer = nil; presentation.clearOutput()
      pumping = false
      demuxEOF = false
      completionSent = false
      prebufferedVideoSample = false
      audio.audioAnchored = false
      reconfiguring = false
    }
    presentation.postSeekGate.reset(targetUs: nil)
    presentation.mediaClock.seek(to: savedPositionUs)
    status = "paused"
    emitState()
  }

  func reactivationState(forcePlay: Bool) -> YlFallbackResumeState {
    stateLock.withLock {
      YlFallbackResumeState(
        positionUs: savedPositionUs,
        selectedAudioStreamIndex: demux.selectedAudioStream?.index,
        shouldPlay: forcePlay || playing
      )
    }
  }

  func reportRestorationFailure(_ error: NativePlayerError) {
    deactivate()
    let details = NativePlayerError(
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
    emit(.failure(details))
    emitState()
  }

  func handleMemoryWarning() {
    stateLock.withLock { demux.openedMedia }?.handleMemoryWarning()
    deactivate()
  }

  func play() throws {
      let wasPlaying = stateLock.withLock { () -> Bool in
        let previous = playing
        playing = true
        return previous
      }
      if !wasPlaying {
        if demux.selectedAudioStream != nil { try currentAudioRenderer?.play() }
        presentation.mediaClock.play(atHostTimeUs: Self.hostTimeUs())
      }
      status = "playing"
      emitState()
      requestPump()
  }

  func pause() throws {
      stateLock.withLock { playing = false }
      if demux.selectedAudioStream != nil { currentAudioRenderer?.pause() }
      presentation.mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
      status = "paused"
      emitState()
  }

  func seekToLiveEdge() throws {
      if demux.mediaPolicy.isLive {
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
  }

  func setPlaybackSpeed(_ rate: Float) throws {
      guard rate >= 0.25, rate <= 4 else {
        throw NativePlayerError(
          category: "source",
          code: "playback.speed_invalid",
          message: "Playback speed must be between 0.25 and 4.0."
        )
      }
      audio.desiredRate = rate
      presentation.mediaClock.setRate(Double(rate), atHostTimeUs: Self.hostTimeUs())
      if demux.selectedAudioStream != nil { currentAudioRenderer?.setRate(rate) }
  }

  func setVolume(_ volume: Float) { audio.setVolume(volume, hasAudio: demux.selectedAudioStream != nil) }

  func setQualityConstraint(_ constraint: YlFallbackQualityConstraint) throws {
      try validateQualityConstraint(constraint)
      stateLock.withLock { qualityConstraint = constraint }
  }

  private func emit(_ event: YlNativeBackendEvent) {
    onEvent(YlNativeBackendCallback(generation: channelGeneration, loadRequestId: stopped ? nil : loadRequestId, event: event))
  }

  func emitState() {
    guard !stateLock.withLock({ disposed || resetting }) else { return }
    if stateLock.withLock({ stopped }) {
      emit(.state(YlNativeState(status: "idle", positionMs: 0, durationMs: nil,
        bufferedPositionMs: 0, isLive: false, isSeekable: false, isAtLiveEdge: false,
        liveOffsetMs: nil, dvrStartMs: nil, dvrEndMs: nil,
        videoWidth: nil, videoHeight: nil, engine: .managedFallback,
        isHardwareDecoding: false, decoderName: nil, audioTracks: [], videoTracks: [],
        metrics: YlBackendStateEncoder.fallbackMetrics(openDurationMs: nil,
          firstFrameDurationMs: nil, bufferedDurationMs: 0, bufferedBytes: 0,
          droppedVideoFrames: 0, audioUnderruns: 0, reconnectCount: 0), error: nil)))
      return
    }
    let positionUs = presentation.mediaClock.position(atHostTimeUs: Self.hostTimeUs())
    let durationMs = demux.mediaPolicy.durationMs(mediaDurationUs: demux.mediaInfo.duration_us)
    let renderer = currentAudioRenderer
    let scheduledAudioDurationUs = renderer?.scheduledDurationUs ?? 0
    let scheduledAudioBytes = renderer?.scheduledBytes ?? 0
    let audioUnderruns = audio.observeUnderruns(renderer: renderer) ?? 0
    let metrics = YlBackendStateEncoder.fallbackMetrics(
      openDurationMs: openDurationMs,
      firstFrameDurationMs: presentation.firstFrameDurationMs,
      bufferedDurationMs: scheduledAudioDurationUs / 1_000,
      bufferedBytes: scheduledAudioBytes,
      droppedVideoFrames: presentation.frameScheduler.lateFrameDropCount,
      audioUnderruns: audioUnderruns,
      reconnectCount: recovery.reconnectCount
    )
    emit(.state(YlNativeState(
        status: status,
        positionMs: positionUs / 1_000,
        durationMs: durationMs,
        bufferedPositionMs: (positionUs + scheduledAudioDurationUs) / 1_000,
        isLive: demux.mediaPolicy.isLive,
        isSeekable: demux.isSeekable,
        isAtLiveEdge: demux.mediaPolicy.isLive,
        liveOffsetMs: nil,
        dvrStartMs: nil,
        dvrEndMs: nil,
        videoWidth: Int(demux.videoStream.width),
        videoHeight: Int(demux.videoStream.height),
        engine: .managedFallback,
        isHardwareDecoding: video.decoder?.usesHardwareDecoder == true,
        decoderName: "VideoToolbox",
        audioTracks: audioTracks,
        videoTracks: videoTracks,
        metrics: metrics,
        error: currentError
      )))
  }

  private func emitStateDelta() {
    guard !stateLock.withLock({ disposed || stopped || resetting }) else { return }
    let positionUs = presentation.mediaClock.position(atHostTimeUs: Self.hostTimeUs())
    let renderer = currentAudioRenderer
    let scheduledAudioDurationUs = renderer?.scheduledDurationUs ?? 0
    let scheduledAudioBytes = renderer?.scheduledBytes ?? 0
    let audioUnderruns = audio.observeUnderruns(renderer: renderer) ?? 0
    let metrics = YlBackendStateEncoder.fallbackMetrics(
      openDurationMs: openDurationMs,
      firstFrameDurationMs: presentation.firstFrameDurationMs,
      bufferedDurationMs: scheduledAudioDurationUs / 1_000,
      bufferedBytes: scheduledAudioBytes,
      droppedVideoFrames: presentation.frameScheduler.lateFrameDropCount,
      audioUnderruns: audioUnderruns,
      reconnectCount: recovery.reconnectCount
    )
    emit(.delta(YlNativeTimelineDelta(
        positionMs: positionUs / 1_000,
        bufferedPositionMs: (positionUs + scheduledAudioDurationUs) / 1_000,
        isAtLiveEdge: demux.mediaPolicy.isLive,
        liveOffsetMs: nil,
        metrics: metrics
      )))
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? { presentation.copyPixelBuffer() }

  func dispose() {
    stateLock.lock()
    guard !disposed else {
      stateLock.unlock()
      return
    }
    let mayClearOutput = active
    disposed = true
    active = false
    playing = false
    reconfiguring = true
    generation &+= 1
    audio.audioGeneration &+= 1
    let reconnectToCancel = recovery.reconnectWorkItem
    recovery.reconnectWorkItem = nil
    let mediaToClose = demux.openedMedia
    demux.openedMedia = nil
    let tokenToCancel = demux.sourceCancellationToken
    demux.sourceCancellationToken = nil
    stateLock.unlock()
    recovery.liveReconnectController.cancel()
    reconnectToCancel?.cancel()
    presentation.displayLink?.invalidate()
    presentation.displayLink = nil
    YlFallbackTeardownTransaction(
      cancelInput: { [self] in
        tokenToCancel?.cancel()
        mediaToClose?.cancelInput()
      },
      joinAndRelease: { [self] in
        demux.worker.sync {
          audio.pendingAudioPacket = nil
          cancelVideoSubmissions()
          video.decoder?.dispose()
          video.decoder = nil
          audio.audioRenderer?.dispose()
          audio.audioRenderer = nil
          presentation.frameScheduler.dispose()
        }
        mediaToClose?.close()
      }
    ).run()
    stateLock.withLock { presentation.currentPixelBuffer = nil }
    if mayClearOutput { presentation.clearOutput() }
  }

  func receive(_ frame: YlVideoFrame) { presentation.receive(frame) }

  func acceptsPresentationFrame(generation frameGeneration: UInt64) -> Bool {
    stateLock.withLock { active && generation == frameGeneration }
  }

  var presentationGeneration: UInt64 { stateLock.withLock { generation } }

  func didAcceptPresentationFrame(generation frameGeneration: UInt64) {
    let completedReconnect = stateLock.withLock { () -> Bool in
      guard recovery.awaitingReconnectFirstFrame, generation == frameGeneration else {
        return false
      }
      recovery.awaitingReconnectFirstFrame = false
      recovery.reconnectCount += 1
      return true
    }
    if completedReconnect {
      recovery.liveReconnectController.markFirstFrame()
      DispatchQueue.main.async { [weak self] in
        guard let self, self.stateLock.withLock({ self.active && self.generation == frameGeneration }) else { return }
        self.emitState()
      }
    }
  }

  func didPublishFirstPresentationFrame() {
    emit(.firstFrame(width: Int(demux.videoStream.width), height: Int(demux.videoStream.height)))
    emitState()
  }

  func presentationDidTick(atHostTimeUs value: Int64) { completeIfDrained(atHostTimeUs: value) }
  func emitPresentationDelta() { emitStateDelta() }

  func fail(_ error: NativePlayerError) {
    setFailure(error)
  }

  func setDemuxPumping(_ value: Bool) { stateLock.withLock { pumping = value } }
  func requestAudioPump() { requestPump() }
  func requestAudioPump(after delay: TimeInterval) { requestPump(after: delay) }

  private func requestPump(after delay: TimeInterval = 0) {
    stateLock.lock()
    guard !disposed, active, !reconfiguring, !pumping, !demuxEOF else {
      stateLock.unlock()
      return
    }
    pumping = true
    stateLock.unlock()
    demux.worker.asyncAfter(deadline: .now() + delay) { [weak self] in self?.pumpOne() }
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

    if audio.pendingAudioPacket != nil {
      audio.retryPending(codecName: selectedAudioCodecName)
      return
    }

    demux.pumpOne(generation: packetGeneration)
  }

  func demuxDidReachEOF(generation packetGeneration: UInt64) {
      stateLock.withLock {
        pumping = false
        demuxEOF = true
      }
      if !services.compatibility.limitsVideoReservations {
        video.decoder?.flush()
      } else if demux.selectedAudioStream == nil {
        video.decoder?.drain()
      } else if let drainingDecoder = video.decoder {
        video.scheduleVideoDrain(decoder: drainingDecoder, generation: packetGeneration)
      }
  }

  func shouldReportDemuxFailure(generation packetGeneration: UInt64) -> Bool {
    return stateLock.withLock { () -> Bool in
        pumping = false
        return !disposed && active && !reconfiguring && generation == packetGeneration
      }
  }

  var demuxAudioGeneration: UInt64 { stateLock.withLock { audio.audioGeneration } }
  func acceptsDemuxAudio(ptsUs: Int64) -> Bool { presentation.postSeekGate.acceptsAudio(ptsUs: ptsUs) }
  func consumeDemuxAudio(_ packet: YlCompressedAudioPacket, onBackpressure: (TimeInterval) -> Void) -> Void? {
    audio.enqueue(packet, codecName: selectedAudioCodecName, onBackpressure: onBackpressure)
  }

  func consumeDemuxVideo(packet: inout YLFPacketRef?, ownedPacket: YLFPacketRef,
                         generation packetGeneration: UInt64) -> Void? {
        let shouldCancel = { [weak self] in
          guard let self else { return true }
          return self.stateLock.withLock {
            self.disposed || !self.active || self.reconfiguring
              || self.generation != packetGeneration
          }
        }
    return video.consume(packet: &packet, ownedPacket: ownedPacket, generation: packetGeneration,
      hasAudio: demux.selectedAudioStream != nil, compatibility: services.compatibility,
      shouldCancel: shouldCancel,
      onSubmitted: { [self] in stateLock.withLock { prebufferedVideoSample = true } },
      onCancelled: { [self] in stateLock.withLock { pumping = false } })
  }

  func shouldCancelVideoTask(generation packetGeneration: UInt64) -> Bool {
    stateLock.withLock { disposed || !active || generation != packetGeneration }
  }

  func isVideoDrainCurrent(generation packetGeneration: UInt64) -> Bool {
    stateLock.withLock { !disposed && active && generation == packetGeneration }
  }

  private func cancelVideoSubmissions() { video.cancelVideoSubmissions() }

  func shouldReportVideoFailure(generation taskGeneration: UInt64) -> Bool {
    stateLock.withLock {
      !disposed && active && !reconfiguring && generation == taskGeneration
    }
  }

  func beginLiveReconnect(
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
      guard demux.mediaPolicy.isLive, !disposed, active, !reconfiguring,
            generation == packetGeneration else { return nil }
      generation &+= 1
      audio.audioGeneration &+= 1
      reconfiguring = true
      pumping = false
      demuxEOF = false
      completionSent = false
      recovery.awaitingReconnectFirstFrame = false
      let detachedMedia = demux.openedMedia
      demux.openedMedia = nil
      let detachedToken = demux.sourceCancellationToken
      demux.sourceCancellationToken = nil
      let detachedDecoder = video.decoder
      video.decoder = nil
      let detachedAudio = audio.audioRenderer
      audio.audioRenderer = nil
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
    audio.pendingAudioPacket = nil
    prebufferedVideoSample = false
    audio.audioAnchored = false
    presentation.frameScheduler.flush(generation: transition.generation)
    presentation.postSeekGate.reset(targetUs: nil)
    stateLock.withLock { presentation.currentPixelBuffer = nil; presentation.clearOutput() }

    DispatchQueue.main.async { [weak self] in
      transition.audio?.pause()
      if let self {
        let isCurrent = self.stateLock.withLock {
          self.active && self.reconfiguring
            && self.generation == transition.generation
        }
        if isCurrent {
          self.presentation.mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
          self.presentation.mediaClock.seek(to: 0)
          self.status = "buffering"
          self.emitState()
        }
        self.demux.worker.async { [weak self] in
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

  var recoveryGeneration: UInt64 { stateLock.withLock { generation } }
  func mayScheduleRecovery(generation reconnectGeneration: UInt64) -> Bool {
    stateLock.withLock { !disposed && active && reconfiguring && generation == reconnectGeneration }
  }
  func emitRecoveryRetry(attempt: Int, delayMs: Int64, error: NativePlayerError,
                         generation reconnectGeneration: UInt64) {
    guard stateLock.withLock({ active && reconfiguring && generation == reconnectGeneration }) else { return }
    emit(.retry(attempt: attempt, delayMs: delayMs, error: error))
  }
  func installRecoveryWorkItem(_ workItem: DispatchWorkItem, generation reconnectGeneration: UInt64) -> Bool {
    return stateLock.withLock { () -> Bool in
      guard !disposed, active, reconfiguring, generation == reconnectGeneration
      else { return false }
      recovery.reconnectWorkItem?.cancel()
      recovery.reconnectWorkItem = workItem
      return true
    }
  }
  func beginRecoveryOpen(_ token: YlOpenCancellationToken, generation reconnectGeneration: UInt64) -> Bool {
    return stateLock.withLock { () -> Bool in
      guard !disposed, active, reconfiguring, generation == reconnectGeneration
      else { return false }
      recovery.reconnectWorkItem = nil
      demux.sourceCancellationToken = token
      return true
    }
  }
  func installRecoveryCandidate(_ candidate: YlFallbackReconnectPipeline,
                                token: YlOpenCancellationToken, generation reconnectGeneration: UInt64) -> Bool {
    return stateLock.withLock { () -> Bool in
        guard !disposed, active, reconfiguring,
              generation == reconnectGeneration,
              demux.sourceCancellationToken === token,
              recovery.liveReconnectController.shouldInstall(
                reconnectGeneration: reconnectGeneration,
                currentGeneration: generation
              ) else { return false }
        demux.mediaInfo = candidate.info
        demux.videoStream = candidate.videoStream
        demux.audioStreams = candidate.audioStreams
        demux.audioCookies = candidate.audioCookies
        video.format = candidate.videoFormat
        demux.selectedAudioStream = candidate.selectedAudioStream
        demux.openedMedia = candidate.media
        video.decoder = candidate.decoder
        audio.audioRenderer = candidate.audioRenderer
        audio.pendingAudioPacket = nil
        prebufferedVideoSample = false
        demuxEOF = false
        completionSent = false
        audio.audioAnchored = false
        recovery.awaitingReconnectFirstFrame = true
        currentError = nil
        return true
      }
  }
  func resumeRecovery(generation reconnectGeneration: UInt64) {
      stateLock.withLock { demux.initialKeyframeGate.reset() }
      presentation.frameScheduler.flush(generation: reconnectGeneration)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        let shouldResume = self.stateLock.withLock { () -> Bool in
          guard !self.disposed, self.active, self.reconfiguring,
                self.generation == reconnectGeneration else { return false }
          self.reconfiguring = false
          return true
        }
        guard shouldResume else { return }
        self.presentation.mediaClock.seek(to: 0)
        if self.playing {
          do {
            if self.demux.selectedAudioStream != nil {
              try self.currentAudioRenderer?.play()
            }
            self.presentation.mediaClock.play(atHostTimeUs: Self.hostTimeUs())
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
        self.emit(.tracksChanged(audio: self.audioTracks, video: self.videoTracks))
        self.emitState()
        self.requestPump()
      }
  }
  func shouldRetryRecovery(token: YlOpenCancellationToken, generation reconnectGeneration: UInt64) -> Bool {
    return stateLock.withLock { () -> Bool in
        if demux.sourceCancellationToken === token { demux.sourceCancellationToken = nil }
        return !disposed && active && reconfiguring
          && generation == reconnectGeneration && !token.isCancelled
      }
  }
  func reportRecoveryExhaustion(_ error: NativePlayerError, generation reconnectGeneration: UInt64) {
      let shouldFail = stateLock.withLock { () -> Bool in
        guard !disposed, active, reconfiguring,
              generation == reconnectGeneration else { return false }
        reconfiguring = false
        playing = false
        return true
      }
      guard shouldFail else { return }
      presentation.displayLink?.isPaused = true
      setFailure(error)
  }

  private func scheduleLiveReconnect(after error: NativePlayerError, generation: UInt64) {
    recovery.scheduleLiveReconnect(after: error, generation: generation)
  }

  func seek(
    toMs positionMs: Int64,
    cancellationToken: YlOpenCancellationToken?
  ) throws {
    let targetUs = max(0, positionMs) * 1_000
    try YlFallbackSeekPolicy(isSeekable: demux.isSeekable) { _ in }.seek(toUs: targetUs)
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
        presentation.mediaClock.seek(to: targetUs)
        emitState()
      }
      return
    }
    let entry = try onMainSync {
      try cancellationToken?.throwIfCancelled()
      let value = try stateLock.withLock {
        guard !disposed, active, !reconfiguring, let media = demux.openedMedia else {
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
    // serialized on demux.worker with teardown; construction never blocks that queue.
    func requireCurrentSeek(_ expectedGeneration: UInt64) throws {
      try cancellationToken?.throwIfCancelled()
      guard !disposed, !stopped, active, generation == expectedGeneration,
            demux.openedMedia === media else {
        throw YlOpenCancellationToken.cancellationError()
      }
    }
    var operationGeneration = UInt64(0)
    let transaction = YlFallbackLifecycleTransaction(
      pauseClock: { [self] in
        try onMainSync {
          try stateLock.withLock { try requireCurrentSeek(entry.generation) }
          currentAudioRenderer?.pause()
          presentation.mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
        }
      },
      advanceGeneration: { [self] in
        try cancellationToken?.throwIfCancelled()
        return try stateLock.withLock {
          guard !disposed, active, generation == entry.generation,
                demux.openedMedia === media else {
            throw YlOpenCancellationToken.cancellationError()
          }
          generation &+= 1
          operationGeneration = generation
          return operationGeneration
        }
      },
      stopDemux: { [self] in
        media.interruptRead()
        demux.worker.sync { cancelVideoSubmissions() }
        media.resumeReads()
        try cancellationToken?.throwIfCancelled()
      },
      clearBuffers: { [self] nextGeneration in
        try demux.worker.sync {
          try stateLock.withLock {
            try requireCurrentSeek(nextGeneration)
            audio.pendingAudioPacket = nil
            prebufferedVideoSample = false
            demuxEOF = false
            completionSent = false
            audio.audioAnchored = false
            presentation.currentPixelBuffer = nil; presentation.clearOutput()
          }
          presentation.frameScheduler.flush(generation: nextGeneration)
        }
      },
      seekDemux: { [self] targetUs in
        try cancellationToken?.throwIfCancelled()
        try demux.seek(media, toMediaTimeUs: targetUs)
        try cancellationToken?.throwIfCancelled()
      },
      resetAudio: { [self] nextGeneration in
        try demux.worker.sync {
          let renderer = try stateLock.withLock { () -> YlAudioRenderer? in
            try requireCurrentSeek(nextGeneration)
            audio.audioGeneration = nextGeneration
            return audio.audioRenderer
          }
          renderer?.reset(generation: nextGeneration)
        }
      },
      recreateVideo: { [self] nextGeneration in
        try demux.worker.sync {
          let previous = try stateLock.withLock { () -> YlVideoToolboxDecoder? in
            try requireCurrentSeek(nextGeneration)
            let previous = video.decoder
            video.decoder = nil
            return previous
          }
          previous?.dispose()
        }
        let candidate = try makeDecoder()
        var installed = false
        defer { if !installed { candidate.dispose() } }
        try demux.worker.sync {
          let previous = try stateLock.withLock { () -> YlVideoToolboxDecoder? in
            try requireCurrentSeek(nextGeneration)
            let previous = video.decoder
            video.decoder = candidate
            installed = true
            return previous
          }
          previous?.dispose()
        }
      },
      suppressFramesBefore: { [self] targetUs in
        try onMainSync {
          try stateLock.withLock { try requireCurrentSeek(operationGeneration) }
          presentation.postSeekGate.reset(targetUs: targetUs)
          presentation.mediaClock.seek(to: targetUs)
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
            if demux.selectedAudioStream != nil { try currentAudioRenderer?.play() }
            presentation.mediaClock.play(atHostTimeUs: Self.hostTimeUs())
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
          active && generation == operationGeneration && demux.openedMedia === media
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
        presentation.mediaClock.play(atHostTimeUs: Self.hostTimeUs())
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
      presentation.mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
      presentation.displayLink?.isPaused = true
      setFailure(error)
    }
  }

  private func makeDecoder() throws -> YlVideoToolboxDecoder {
    try video.makeDecoder(format: video.format)
  }

  func makeLiveReconnectPipeline(
    generation reconnectGeneration: UInt64,
    cancellationToken: YlOpenCancellationToken
  ) throws -> YlFallbackReconnectPipeline {
    try cancellationToken.throwIfCancelled()
    let reopenedMedia = try demux.open(
      recipe: demux.sourceRecipe,
      networkBufferBytes: bufferBudget.networkBytes,
      sessionConfiguration: demux.sessionConfiguration,
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
    let activeQualityConstraint = stateLock.withLock { qualityConstraint }
    let catalog = try demux.inspectReopened(context: validContext, info: info) { selectedVideo in
      try YlFallbackQualityPolicy.validate(
        constraint: activeQualityConstraint,
        stream: Self.videoDescriptor(selectedVideo)
      )
    }
    let selectedVideo = catalog.video
    let supportedAudio = catalog.audio
    let copiedAudioCookies = catalog.cookies

    let candidateFormat = try video.makeFormatDescription(
      context: validContext,
      streamIndex: selectedVideo.index
    )
    let newDecoder = try video.makeDecoder(format: candidateFormat)
    candidateDecoder = newDecoder

    let preferredAudioIndex = demux.selectedAudioStream?.index
    let reselectedAudio = preferredAudioIndex.flatMap { preferredIndex in
      supportedAudio.first { $0.index == preferredIndex }
    } ?? supportedAudio.first
    let newAudioRenderer = audio.makeRenderer()
    candidateAudio = newAudioRenderer
    if let reselectedAudio {
      try newAudioRenderer.configure(stream: audio.reconnectConfiguration(
        for: reselectedAudio, generation: reconnectGeneration, copiedAudioCookies: copiedAudioCookies))
      newAudioRenderer.setVolume(audio.desiredVolume)
      newAudioRenderer.setRate(audio.desiredRate)
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
    let reopenedMedia = try demux.open(
      recipe: demux.sourceRecipe,
      networkBufferBytes: bufferBudget.networkBytes,
      sessionConfiguration: demux.sessionConfiguration
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

    let candidateFormat = try video.makeFormatDescription(
      context: validContext,
      streamIndex: demux.videoStream.index
    )
    candidateDecoder = try video.makeDecoder(format: candidateFormat)
    let renderer = audio.makeRenderer()
    candidateAudio = renderer
    if let currentAudioStream = demux.selectedAudioStream {
      try renderer.configure(stream: audioConfiguration(
        for: currentAudioStream,
        generation: audio.audioGeneration
      ))
      renderer.setVolume(audio.desiredVolume)
      renderer.setRate(audio.desiredRate)
    }
    if positionUs > 0 {
      try demux.seek(reopenedMedia, toMediaTimeUs: positionUs)
      presentation.postSeekGate.reset(targetUs: positionUs)
    }

    // This path also restores a quiesced local pipeline whose demux/audio are
    // retained. Retire those resources only after the candidate seek succeeds.
    let retiredMedia = demux.openedMedia
    let retiredDecoder = video.decoder
    let retiredAudio = audio.audioRenderer
    video.format = candidateFormat
    demux.openedMedia = reopenedMedia
    video.decoder = candidateDecoder
    candidateDecoder = nil
    audio.audioRenderer = renderer
    candidateAudio = nil
    audio.pendingAudioPacket = nil
    prebufferedVideoSample = false
    stateLock.withLock { demux.initialKeyframeGate.reset() }
    demuxEOF = false
    completionSent = false
    audio.audioAnchored = false
    presentation.frameScheduler.flush(generation: generation)
    presentation.mediaClock.seek(to: positionUs)
    mediaNeedsClose = false
    retiredDecoder?.dispose()
    retiredAudio?.dispose()
    retiredMedia?.cancelInput()
    retiredMedia?.close()
  }

  private func installDisplayLink(paused: Bool) { presentation.installDisplayLink(paused: paused) }

  private func completeIfDrained(atHostTimeUs hostTimeUs: Int64) {
    let shouldComplete = stateLock.withLock {
      active && playing && demuxEOF && !completionSent
        && audio.pendingAudioPacket == nil
    }
    guard shouldComplete, video.submissions.isDrained,
          presentation.frameScheduler.pendingPTS.isEmpty,
          (currentAudioRenderer?.scheduledDurationUs ?? 0) == 0 else { return }
    stateLock.withLock {
      guard !completionSent else { return }
      completionSent = true
      playing = false
    }
    presentation.mediaClock.pause(atHostTimeUs: hostTimeUs)
    presentation.displayLink?.isPaused = true
    status = "completed"
    emitState()
  }

  private func setFailure(_ error: NativePlayerError) {
    let details = NativePlayerError(
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
        audioGeneration: audio.audioGeneration
      ) else { return nil }
      generation = generations.videoGeneration
      audio.audioGeneration = generations.audioGeneration
      active = false
      playing = false
      reconfiguring = true
      pumping = false
      demuxEOF = false
      completionSent = false
      recovery.awaitingReconnectFirstFrame = false
      status = "error"
      currentError = details
      let detachedMedia = demux.openedMedia
      demux.openedMedia = nil
      let detachedToken = demux.sourceCancellationToken
      demux.sourceCancellationToken = nil
      let detachedReconnect = recovery.reconnectWorkItem
      recovery.reconnectWorkItem = nil
      return (generation, detachedMedia, detachedToken, detachedReconnect)
    }
    guard let transition else { return }

    recovery.liveReconnectController.cancel()
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
        self.demux.worker.async { transition.media?.close() }
        return
      }
      self.presentation.displayLink?.invalidate()
      self.presentation.displayLink = nil
      let renderer = self.stateLock.withLock { self.audio.audioRenderer }
      renderer?.pause()
      self.presentation.mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
      self.presentation.frameScheduler.flush(generation: transition.generation)
      self.presentation.postSeekGate.reset(targetUs: nil)
      self.stateLock.withLock { self.presentation.currentPixelBuffer = nil; self.presentation.clearOutput() }
      self.emit(.failure(details))
      self.emitState()

      self.demux.worker.async { [weak self] in
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
          let detachedDecoder = self.video.decoder
          self.video.decoder = nil
          let detachedAudio = self.audio.audioRenderer
          self.audio.audioRenderer = nil
          self.audio.pendingAudioPacket = nil
          self.prebufferedVideoSample = false
          self.audio.audioAnchored = false
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

  func selectAudioTrack(
    _ trackId: String?,
    cancellationToken: YlOpenCancellationToken?
  ) throws {
    try cancellationToken?.throwIfCancelled()
    let requestedStream = try demux.audioStream(for: trackId)
    guard requestedStream.index != demux.selectedAudioStream?.index else { return }

    let initialGeneration = stateLock.withLock { generation }
    if cancellationToken == nil, !stateLock.withLock({ active }) {
      try onMainSync {
        try stateLock.withLock {
          guard !disposed, !stopped, generation == initialGeneration else {
            throw YlOpenCancellationToken.cancellationError()
          }
        }
        demux.selectedAudioStream = requestedStream
        stateLock.withLock { audio.audioGeneration &+= 1 }
        emit(.tracksChanged(audio: audioTracks, video: videoTracks))
        emitState()
      }
      return
    }

    let nextAudioGeneration = stateLock.withLock { audio.audioGeneration &+ 1 }
    let candidate = audio.makeRenderer()
    do {
      try candidate.configure(stream: audioConfiguration(
        for: requestedStream,
        generation: nextAudioGeneration
      ))
      candidate.setVolume(audio.desiredVolume)
      candidate.setRate(audio.desiredRate)
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
      let positionUs = presentation.mediaClock.position(atHostTimeUs: now)
      let value = try stateLock.withLock {
        guard !disposed, active, !reconfiguring, let media = demux.openedMedia else {
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
      presentation.mediaClock.pause(atHostTimeUs: now)
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
    demux.worker.sync {}
    media.resumeReads()
    try cancellationToken?.throwIfCancelled()
    do {
      try onMainSync {
        try cancellationToken?.throwIfCancelled()
        guard stateLock.withLock({
          active && generation == state.generation && demux.openedMedia === media
        }) else {
          throw YlOpenCancellationToken.cancellationError()
        }
        let previous = audio.audioRenderer
        audio.audioRenderer = candidate
        candidateOwnedByBackend = true
        demux.selectedAudioStream = requestedStream
        audio.pendingAudioPacket = nil
        audio.audioAnchored = false
        stateLock.withLock {
          audio.audioGeneration = nextAudioGeneration
          reconfiguring = false
        }
        previous?.dispose()
        presentation.mediaClock.seek(to: state.positionUs)
        if state.wasPlaying {
          try candidate.play()
          presentation.mediaClock.play(atHostTimeUs: Self.hostTimeUs())
        }
        emit(.tracksChanged(audio: audioTracks, video: videoTracks))
      }
      try cancellationToken?.throwIfCancelled()
      endControlOperation()
      try onMainSync {
        try cancellationToken?.throwIfCancelled()
        guard stateLock.withLock({
          active && generation == state.generation && demux.openedMedia === media
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
      presentation.mediaClock.seek(to: state.positionUs)
      if state.wasPlaying {
        try? currentAudioRenderer?.play()
        presentation.mediaClock.play(atHostTimeUs: Self.hostTimeUs())
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

  private func audioConfiguration(for stream: YLFStreamInfo, generation: UInt64) -> YlAudioStreamConfiguration {
    audio.configuration(for: stream, generation: generation, audioCookies: demux.audioCookies)
  }

  private func audioCodecName(_ stream: YLFStreamInfo) -> String { audio.codecName(stream) }

  private var selectedAudioCodecName: String {
    demux.selectedAudioStream.map(audioCodecName) ?? "Compressed"
  }

  private var audioTracks: [YlNativeTrack] { demux.audioTracks(codecName: audio.codecName) }
  private var videoTracks: [YlNativeTrack] { demux.videoTracks }

  private static func hostTimeUs() -> Int64 { YlPresentationCoordinator.hostTimeUs() }

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
