import yl_player_media_core
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
  var isolatedAudioClockStatistics: YlIsolatedAudioClockStatistics? { presentation.isolatedAudioClockStatistics }
  var timedVideoStatistics: YlTimedVideoStatistics? { presentation.timedVideoStatistics }
  var isActive: Bool { stateLock.withLock { active } }
  var playbackIntent: Bool { stateLock.withLock { playing } }
  var requiresAsyncActivation: Bool {
    // An active seek temporarily detaches its decoder while rebuilding it. The
    // command FIFO owns that replacement; play must not open a competing pipeline.
    guard !isActive else { return false }
    // A demux cursor alone cannot restore a retired VT session: its next packet
    // may depend on a keyframe consumed by the old video.decoder (R22).
    let needsPipeline = demux.context == nil || (services.compatibility.limitsVideoReservations && !video.hasDecoder)
    guard needsPipeline else { return false }
    let sourceRecipe = demux.sourceRecipe
    switch sourceRecipe {
    case .network, .hls, .rtmp: return true
    case .local: return false
    }
  }

  var isNetworkSource: Bool {
    let isNetwork: Bool
    let sourceRecipe = demux.sourceRecipe
    switch sourceRecipe {
    case .network, .hls, .rtmp: isNetwork = true
    case .local: isNetwork = false
    }
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

  var liveRecoveryContinuity: YlRecoveryCoordinator.Continuity { recovery.continuity }
  func retainLiveRecoveryContinuity(_ value: YlRecoveryCoordinator.Continuity) { recovery.retainContinuity(value) }
  private var livePlaybackRequestId: Int64?
  var livePlaybackState: YlNativeLivePlayback? {
    guard demux.mediaPolicy.isLive, isNetworkSource, bufferBudget.boundedPlan == nil else { return nil }
    return YlNativeLivePlayback(mode: configuration.bufferMode == "lowLatency" ? .lowLatency : .smoothPlayback,
      switchableModes: [.smoothPlayback, .lowLatency], committedRequestId: livePlaybackRequestId)
  }
  func acknowledgeLivePlaybackMode(_ mode: YlNativeLiveMode, requestId: Int64) throws -> YlNativeLivePlayback {
    guard let value = livePlaybackState, value.mode == mode, isActive, !isStopped else { throw YlNativeLivePlayback.unsupported }
    livePlaybackRequestId = requestId
    return YlNativeLivePlayback(mode: mode, switchableModes: value.switchableModes, committedRequestId: requestId)
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
  private let metricsCollector: YlMetricsCollector
  private let boundedStateLock = NSLock()
  private var boundedStartedValue = false
  private var boundedProducerLimitedValue = false
  private var boundedStarted: Bool {
    get { boundedStateLock.withLock { boundedStartedValue } }
    set { boundedStateLock.withLock { boundedStartedValue = newValue } }
  }
  private var boundedProducerLimited: Bool {
    get { boundedStateLock.withLock { boundedProducerLimitedValue } }
    set { boundedStateLock.withLock { boundedProducerLimitedValue = newValue } }
  }
  private var bufferReleaseObserver: UUID?
  private var qualityConstraint: YlFallbackQualityConstraint
  private let stateLock = NSLock()
  private var active = false
  private var playing = false
  private var rtmpPaused = false
  private var livePausedAt: TimeInterval?
  private var pausedRecovery: (() -> Void)?
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
  private let usesInBandVideoConfiguration: Bool
  private var openStartedAt = CACurrentMediaTime()
  private var openDurationMs: Int64?
  private var currentError: NativePlayerError?

  private var currentAudioRenderer: YlAudioPipeline.Resource? {
    audio.currentResource
  }

  init(
    playerId: Int64,
    services: YlPlatformServices,
    configuration: PlayerConfiguration,
    prepared: YlPreparedFallback,
    qualityConstraint: YlFallbackQualityConstraint = .unconstrained,
    generation: UInt64,
    videoSessionFactory: YlVTSessionFactory? = nil,
    mediaClock providedMediaClock: YlMediaClock? = nil,
    audioRendererFactory: any YlAudioRendererMaking = YlPlatformAudioRendererFactory(),
    presentationScheduler: any YlPresentationScheduling = YlFrameScheduler(),
    demuxControl: any YlDemuxControlling = YlOpenedMediaControl(),
    loadRequestId: String? = nil,
    channelIdentity: UInt64? = nil,
    emit: @escaping (YlNativeBackendCallback) -> Void,
    audioTerminalCandidateEnabled: Bool = false,
    timedVideoCandidateEnabled: Bool = false,
    timedVideoDiagnosticsEnabled: Bool = false
  ) throws {
    guard !YlHDRVideoPolicy.isHDR(prepared.videoFormat) || services.nativeViewType != nil else {
      throw NativePlayerError(category: "unsupported", code: "render.hdr_surface_unavailable",
        message: "HDR video requires a native HDR display surface.")
    }
    try YlFallbackQualityPolicy.validate(
      constraint: qualityConstraint,
      stream: Self.videoDescriptor(prepared.videoStream)
    )
    self.loadRequestId = loadRequestId
    if let channelIdentity { self.channelGeneration = channelIdentity }
    self.playerId = playerId
    self.services = services
    self.configuration = configuration
    self.usesInBandVideoConfiguration = prepared.usesInBandVideoConfiguration
    self.bufferBudget = try YlFallbackBufferBudget.make(configuration: configuration, prepared: prepared)
    self.metricsCollector = YlMetricsCollector(scope: prepared.bufferScope, bounded: prepared.boundedPlan != nil)
    let resumeState = prepared.resumeState
    self.qualityConstraint = qualityConstraint
    self.generation = generation
    self.onEvent = emit
    self.demux = try YlDemuxPipeline(prepared: prepared, lock: stateLock, bufferBudget: bufferBudget, control: demuxControl)
    self.video = prepared.takePreparedVideo() ?? YlVideoPipeline(format: prepared.videoFormat, bufferBudget: bufferBudget,
      factory: videoSessionFactory ?? YlHardwareVTSessionFactory(policy: prepared.decoderFactoryPolicy), policy: prepared.decoderPolicy,
      felConfiguration: prepared.felConfiguration, softwareConfiguration: prepared.softwareConfiguration,
      softwareServices: prepared.softwareServices)
    let localSource: Bool
    if case .local = prepared.sourceRecipe { localSource = true } else { localSource = false }
    self.audio = YlAudioPipeline(bufferBudget: bufferBudget, lock: stateLock, generation: generation, factory: audioRendererFactory,
      completionContext: .init(enabled: audioTerminalCandidateEnabled, platform: services.platform,
        localFiniteSeekable: localSource && !prepared.policy.isLive && demux.isSeekable && demux.mediaInfo.duration_us > 0,
        hasBoundedPlan: prepared.boundedPlan != nil, codec: .unsupported, sampleRate: 0, channels: 0, rate: 1))
    self.audio.beforeOutput = services.beforeAudioOutput
    self.presentation = YlPresentationCoordinator(services: services, lock: stateLock,
      openedAt: openStartedAt, positionEventIntervalMs: configuration.positionEventIntervalMs, scheduler: presentationScheduler)
    self.recovery = YlRecoveryCoordinator(configuration: configuration.network,
      scheduler: demux.recoveryScheduler, rtmpBudget: prepared.sourceRecipe.rtmpRecovery)
    self.playing = resumeState?.shouldPlay ?? false
    self.savedPositionUs = resumeState?.positionUs ?? 0
    super.init()

    bufferReleaseObserver = prepared.bufferScope.ledger.onRelease { [weak self] in
      DispatchQueue.main.async { [weak self] in self?.requestPump() }
    }
    presentation.configureBounded(prepared.boundedPlan)
    presentation.configureTimedCandidate(enabled: timedVideoCandidateEnabled && services.platform == .macos
      && services.nativeViewType != nil && localSource && !prepared.policy.isLive
      && demux.isSeekable && demux.mediaInfo.duration_us > 0 && prepared.boundedPlan == nil,
      requiresAudioAnchor: demux.selectedAudioStream != nil, diagnosticsEnabled: timedVideoDiagnosticsEnabled)
    self.presentation.configureClock(providedMediaClock, audioTime: { [weak self] in
      guard let self else { return nil }
      let renderer = self.audio.currentResource
      return renderer?.renderedAudioTime
    })
    if presentation.configureIsolatedAudioClock(generation: audio.audioGeneration, read: { [weak self] generation in
      guard let self, let resource = self.audio.currentResource else { return .waiting }
      // A finite audio gap must not freeze the independent video worker when
      // AppKit stops delivering display ticks. Advance only through decoded
      // video, on the same sampler that reads the audio clock; never via UI.
      resource.advanceSilence(through: self.presentation.pendingFrames.last,
        atHostTimeUs: Self.hostTimeUs(), expectedGeneration: generation)
      return resource.clockObservation(expectedGeneration: generation)
    }) {
      audio.beforeClockControl = { [weak presentation] in presentation?.invalidateAudioClock() }
      audio.onClockGenerationChanged = { [weak presentation] generation in presentation?.setAudioClockGeneration(generation) }
    }
    audio.initializeRenderer()
    demux.output = self
    recovery.session = self
    presentation.output = self
    audio.output = self
    audio.timeline = self.presentation
    self.presentation.seek(to: savedPositionUs)
    // Demux seeks land on an earlier keyframe; suppress that preroll just as
    // in-place pipeline restoration does before it can re-anchor the clock.
    if savedPositionUs > 0 { presentation.suppressFramesBefore( savedPositionUs) }
    video.connect(self)
    do {
      if !video.hasDecoder { try video.initializeDecoder() }
      if let audioStream = demux.selectedAudioStream {
        try audio.configureInitial(stream: audioStream, cookies: demux.audioCookies)
      }
    } catch {
      video.discardDecoder()
      audio.discardRenderer()
      demux.discardMedia()
      throw error
    }
    presentation.flushFrames(generation: generation)
    boundedStarted = false; boundedProducerLimited = false
    bufferBudget.bufferScope?.beginMediaGeneration()
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
          message: "The playback audio session could not be activated.", diagnostic: YlAppleSafeDiagnostics.diagnostic(error))
      }
    }
    if playing { try audio.prepareForPlayback() }
    if requiresAsyncActivation {
      throw NativePlayerError(
        category: "internal",
        code: "\(YlApplePlatform.current.rawValue).async_activation_required",
        message: "Network Matroska reactivation requires background preparation."
      )
    }
    if demux.context == nil || !audio.hasRenderer || (services.compatibility.limitsVideoReservations && !video.hasDecoder) {
      try rebuildPipeline(positionUs: savedPositionUs)
    } else if !video.hasDecoder {
      try video.initializeDecoder()
    }
    if !presentation.hasDisplay { installDisplayLink(paused: false) }
    stateLock.withLock {
      active = true
      reconfiguring = false
    }
    presentation.setDisplayPaused(false)
    if playing && bufferBudget.boundedPlan == nil {
      if demux.selectedAudioStream != nil { if bufferBudget.boundedPlan == nil || boundedStarted { try audio.playInstalled() } }
      if bufferBudget.boundedPlan == nil || boundedStarted { presentation.play(atHostTimeUs: Self.hostTimeUs()) }
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
    let positionBeforeRelease = stopping ? nil : presentation.position(atHostTimeUs: Self.hostTimeUs())
    stateLock.lock()
    guard !disposed,
          stopping || active || demux.currentMedia != nil || video.hasDecoder || audio.hasRenderer else {
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
    rtmpPaused = false; pausedRecovery = nil; livePausedAt = nil
    reconfiguring = true
    generation &+= 1
    audio.advanceGeneration()
    let currentGeneration = generation
    let reconnectToCancel = recovery.detachScheduledWork()
    let mediaToClose = demux.detachMedia()
    let tokenToCancel = demux.detachCancellationToken()
    stateLock.unlock()
    if stopping { recovery.cancelBudget() }
    reconnectToCancel?.cancel()
    presentation.retireDisplay()
    currentAudioRenderer?.pause()
    presentation.pause(atHostTimeUs: Self.hostTimeUs())
    YlFallbackTeardownTransaction(
      cancelInput: { [self] in
        tokenToCancel?.cancel()
        mediaToClose?.cancelInput()
      },
      joinAndRelease: { [self] in
        demux.performSync {
          audio.discardPendingPacket()
          cancelVideoSubmissions()
          video.discardDecoder()
          audio.discardRenderer()
        }
        mediaToClose?.close()
      }
    ).run()
    presentation.flushFrames(generation: currentGeneration)
    boundedStarted = false; boundedProducerLimited = false
    bufferBudget.bufferScope?.beginMediaGeneration()
    stateLock.withLock {
      presentation.clearFrame()
      if mayClearOutput { presentation.clearOutput() }
      pumping = false
      demuxEOF = false
      completionSent = false
      prebufferedVideoSample = false
      audio.resetAnchor()
      reconfiguring = false
    }
    presentation.suppressFramesBefore( nil)
    if stopping {
      channelGeneration = YlBackendGeneration.next()
      savedPositionUs = 0
      openDurationMs = nil
      presentation.resetMilestones()
      recovery.resetAfterStop()
      currentError = nil
      demux.clearStoppedCatalog()
    }
    presentation.seek(to: savedPositionUs)
    status = stopping ? "idle" : "paused"
    resetting = false
    emitState()
  }

  func quiesceForReplacement() {
    // The default audio clock consults stateLock synchronously.
    let positionGeneration = stateLock.withLock { generation }
    let positionBeforeReplacement = presentation.position(atHostTimeUs: Self.hostTimeUs())
    stateLock.lock()
    guard !disposed, active else {
      stateLock.unlock()
      return
    }
    if generation == positionGeneration {
      savedPositionUs = positionBeforeReplacement
    }
    active = false
    pausedRecovery = nil
    reconfiguring = true
    let generations = YlFallbackReplacementGenerationPolicy.quiesce(
      videoGeneration: generation,
      audioGeneration: audio.audioGeneration
    )
    generation = generations.videoGeneration
    audio.adoptGeneration(generations.audioGeneration)
    let currentGeneration = generation
    let reconnectToCancel = recovery.detachScheduledWork()
    let media = demux.currentMedia
    let reconnectTokenToCancel = demux.detachOrphanedCancellation()
    stateLock.unlock()

    reconnectToCancel?.cancel()
    reconnectTokenToCancel?.cancel()

    presentation.retireDisplay()
    currentAudioRenderer?.pause()
    presentation.pause(atHostTimeUs: Self.hostTimeUs())
    media?.interruptRead()
    demux.performSync {
      audio.discardPendingPacket()
      if services.compatibility.limitsVideoReservations {
        cancelVideoSubmissions()
        video.discardDecoder()
      }
    }
    media?.resumeReads()
    presentation.flushFrames(generation: currentGeneration)
    boundedStarted = false; boundedProducerLimited = false
    bufferBudget.bufferScope?.beginMediaGeneration()
    stateLock.withLock {
      presentation.clearFrameAndTexture()
      pumping = false
      demuxEOF = false
      completionSent = false
      prebufferedVideoSample = false
      audio.resetAnchor()
      reconfiguring = false
    }
    presentation.suppressFramesBefore( nil)
    presentation.seek(to: savedPositionUs)
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
    stateLock.withLock { demux.currentMedia }?.handleMemoryWarning()
    deactivate()
  }

  func play() throws {
      // Controls can race the delivered EOF snapshot. A drained generation stays
      // completed until seek/rebuild creates new media work; do not restart its
      // wall clock or reacquire audio for a late play command.
      if stateLock.withLock({ completionSent }) { emitState(); return }
      try audio.prepareForPlayback()
      let refreshGeneration = stateLock.withLock { () -> UInt64? in
        guard active, !disposed, !reconfiguring, bufferBudget.boundedPlan == nil,
          YlLiveResumePolicy.requiresRefresh(lowLatency: configuration.bufferMode == "lowLatency",
            live: demux.mediaPolicy.isLive, pausedAt: livePausedAt, now: CACurrentMediaTime()) else { return nil }
        return generation
      }
      if let refreshGeneration {
        guard recovery.reserveLiveRefresh() else { throw ylRtmpError("resource.exhausted") }
        let refreshCause = demux.sourceRecipe.isRtmp ? ylRtmpError("network.rtmp_disconnected")
          : NativePlayerError(category: "network", code: "network.http_status", message: "The live transport is being refreshed.")
        if beginLiveReconnect(after: refreshCause,
            packetGeneration: refreshGeneration, explicitLiveAttempt: true) {
          stateLock.withLock { playing = true; rtmpPaused = false; livePausedAt = nil }
          status = "buffering"
          emitState()
          return
        }
      }
      let wasPlaying = stateLock.withLock { () -> Bool in
        let previous = playing
        livePausedAt = nil
        playing = true
        return previous
      }
      if !wasPlaying && bufferBudget.boundedPlan == nil {
        if demux.selectedAudioStream != nil { if bufferBudget.boundedPlan == nil || boundedStarted { try currentAudioRenderer?.play() } }
        if bufferBudget.boundedPlan == nil || boundedStarted { presentation.play(atHostTimeUs: Self.hostTimeUs()) }
      }
      let resume = stateLock.withLock { () -> (() -> Void)? in
        rtmpPaused = false
        let pending = pausedRecovery; pausedRecovery = nil
        demux.currentMedia?.setPlaybackPaused(false)
        return pending
      }
      if let resume { demux.performAsync(resume) }
      // Natural EOF pauses display ticks. Seeking resets the media generation,
      // but replay also needs ticks for video, progress and drain completion.
      presentation.setDisplayPaused(false)
      status = "playing"
      emitState()
      requestPump()
  }

  func pause() throws {
      if stateLock.withLock({ completionSent }) { emitState(); return }
      stateLock.withLock {
        if playing { livePausedAt = CACurrentMediaTime() }
        playing = false
        if demux.sourceRecipe.isRtmp {
          rtmpPaused = true; demux.currentMedia?.setPlaybackPaused(true)
        }
      }
      if demux.selectedAudioStream != nil { currentAudioRenderer?.pause() }
      presentation.pause(atHostTimeUs: Self.hostTimeUs())
      status = "paused"
      emitState()
  }

  func seekToLiveEdge() throws {
      if demux.sourceRecipe.isRtmp {
        beginLiveReconnect(after: ylRtmpError("network.rtmp_disconnected"),
          packetGeneration: recoveryGeneration, explicitLiveAttempt: true)
        return
      }
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
      audio.setRate(rate, hasAudio: demux.selectedAudioStream != nil) {
        presentation.setRate(Double(rate), atHostTimeUs: Self.hostTimeUs())
      }
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
          firstFrameDurationMs: nil, bufferedDurationMs: metricsCollector.managedBufferedDurationMs, bufferedBytes: metricsCollector.managedBufferedBytes,
          droppedVideoFrames: 0, audioUnderruns: 0, reconnectCount: 0), error: nil)))
      return
    }
    let positionUs = presentation.position(atHostTimeUs: Self.hostTimeUs())
    let durationMs = demux.mediaPolicy.durationMs(mediaDurationUs: demux.mediaInfo.duration_us)
    let renderer = currentAudioRenderer
    let scheduledAudioDurationUs = renderer?.scheduledDurationUs ?? 0
    let metrics = collectMetrics(renderer: renderer)
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
        isHardwareDecoding: video.usesHardwareDecoder == true,
        decoderName: video.hardwareEvidence.decoderName,
        audioTracks: audioTracks,
        videoTracks: videoTracks,
        metrics: metrics,
        error: currentError,
        decoderEvidence: video.hardwareEvidence,
        geometry: video.geometry, livePlayback: livePlaybackState
      )))
  }

  private func emitStateDelta() {
    guard !stateLock.withLock({ disposed || stopped || resetting }) else { return }
    let positionUs = presentation.position(atHostTimeUs: Self.hostTimeUs())
    let renderer = currentAudioRenderer
    let scheduledAudioDurationUs = renderer?.scheduledDurationUs ?? 0
    let metrics = collectMetrics(renderer: renderer)
    emit(.delta(YlNativeTimelineDelta(
        positionMs: positionUs / 1_000,
        bufferedPositionMs: (positionUs + scheduledAudioDurationUs) / 1_000,
        isAtLiveEdge: demux.mediaPolicy.isLive,
        liveOffsetMs: nil,
        metrics: metrics
      )))
  }

  private func collectMetrics(renderer: YlAudioPipeline.Resource?) -> YlNativeMetrics {
    if let ready = openDurationMs { metricsCollector.observe(.ready(durationMs: ready)) }
    if let frame = presentation.firstFrameDuration { metricsCollector.observe(.firstFrame(durationMs: frame)) }
    metricsCollector.observe(.playback(status))
    metricsCollector.observe(.videoDropped(total: presentation.lateFrameDropCount))
    metricsCollector.observe(.audioUnderruns(total: audio.observeUnderruns(renderer: demux.selectedAudioStream == nil ? nil : renderer)))
    // Recovery counts only a current, installed reconnect's first frame, never a request retry.
    if recovery.reconnectCount > 0 { metricsCollector.observe(.reconnect(id: UInt64(recovery.reconnectCount))) }
    return metricsCollector.snapshot
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
    audio.advanceGeneration()
    let reconnectToCancel = recovery.detachScheduledWork()
    let mediaToClose = demux.detachMedia()
    let tokenToCancel = demux.detachCancellationToken()
    stateLock.unlock()
    recovery.cancelBudget()
    reconnectToCancel?.cancel()
    presentation.stopAudioClock()
    presentation.retireDisplay()
    YlFallbackTeardownTransaction(
      cancelInput: { [self] in
        tokenToCancel?.cancel()
        mediaToClose?.cancelInput()
      },
      joinAndRelease: { [self] in
        demux.performSync {
          audio.discardPendingPacket()
          cancelVideoSubmissions()
          video.discardDecoder()
          audio.discardRenderer()
          presentation.disposeFrames()
        }
        mediaToClose?.close()
      }
    ).run()
    stateLock.withLock { presentation.clearFrame() }
    if mayClearOutput { presentation.clearOutput() }
  }

  func receive(_ frame: YlVideoFrame) { presentation.receive(frame) }

  func acceptsPresentationFrame(generation frameGeneration: UInt64) -> Bool {
    stateLock.withLock { active && generation == frameGeneration }
  }

  var presentationGeneration: UInt64 { stateLock.withLock { generation } }

  func didAcceptPresentationFrame(generation frameGeneration: UInt64) {
    let completedReconnect = stateLock.withLock { () -> Bool in
      recovery.acceptFirstFrame(isCurrent: generation == frameGeneration)
    }
    if completedReconnect {
      recovery.markFirstFrame()
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

  func presentationDidTick(atHostTimeUs value: Int64) {
    if presentation.isolatedAudioClockStatistics == nil,
       stateLock.withLock({ active && playing && !reconfiguring && !disposed }) {
      currentAudioRenderer?.advanceSilence(
        through: presentation.pendingFrames.last, atHostTimeUs: value
      )
    }
    updateBoundedPlayback(atHostTimeUs: value)
    completeIfDrained(atHostTimeUs: value)
  }
  private func updateBoundedPlayback(atHostTimeUs value: Int64) {
    guard let plan = bufferBudget.boundedPlan,
          stateLock.withLock({ active && playing && !reconfiguring && !disposed }) else { return }
    let duration = bufferBudget.bufferScope?.bufferedDurationUs ?? 0
    let eof = stateLock.withLock { demuxEOF }
    if !boundedStarted, plan.ready(durationUs: duration, eof: eof, producerLimited: boundedProducerLimited) {
      do { if demux.selectedAudioStream != nil { try currentAudioRenderer?.play() } }
      catch { fail(YlManagedBufferLedger.unsupported()); return }
      boundedStarted = true; presentation.play(atHostTimeUs: value); status = "playing"
    } else if boundedStarted && duration == 0 && !eof {
      currentAudioRenderer?.pause(); presentation.pause(atHostTimeUs: value)
      boundedStarted = false; status = "buffering"
    }
    requestPump()
  }
  var allowsBoundedPresentation: Bool { bufferBudget.boundedPlan == nil || boundedStarted }
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
    demux.schedulePump(after: delay) { [weak self] in self?.pumpOne() }
  }

  private func pumpOne() {
    stateLock.lock()
    let shouldContinue = !disposed && active && !reconfiguring
      && !rtmpPaused && (playing || !prebufferedVideoSample)
    let packetGeneration = generation
    if !shouldContinue {
      pumping = false
      stateLock.unlock()
      return
    }
    stateLock.unlock()

    if bufferBudget.boundedPlan != nil {
      let duration = bufferBudget.bufferScope?.bufferedDurationUs ?? 0
      let snapshot = bufferBudget.bufferScope!.ledger.snapshot
      let nearByteLimit = snapshot.maxBytes - snapshot.currentBytes < 256 * 1024
      if (bufferBudget.bufferScope?.shouldPausePacketAdmission == true || nearByteLimit) && duration > 0 {
        stateLock.withLock { pumping = false }; boundedProducerLimited = true; return
      }
    }
    boundedProducerLimited = false
    if audio.hasPendingPacket {
      boundedProducerLimited = true
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
      audio.finishInput()
      video.finishInput(generation: packetGeneration, hasAudio: demux.selectedAudioStream != nil,
                        compatibility: services.compatibility)
  }

  func shouldReportDemuxFailure(generation packetGeneration: UInt64) -> Bool {
    return stateLock.withLock { () -> Bool in
        pumping = false
        return !disposed && active && !reconfiguring && generation == packetGeneration
      }
  }

  var demuxAudioGeneration: UInt64 { stateLock.withLock { audio.audioGeneration } }
  var demuxAudioPresentationStartUs: Int64? { presentation.audioTargetUs }
  func acceptsDemuxAudio(ptsUs: Int64) -> Bool { presentation.acceptsAudio(ptsUs: ptsUs) }
  func consumeDemuxAudio(_ packet: YlCompressedAudioPacket, onBackpressure: (TimeInterval) -> Void) -> Void? {
    audio.enqueue(packet, codecName: selectedAudioCodecName, onBackpressure: onBackpressure)
  }

  func consumeDemuxVideo(packet: inout YLFPacketRef?, ownedPacket: YLFPacketRef,
                         generation packetGeneration: UInt64, managedPayload: YlManagedBufferLedger.Token?) -> Void? {
        let shouldCancel = { [weak self] in
          guard let self else { return true }
          return self.stateLock.withLock {
            self.disposed || !self.active || self.reconfiguring
              || self.generation != packetGeneration
          }
        }
    return video.consume(packet: &packet, ownedPacket: ownedPacket, generation: packetGeneration, managedPayload: managedPayload,
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

  func beginLiveReconnect(after error: NativePlayerError, packetGeneration: UInt64) {
    beginLiveReconnect(after: error, packetGeneration: packetGeneration, explicitLiveAttempt: false)
  }

  @discardableResult
  private func beginLiveReconnect(
    after error: NativePlayerError,
    packetGeneration: UInt64,
    explicitLiveAttempt: Bool
  ) -> Bool {
    if demux.sourceRecipe.isRtmp && !YlRtmpRecoveryBudget.isTransient(error) {
      if shouldReportDemuxFailure(generation: packetGeneration) { setFailure(error) }
      return false
    }
    let transition = stateLock.withLock { () -> (
      generation: UInt64,
      media: YlDemuxPipeline.Resource?,
      token: YlOpenCancellationToken?,
      decoder: YlVideoPipeline.Resource?,
      audio: YlAudioPipeline.Resource?
    )? in
      guard demux.mediaPolicy.isLive, !disposed, active, !reconfiguring,
            generation == packetGeneration else { return nil }
      generation &+= 1
      audio.advanceGeneration()
      reconfiguring = true
      pumping = false
      demuxEOF = false
      completionSent = false
      recovery.clearFirstFrameExpectation()
      let detachedMedia = demux.detachMedia()
      let detachedToken = demux.detachCancellationToken()
      let detachedDecoder = video.detach()
      let detachedAudio = audio.detach()
      return (
        generation,
        detachedMedia,
        detachedToken,
        detachedDecoder,
        detachedAudio
      )
    }
    guard let transition else { return false }

    transition.token?.cancel()
    transition.media?.cancelInput()
    audio.discardPendingPacket()
    prebufferedVideoSample = false
    audio.resetAnchor()
    presentation.flushFrames(generation: transition.generation)
    boundedStarted = false; boundedProducerLimited = false
    bufferBudget.bufferScope?.beginMediaGeneration()
    presentation.suppressFramesBefore( nil)
    stateLock.withLock { presentation.clearFrameAndTexture() }

    DispatchQueue.main.async { [weak self] in
      transition.audio?.pause()
      if let self {
        let isCurrent = self.stateLock.withLock {
          self.active && self.reconfiguring
            && self.generation == transition.generation
        }
        if isCurrent {
          self.presentation.pause(atHostTimeUs: Self.hostTimeUs())
          self.presentation.seek(to: 0)
          self.status = self.stateLock.withLock { self.rtmpPaused ? "paused" : "buffering" }
          self.emitState()
        }
        self.demux.performAsync { [weak self] in
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
            generation: transition.generation, explicitLiveAttempt: explicitLiveAttempt
          )
        }
      } else {
        transition.decoder?.dispose()
        transition.audio?.dispose()
        transition.media?.close()
      }
    }
    return true
  }

  var recoveryGeneration: UInt64 { stateLock.withLock { generation } }
  var managedRequestFailure: NativePlayerError? {
    let request: YlNetworkRequestRecipe
    switch demux.sourceRecipe {
    case let .network(value, _), let .hls(value): request = value
    case .local, .rtmp: return nil
    }
    return request.managedIntent?.terminalFailure
  }

  func deferRecoveryIfPaused(generation reconnectGeneration: UInt64, operation: @escaping () -> Void) -> Bool {
    stateLock.withLock {
      guard demux.sourceRecipe.isRtmp, rtmpPaused, !disposed, active,
            reconfiguring, generation == reconnectGeneration else { return false }
      pausedRecovery = operation
      return true
    }
  }
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
      recovery.replaceScheduledWork(workItem)
      return true
    }
  }
  func beginRecoveryOpen(_ token: YlOpenCancellationToken, generation reconnectGeneration: UInt64,
                         whenPaused: @escaping () -> Void) -> Bool {
    return stateLock.withLock { () -> Bool in
      guard !disposed, active, reconfiguring, generation == reconnectGeneration
      else { return false }
      // Play observes either an admitted open or this exact reserved attempt.
      // Storing after releasing the lock could lose a concurrent pause/play.
      if rtmpPaused { pausedRecovery = whenPaused; return false }
      recovery.beginReopen()
      demux.installCancellation(token)
      return true
    }
  }
  func installRecoveryCandidate(_ candidate: YlFallbackReconnectPipeline,
                                token: YlOpenCancellationToken, generation reconnectGeneration: UInt64) -> Bool {
    return stateLock.withLock { () -> Bool in
        guard !disposed, active, reconfiguring,
              generation == reconnectGeneration,
              demux.ownsCancellation(token),
              recovery.mayInstall(
                generation: reconnectGeneration,
                currentGeneration: generation
              ) else { return false }
        demux.installReconnect(candidate)
        candidate.media.setPlaybackPaused(rtmpPaused)
        video.install(candidate.decoder)
        audio.install(candidate.audioRenderer)
        audio.discardPendingPacket()
        prebufferedVideoSample = false
        demuxEOF = false
        completionSent = false
        audio.resetAnchor()
        recovery.expectFirstFrame()
        currentError = nil
        return true
      }
  }
  func resumeRecovery(generation reconnectGeneration: UInt64) {
      stateLock.withLock { demux.resetInitialKeyframeGate() }
      presentation.flushFrames(generation: reconnectGeneration)
      boundedStarted = false; boundedProducerLimited = false
    bufferBudget.bufferScope?.beginMediaGeneration()
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        let shouldResume = self.stateLock.withLock { () -> Bool in
          guard !self.disposed, self.active, self.reconfiguring,
                self.generation == reconnectGeneration else { return false }
          self.reconfiguring = false
          return true
        }
        guard shouldResume else { return }
        self.presentation.seek(to: 0)
        if self.playing {
          do {
            if self.demux.selectedAudioStream != nil {
              if self.bufferBudget.boundedPlan == nil || self.boundedStarted { try self.currentAudioRenderer?.play() }
            }
            if self.bufferBudget.boundedPlan == nil || self.boundedStarted { self.presentation.play(atHostTimeUs: Self.hostTimeUs()) }
            self.status = "playing"
          } catch {
            self.setFailure(NativePlayerError(
              category: "decoderFailure",
              code: "decoder.audio_failed",
              message: "The reconnected audio renderer could not start.",
              diagnostic: YlAppleSafeDiagnostics.diagnostic(error)
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
        demux.clearCancellation(ifOwned: token)
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
      presentation.setDisplayPaused(true)
      setFailure(error)
  }

  private func scheduleLiveReconnect(after error: NativePlayerError, generation: UInt64, explicitLiveAttempt: Bool = false) {
    recovery.scheduleLiveReconnect(after: error, generation: generation, explicitLiveAttempt: explicitLiveAttempt)
  }

  func seek(
    toMs positionMs: Int64,
    cancellationToken: YlOpenCancellationToken?
  ) throws {
    try seek(toUs: max(0, positionMs) * 1_000, selectingAudio: nil, cancellationToken: cancellationToken)
  }

  /// Audio switches involving Opus or Vorbis need the same demux history, video generation
  /// and presentation gate as a seek. A nil target freezes the current position
  /// only after candidate configuration succeeds, before pausing the clock.
  private func seek(
    toUs requestedTargetUs: Int64?,
    selectingAudio requestedStream: YLFStreamInfo?,
    cancellationToken: YlOpenCancellationToken?
  ) throws {
    var targetUs = requestedTargetUs ?? 0
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
        presentation.seek(to: targetUs)
        emitState()
      }
      return
    }
    let candidate = try requestedStream.map { stream in
      try audio.prepareTrack(stream: stream, generation: stateLock.withLock { audio.nextGeneration() },
        cookies: demux.audioCookies)
    }
    var candidateInstalled = false
    defer { if !candidateInstalled { candidate?.dispose() } }
    let entry = try onMainSync {
      try cancellationToken?.throwIfCancelled()
      if requestedTargetUs == nil { targetUs = presentation.position(atHostTimeUs: Self.hostTimeUs()) }
      let value = try stateLock.withLock {
        guard !disposed, active, !reconfiguring, let media = demux.currentMedia else {
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
      demux.resume(media)
    }
    defer { endControlOperation() }
    // Every resource commit checks while holding stateLock. Resource mutation is
    // serialized on demux.worker with teardown; construction never blocks that queue.
    func requireCurrentSeek(_ expectedGeneration: UInt64) throws {
      try cancellationToken?.throwIfCancelled()
      guard !disposed, !stopped, active, generation == expectedGeneration,
            demux.currentMedia === media else {
        throw YlOpenCancellationToken.cancellationError()
      }
    }
    var operationGeneration = entry.generation
    let transaction = YlFallbackLifecycleTransaction(
      pauseClock: { [self] in
        try onMainSync {
          try stateLock.withLock { try requireCurrentSeek(entry.generation) }
          currentAudioRenderer?.pause()
          presentation.pause(atHostTimeUs: Self.hostTimeUs())
        }
      },
      advanceGeneration: { [self] in
        try cancellationToken?.throwIfCancelled()
        return try stateLock.withLock {
          guard !disposed, active, generation == entry.generation,
                demux.currentMedia === media else {
            throw YlOpenCancellationToken.cancellationError()
          }
          generation &+= 1
          operationGeneration = generation
          return operationGeneration
        }
      },
      stopDemux: { [self] in
        demux.interrupt(media)
        demux.joinForControl { cancelVideoSubmissions() }
        demux.resume(media)
        try cancellationToken?.throwIfCancelled()
      },
      clearBuffers: { [self] nextGeneration in
        try demux.performSync {
          try stateLock.withLock {
            try requireCurrentSeek(nextGeneration)
            audio.discardPendingPacket()
            demux.resetInitialKeyframeGate()
            prebufferedVideoSample = false
            demuxEOF = false
            completionSent = false
            audio.resetAnchor()
            presentation.clearFrameAndTexture()
          }
          presentation.flushFrames(generation: nextGeneration)
          boundedStarted = false; boundedProducerLimited = false
    bufferBudget.bufferScope?.beginMediaGeneration()
        }
      },
      seekDemux: { [self] targetUs in
        try cancellationToken?.throwIfCancelled()
        try demux.seek(media, toMediaTimeUs: targetUs)
        try cancellationToken?.throwIfCancelled()
      },
      resetAudio: { [self] nextGeneration in
        try demux.performSync {
          let replacement = try stateLock.withLock { () -> (YlAudioPipeline.Resource?, YlAudioPipeline.Reset) in
            try requireCurrentSeek(nextGeneration)
            var previous: YlAudioPipeline.Resource?
            if let candidate, let requestedStream {
              previous = audio.install(candidate)
              candidateInstalled = true
              demux.selectAudio(requestedStream)
            }
            return (previous, audio.prepareReset(generation: nextGeneration))
          }
          replacement.0?.dispose()
          replacement.1.perform()
        }
      },
      recreateVideo: { [self] nextGeneration in
        try demux.performSync {
          let previous = try stateLock.withLock { () -> YlVideoPipeline.Resource? in
            try requireCurrentSeek(nextGeneration)
            return video.detach()
          }
          previous?.dispose()
        }
        let candidate = try makeDecoder()
        var installed = false
        defer { if !installed { candidate.dispose() } }
        try demux.performSync {
          let previous = try stateLock.withLock { () -> YlVideoPipeline.Resource? in
            try requireCurrentSeek(nextGeneration)
            let previous = video.install(candidate)
            installed = true
            return previous
          }
          previous?.dispose()
        }
      },
      suppressFramesBefore: { [self] targetUs in
        try onMainSync {
          try stateLock.withLock { try requireCurrentSeek(operationGeneration) }
          presentation.suppressFramesBefore( targetUs)
          presentation.seek(to: targetUs)
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
            if demux.selectedAudioStream != nil { if bufferBudget.boundedPlan == nil || boundedStarted { try currentAudioRenderer?.play() } }
            if bufferBudget.boundedPlan == nil || boundedStarted { presentation.play(atHostTimeUs: Self.hostTimeUs()) }
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
          active && generation == operationGeneration && demux.currentMedia === media
        }) else {
          throw YlOpenCancellationToken.cancellationError()
        }
        requestPump()
        if requestedStream != nil { emit(.tracksChanged(audio: audioTracks, video: videoTracks)) }
        emitState()
      }
    } catch let error as NativePlayerError {
      endControlOperation()
      if cancellationToken?.isCancelled == true || error.code == "network.cancelled" {
        if requestedStream != nil && operationGeneration != entry.generation {
          // After cursor/buffer mutation, resuming the retained codec would use
          // unrelated history. Retire this operation instead; a newer generation
          // is protected by transitionToTerminalSeekFailure's authority check.
          transitionToTerminalSeekFailure(YlOpenCancellationToken.cancellationError(),
            operationGeneration: operationGeneration)
        } else {
          transitionToCancelledSeek(wasPlaying: wasPlaying, operationGeneration: operationGeneration)
        }
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
        diagnostic: YlAppleSafeDiagnostics.diagnostic(error)
      )
      endControlOperation()
      if cancellationToken?.isCancelled == true {
        if requestedStream != nil && operationGeneration != entry.generation {
          // After cursor/buffer mutation, resuming the retained codec would use
          // unrelated history. Retire this operation instead; a newer generation
          // is protected by transitionToTerminalSeekFailure's authority check.
          transitionToTerminalSeekFailure(YlOpenCancellationToken.cancellationError(),
            operationGeneration: operationGeneration)
        } else {
          transitionToCancelledSeek(wasPlaying: wasPlaying, operationGeneration: operationGeneration)
        }
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
        if bufferBudget.boundedPlan == nil || boundedStarted { try? currentAudioRenderer?.play() }
        if bufferBudget.boundedPlan == nil || boundedStarted { presentation.play(atHostTimeUs: Self.hostTimeUs()) }
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
      presentation.pause(atHostTimeUs: Self.hostTimeUs())
      presentation.setDisplayPaused(true)
      setFailure(error)
    }
  }

  private func makeDecoder() throws -> YlVideoPipeline.Resource {
    try video.prepareCurrent()
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
    var candidateDecoder: YlVideoPipeline.Resource?
    var candidateAudio: YlAudioPipeline.Resource?
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

    let newDecoder = try video.prepare(context: validContext, streamIndex: selectedVideo.index,
      checkCancellation: { try cancellationToken.throwIfCancelled() },
      rewind: { try demux.seek(reopenedMedia, toMediaTimeUs: 0) })
    candidateDecoder = newDecoder

    let preferredAudioIndex = demux.selectedAudioStream?.index
    let reselectedAudio = preferredAudioIndex.flatMap { preferredIndex in
      supportedAudio.first { $0.index == preferredIndex }
    } ?? supportedAudio.first
    audio.updateSourceEligibility(localFiniteSeekable: false) // Live/network reconnects cannot enter the local candidate.
    let newAudioRenderer = try audio.prepareReconnect(stream: reselectedAudio,
      generation: reconnectGeneration, cookies: copiedAudioCookies,
      onCreated: { resource in candidateAudio = resource })
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
    var candidateDecoder: YlVideoPipeline.Resource?
    var candidateAudio: YlAudioPipeline.Resource?
    defer {
      if mediaNeedsClose {
        candidateDecoder?.dispose()
        candidateAudio?.dispose()
        reopenedMedia.close()
      }
    }

    // This is the same loaded asset. Its container header still lacks the
    // parameter sets recovered during open; retain that format across rebuilds.
    candidateDecoder = try usesInBandVideoConfiguration
      ? video.prepareCurrent()
      : video.prepare(context: validContext, streamIndex: demux.videoStream.index,
          rewind: { try demux.seek(reopenedMedia, toMediaTimeUs: 0) })
    let localSource: Bool
    if case .local = demux.sourceRecipe { localSource = true } else { localSource = false }
    audio.updateSourceEligibility(localFiniteSeekable: localSource && !demux.mediaPolicy.isLive
      && demux.isSeekable && reopenedMedia.supportsRandomAccess && reopenedMedia.info.duration_us > 0)
    let renderer = try audio.prepareRebuild(stream: demux.selectedAudioStream, cookies: demux.audioCookies,
      onCreated: { resource in candidateAudio = resource })
    if positionUs > 0 {
      try demux.seek(reopenedMedia, toMediaTimeUs: positionUs)
      presentation.suppressFramesBefore( positionUs)
    }

    // This path also restores a quiesced local pipeline whose demux/audio are
    // retained. Retire those resources only after the candidate seek succeeds.
    let retiredMedia = demux.currentMedia
    let retiredDecoder = video.detach()
    let retiredAudio = audio.detach()
    demux.installMedia(reopenedMedia)
    video.install(candidateDecoder)
    candidateDecoder = nil
    audio.install(renderer)
    candidateAudio = nil
    audio.discardPendingPacket()
    prebufferedVideoSample = false
    stateLock.withLock { demux.resetInitialKeyframeGate() }
    demuxEOF = false
    completionSent = false
    audio.resetAnchor()
    presentation.flushFrames(generation: generation)
    boundedStarted = false; boundedProducerLimited = false
    bufferBudget.bufferScope?.beginMediaGeneration()
    presentation.seek(to: positionUs)
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
        && !audio.hasPendingPacket
    }
    guard shouldComplete, video.isDrained,
          presentation.pendingFrames.isEmpty, !presentation.hasPendingTimedPresentation,
          !(currentAudioRenderer?.hasPendingPlayback ?? false) else { return }
    stateLock.withLock {
      guard !completionSent else { return }
      completionSent = true
      playing = false
    }
    presentation.pause(atHostTimeUs: hostTimeUs)
    presentation.setDisplayPaused(true)
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
      media: YlDemuxPipeline.Resource?,
      token: YlOpenCancellationToken?,
      reconnect: YlRecoveryCoordinator.ScheduledWork?
    )? in
      guard let generations = YlFallbackTerminalFailurePolicy.begin(
        disposed: disposed,
        active: active,
        hasError: currentError != nil,
        videoGeneration: generation,
        audioGeneration: audio.audioGeneration
      ) else { return nil }
      generation = generations.videoGeneration
      audio.adoptGeneration(generations.audioGeneration)
      active = false
      playing = false
      reconfiguring = true
      pumping = false
      demuxEOF = false
      completionSent = false
      recovery.clearFirstFrameExpectation()
      status = "error"
      currentError = details
      let detachedMedia = demux.detachMedia()
      let detachedToken = demux.detachCancellationToken()
      let detachedReconnect = recovery.detachScheduledWork()
      return (generation, detachedMedia, detachedToken, detachedReconnect)
    }
    guard let transition else { return }

    recovery.cancelBudget()
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
        self.demux.performAsync { transition.media?.close() }
        return
      }
      self.presentation.retireDisplay()
      let renderer = self.audio.currentResource
      renderer?.pause()
      self.presentation.pause(atHostTimeUs: Self.hostTimeUs())
      self.presentation.flushFrames(generation: transition.generation)
      self.boundedStarted = false; self.boundedProducerLimited = false
      self.bufferBudget.bufferScope?.beginMediaGeneration()
      self.presentation.suppressFramesBefore( nil)
      self.stateLock.withLock { self.presentation.clearFrameAndTexture() }
      self.emit(.failure(details))
      self.emitState()

      self.demux.performAsync { [weak self] in
        guard let self else {
          transition.media?.close()
          return
        }
        let resources = self.stateLock.withLock { () -> (
          decoder: YlVideoPipeline.Resource?,
          audio: YlAudioPipeline.Resource?
        ) in
          guard self.generation == transition.generation, !self.active else {
            return (nil, nil)
          }
          let detachedDecoder = self.video.detach()
          let detachedAudio = self.audio.detach()
          self.audio.discardPendingPacket()
          self.prebufferedVideoSample = false
          self.audio.resetAnchor()
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
    let switchesOpus = Int(requestedStream.codec) == YLFCodecOpus
      || demux.selectedAudioStream.map({ Int($0.codec) == YLFCodecOpus }) == true
    let switchesVorbis = Int(requestedStream.codec) == YLFCodecVorbis
      || demux.selectedAudioStream.map({ Int($0.codec) == YLFCodecVorbis }) == true
    let initialGeneration = stateLock.withLock { generation }
    if switchesVorbis, !stateLock.withLock({ active }) {
      throw NativePlayerError(category: "unsupported", code: "policy.vorbis_track_switch_unsupported",
        message: "Activate or resume playback before switching a Vorbis track.")
    }
    if cancellationToken == nil, !stateLock.withLock({ active }) {
      // Inactive pipelines may retain a renderer and a prefetched cursor. Do
      // not change their selection without a full reactivation transaction.
      guard !switchesOpus && !switchesVorbis else {
        throw NativePlayerError(category: "unsupported", code: switchesVorbis ? "policy.vorbis_track_switch_unsupported" : "policy.opus_track_switch_unsupported",
          message: switchesVorbis ? "Activate or resume playback before switching a Vorbis track." : "Activate or resume playback before switching an Opus track.")
      }
      try onMainSync {
        try stateLock.withLock {
          guard !disposed, !stopped, generation == initialGeneration else {
            throw YlOpenCancellationToken.cancellationError()
          }
        }
        demux.selectAudio(requestedStream)
        stateLock.withLock { audio.advanceGeneration() }
        emit(.tracksChanged(audio: audioTracks, video: videoTracks))
        emitState()
      }
      return
    }

    if switchesOpus || switchesVorbis {
      try seek(toUs: nil, selectingAudio: requestedStream, cancellationToken: cancellationToken)
      return
    }

    let nextAudioGeneration = stateLock.withLock { audio.nextGeneration() }
    let candidate = try audio.prepareTrack(stream: requestedStream,
      generation: nextAudioGeneration, cookies: demux.audioCookies)
    var candidateOwnedByBackend = false
    defer {
      if !candidateOwnedByBackend { candidate.dispose() }
    }

    let state = try onMainSync {
      try cancellationToken?.throwIfCancelled()
      let now = Self.hostTimeUs()
      let positionUs = presentation.position(atHostTimeUs: now)
      let value = try stateLock.withLock {
        guard !disposed, active, !reconfiguring, let media = demux.currentMedia else {
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
      presentation.pause(atHostTimeUs: now)
      return value
    }
    let media = state.media
    media.beginControlOperation(cancellationToken)
    var controlOperationEnded = false
    func endControlOperation() {
      guard !controlOperationEnded else { return }
      controlOperationEnded = true
      media.endControlOperation()
      demux.resume(media)
    }
    defer { endControlOperation() }
    demux.interrupt(media)
    demux.performSync {}
    demux.resume(media)
    try cancellationToken?.throwIfCancelled()
    do {
      try onMainSync {
        try cancellationToken?.throwIfCancelled()
        guard stateLock.withLock({
          active && generation == state.generation && demux.currentMedia === media
        }) else {
          throw YlOpenCancellationToken.cancellationError()
        }
        let previous = audio.install(candidate)
        candidateOwnedByBackend = true
        demux.selectAudio(requestedStream)
        audio.discardPendingPacket()
        audio.resetAnchor()
        stateLock.withLock {
          audio.adoptGeneration(nextAudioGeneration)
          reconfiguring = false
        }
        previous?.dispose()
        presentation.seek(to: state.positionUs)
        if state.wasPlaying {
          if bufferBudget.boundedPlan == nil || boundedStarted { try candidate.play() }
          if bufferBudget.boundedPlan == nil || boundedStarted { presentation.play(atHostTimeUs: Self.hostTimeUs()) }
        }
        emit(.tracksChanged(audio: audioTracks, video: videoTracks))
      }
      try cancellationToken?.throwIfCancelled()
      endControlOperation()
      try onMainSync {
        try cancellationToken?.throwIfCancelled()
        guard stateLock.withLock({
          active && generation == state.generation && demux.currentMedia === media
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
        diagnostic: YlAppleSafeDiagnostics.diagnostic(error)
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
      media: YlDemuxPipeline.Resource,
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
      presentation.seek(to: state.positionUs)
      if state.wasPlaying {
        if bufferBudget.boundedPlan == nil || boundedStarted { try? currentAudioRenderer?.play() }
        if bufferBudget.boundedPlan == nil || boundedStarted { presentation.play(atHostTimeUs: Self.hostTimeUs()) }
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
    if let bufferReleaseObserver { bufferBudget.bufferScope?.ledger.removeObserver(bufferReleaseObserver) }
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
