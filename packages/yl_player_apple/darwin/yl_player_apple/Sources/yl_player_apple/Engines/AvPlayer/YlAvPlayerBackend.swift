import AVFoundation
import CoreVideo
import QuartzCore

enum YlAvPlayerStatePolicy {
  static func status(
    wantsToPlay: Bool,
    itemReady: Bool,
    rate: Float,
    waiting: Bool
  ) -> String {
    guard itemReady else { return "opening" }
    guard wantsToPlay else { return "paused" }
    return rate > 0 && !waiting ? "playing" : "buffering"
  }
}

final class YlAvPlayerStallWatchdog {
  typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

  private enum Phase: String {
    case firstFrame
    case rebuffer
  }

  private let schedule: Scheduler
  private var generation: UInt64 = 0
  private var armedPhase: Phase?

  init(_ schedule: @escaping Scheduler = { delay, action in
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
  }) {
    self.schedule = schedule
  }

  func update(
    active: Bool,
    wantsToPlay: Bool,
    hasCurrentItem: Bool,
    isWaiting: Bool,
    firstFrameSent: Bool,
    timeoutMs: Int64,
    waitingReason: String?,
    onTimeout: @escaping (NativePlayerError) -> Void
  ) {
    guard active, wantsToPlay, hasCurrentItem else {
      cancel()
      return
    }

    let phase: Phase
    let code: String
    let message: String
    if !firstFrameSent {
      phase = .firstFrame
      code = "avplayer.first_frame_timeout"
      message = "AVPlayer did not render the first frame before the read timeout."
    } else if isWaiting {
      phase = .rebuffer
      code = "avplayer.stall_timeout"
      message = "AVPlayer remained stalled beyond the read timeout."
    } else {
      cancel()
      return
    }
    guard armedPhase != phase else { return }

    generation &+= 1
    let scheduledGeneration = generation
    armedPhase = phase

    let timeout = max(0, timeoutMs)
    let reason = waitingReason?.isEmpty == false ? waitingReason ?? "none" : "none"
    let error = NativePlayerError(
      category: "network",
      code: code,
      message: message,
      diagnostic: "AVPlayer(phase=\(phase.rawValue), timeoutMs=\(timeout), waitingReason=\(reason))"
    )
    schedule(TimeInterval(timeout) / 1_000) { [weak self] in
      guard let self, self.generation == scheduledGeneration else { return }
      self.armedPhase = nil
      onTimeout(error)
    }
  }

  func cancel() {
    generation &+= 1
    armedPhase = nil
  }
}

final class YlAvPlayerBackend: NSObject, YlPlaybackBackend {
  private struct StagedHls {
    let source: YlAppleSourceDescriptor
    let prepared: YlPreparedHlsAsset
    let resume: Bool
  }

  let playerId: Int64
  var textureId: Int64 { services.textureOutput.textureId }
  var isActive: Bool { active }

  private let services: YlPlatformServices
  private let configuration: PlayerConfiguration
  private final class CallbackBinding {
    let emit: (YlNativeBackendCallback) -> Void
    init(_ emit: @escaping (YlNativeBackendCallback) -> Void) { self.emit = emit }
  }
  private var callbackBinding: CallbackBinding
  private let player: AVPlayer
  private let errorLogCollector = YlAvPlayerErrorLogCollector()
  private let videoOutput = AVPlayerItemVideoOutput(
    pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
  )
  private var displayLink: (any YlDisplayDriving)?
  private var periodicObserver: Any?
  private var itemStatusObservation: NSKeyValueObservation?
  private var timeControlObservation: NSKeyValueObservation?
  private var endObserver: NSObjectProtocol?
  private var failedObserver: NSObjectProtocol?
  private var audioOptions: [String: AVMediaSelectionOption] = [:]
  private var audioTracks: [YlNativeTrack] = []
  private var videoTracks: [YlNativeTrack] = []
  private var sourceIsLive = false
  private var status = "idle"
  private var stopped = false
  private var resetting = false
  private var disposed = false
  private var firstFrameSent = false
  private var playRequested = false
  var playbackIntent: Bool { playRequested || player.rate > 0 }
  var requiresExternalRollbackActivation: Bool {
    guard services.compatibility.retainsReplacementHls == false, let source = lastSource else { return false }
    return YlSourceRouter.route(source) == .headeredHls
  }
  private var desiredRate: Float = 1
  private var openStartedAt: CFTimeInterval?
  private var openDurationMs: Int64?
  private var firstFrameDurationMs: Int64?
  private var rebufferCount = 0
  private var bufferingStartedAt: CFTimeInterval?
  private var rebufferDurationMs: Int64 = 0
  private var hasBeenReady = false
  private var currentError: NativePlayerError?
  private let failureGate = YlAvPlayerFailureGate()
  private let stallWatchdog = YlAvPlayerStallWatchdog()
  private var active = false
  private var lastSource: YlAppleSourceDescriptor?
  private var savedPositionMs: Int64 = 0
  private var itemGeneration: UInt64 = 0
  private var channelGeneration = YlBackendGeneration.next()
  private var qualityConstraint = YlAppleVideoConstraints.unconstrained
  private var selectedAudioTrackId: String?
  private var resumeAtLiveEdge = false
  private var hlsResourceLoader: YlHlsResourceLoader?
  private var stagedHls: StagedHls?
  // iOS retains actual source ownership only across the synchronous slot transaction.
  private var replacementHls: (asset: AVURLAsset, loader: YlHlsResourceLoader, shouldPlay: Bool)?
  private var liveReconnectController: YlLiveReconnectController
  private var pendingLiveReconnect: DispatchWorkItem?

  init(
    playerId: Int64,
    services: YlPlatformServices,
    configuration: PlayerConfiguration,
    player: AVPlayer = AVPlayer(),
    emit: @escaping (YlNativeBackendCallback) -> Void
  ) {
    self.playerId = playerId
    self.services = services
    self.player = player
    self.liveReconnectController = YlLiveReconnectController(configuration: configuration.network)
    self.configuration = configuration
    self.callbackBinding = CallbackBinding(emit)
    super.init()

    player.automaticallyWaitsToMinimizeStalling = configuration.bufferMode != "lowLatency"
    installCallbackObservers()
  }

  /// Rebind permanent observers with an immutable authority captured before delivery.
  /// Retired periodic/display/observation closures cannot relabel queued old work.
  func bindCallbacks(_ emit: @escaping (YlNativeBackendCallback) -> Void) {
    callbackBinding = CallbackBinding(emit)
    timeControlObservation?.invalidate()
    if let periodicObserver { player.removeTimeObserver(periodicObserver) }
    periodicObserver = nil
    displayLink?.invalidate()
    installCallbackObservers()
    displayLink?.isPaused = !active
  }

  private func installCallbackObservers() {
    let binding = callbackBinding
    timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) {
      [weak self] _, _ in
      guard let self, self.callbackBinding === binding else { return }
      let generation = self.itemGeneration
      DispatchQueue.main.async { [weak self] in
        guard let self, self.callbackBinding === binding, self.itemGeneration == generation, !self.stopped else { return }
        self.handleTimeControlChange()
      }
    }
    periodicObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(
        milliseconds: configuration.positionEventIntervalMs,
        preferredTimescale: 1_000
      ),
      queue: .main
    ) { [weak self] _ in
      guard let self, self.callbackBinding === binding else { return }
      self.emitStateDelta()
    }
    let link = services.makeDisplayDriver { [weak self] in
      guard let self, self.callbackBinding === binding else { return }
      self.displayLinkTick()
    }
    link.isPaused = true
    displayLink = link
  }

  private func checkAlive() throws {
    guard !disposed else {
      throw NativePlayerError(category: "resource", code: "\(YlApplePlatform.current.rawValue).player_disposed",
        message: "The Apple player has been disposed.")
    }
  }
  func play() throws {
    try checkAlive(); guard !stopped else { return }
    playRequested = true
    player.playImmediately(atRate: desiredRate)
    status = services.platform == .ios
      ? (player.timeControlStatus == .playing ? "playing" : "buffering")
      : YlAvPlayerStatePolicy.status(wantsToPlay: true,
        itemReady: player.currentItem?.status == .readyToPlay, rate: player.rate,
        waiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
    emitState()
    refreshStallWatchdog()
  }
  func pause() throws {
    try checkAlive(); guard !stopped else { return }
    playRequested = false
    stallWatchdog.cancel()
    player.pause()
  }
  func seek(toMs milliseconds: Int64, cancellationToken: YlOpenCancellationToken? = nil) throws {
    try checkAlive(); guard !stopped else { return }
    try cancellationToken?.throwIfCancelled()
    resumeAtLiveEdge = false
    if active {
      player.seek(to: CMTime(milliseconds: milliseconds, preferredTimescale: 1_000),
        toleranceBefore: .zero, toleranceAfter: .zero)
    } else { savedPositionMs = max(0, milliseconds); emitState() }
  }
  func setPlaybackSpeed(_ speed: Float) throws {
    try checkAlive()
    guard speed >= 0.25, speed <= 4 else {
      throw NativePlayerError(category: "source", code: "playback.speed_invalid",
        message: "Playback speed must be between 0.25 and 4.0.")
    }
    desiredRate = speed
    if player.rate != 0 { player.rate = speed }
  }
  func setVolume(_ volume: Float) throws { try checkAlive(); player.volume = min(max(volume, 0), 1) }

  func validateOpen(_ source: YlAppleSourceDescriptor) throws {
    let assessment = YlEngineRouter.assess(source)
    if let rejection = assessment.rejection { throw rejection }
    guard assessment.candidate == .avPlayer else {
      throw NativePlayerError(category: "container", code: "container.native_fallback_required",
        message: "This source requires a controlled preparation route.")
    }
  }

  func stagePreparedHls(
    source: YlAppleSourceDescriptor,
    prepared: YlPreparedHlsAsset,
    resume: Bool
  ) throws {
    guard !disposed else {
      throw NativePlayerError(
        category: "resource",
        code: "\(YlApplePlatform.current.rawValue).player_disposed",
        message: "The \(YlApplePlatform.current.displayName) player has been disposed."
      )
    }
    stagedHls?.prepared.discard()
    stagedHls = StagedHls(source: source, prepared: prepared, resume: resume)
  }

  func commitStagedHlsIfActive() throws {
    guard active else { return }
    try installStagedHls()
  }

  private func configureAudioSession() throws {
    guard configuration.managesAudioSession else { return }
    do {
      try services.activateAudioSession()
    } catch {
      throw NativePlayerError(
        category: "resource",
        code: "ios.audio_session_failed",
        message: "The playback audio session could not be activated.",
        diagnostic: String(describing: error)
      )
    }
  }

  func activate() throws {
    guard !disposed, !active, !stopped || stagedHls != nil else { return }
    var activated = false
    defer { if !activated { finishReplacement() } }
    if services.platform == .ios { try configureAudioSession() }
    active = true
    liveReconnectController = YlLiveReconnectController(
      configuration: configuration.network
    )
    if stagedHls != nil {
      try installStagedHls()
      activated = true
      return
    }
    if let retained = replacementHls {
      replacementHls = nil
      hlsResourceLoader = retained.loader
      playRequested = retained.shouldPlay
      installItem(asset: retained.asset, positionMs: savedPositionMs)
      if retained.shouldPlay { player.playImmediately(atRate: desiredRate) }
    } else if let source = lastSource {
      try installItem(source, positionMs: savedPositionMs)
    } else {
      activated = true
      emitState()
      return
    }
    activated = true
    status = "opening"
    emitState()
  }

  func stop() {
    clearMediaForStop()
    emitState()
  }

  // Used by the slot owner to clear an inactive AV source without a second event.
  func clearMediaForStop() {
    guard !disposed else { return }
    resetting = true
    stopped = true
    active = false
    playRequested = false
    cancelLiveReconnect()
    stallWatchdog.cancel()
    player.currentItem?.cancelPendingSeeks()
    player.currentItem?.asset.cancelLoading()
    removeCurrentItem()
    player.pause()
    stagedHls?.prepared.discard()
    stagedHls = nil
    lastSource = nil
    channelGeneration = YlBackendGeneration.next()
    savedPositionMs = 0
    resumeAtLiveEdge = false
    sourceIsLive = false
    selectedAudioTrackId = nil
    audioOptions.removeAll()
    audioTracks.removeAll()
    videoTracks.removeAll()
    firstFrameSent = false
    hasBeenReady = false
    openStartedAt = nil
    openDurationMs = nil
    firstFrameDurationMs = nil
    bufferingStartedAt = nil
    rebufferCount = 0
    rebufferDurationMs = 0
    currentError = nil
    status = "idle"
    resetting = false
  }

  func quiesceForReplacement() {
    deactivate(retainingHlsForReplacement: services.compatibility.retainsReplacementHls)
  }

  func finishReplacement() {
    guard let retained = replacementHls else { return }
    replacementHls = nil
    retained.asset.cancelLoading()
    retained.loader.cancelAll()
  }

  func deactivate() {
    deactivate(retainingHlsForReplacement: false)
  }

  private func deactivate(retainingHlsForReplacement: Bool) {
    if !retainingHlsForReplacement { finishReplacement() }
    guard !disposed, active else { return }
    if retainingHlsForReplacement,
       let loader = hlsResourceLoader, let asset = player.currentItem?.asset as? AVURLAsset {
      replacementHls = (asset, loader, playRequested || player.rate > 0)
      hlsResourceLoader = nil
    }
    cancelLiveReconnect()
    savedPositionMs = milliseconds(player.currentTime()) ?? savedPositionMs
    if let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue,
       let position = milliseconds(player.currentTime()),
       let end = milliseconds(CMTimeRangeGetEnd(range)),
       end - position <= 2_000 {
      resumeAtLiveEdge = true
    }
    finishBuffering()
    active = false
    playRequested = false
    player.pause()
    removeCurrentItem(releaseReplacement: !retainingHlsForReplacement)
    if status != "error" && status != "completed" && status != "idle" {
      status = "paused"
    }
    emitState()
  }

  func reportRestorationFailure(_ error: NativePlayerError) {
    guard !disposed else { return }
    stallWatchdog.cancel()
    if active { deactivate() }
    active = false
    playRequested = false
    status = "error"
    let details = NativePlayerError(
      category: error.category,
      code: error.code,
      message: error.message,
      diagnostic: error.diagnostic
    )
    currentError = details
    emit(.failure(details))
    emitState(error: details)
  }

  func open(_ source: YlAppleSourceDescriptor) throws {
    try checkAlive()
    try validateOpen(source)
    if stopped && services.platform == .ios { try configureAudioSession() }
    channelGeneration = YlBackendGeneration.next()
    resetOpenState(source, resume: false)
    try installItem(source, positionMs: source.loadOptions?.startPositionMs ?? 0)
    emitState()
  }

  private func resetOpenState(_ source: YlAppleSourceDescriptor, resume: Bool) {
    stopped = false
    cancelLiveReconnect()
    liveReconnectController = YlLiveReconnectController(configuration: configuration.network)
    removeCurrentItem()
    lastSource = source
    let loadOptions = source.loadOptions
    if !resume, source.loadOptions != nil {
      qualityConstraint = loadOptions?.videoConstraints ?? .unconstrained
    }
    if !resume {
      savedPositionMs = 0
      resumeAtLiveEdge = false
      selectedAudioTrackId = nil
    }
    active = true
    sourceIsLive = source.isLive
    status = "opening"
    playRequested = !resume && (loadOptions?.autoplay ?? false)
    firstFrameSent = false
    hasBeenReady = false
    openStartedAt = CACurrentMediaTime()
    openDurationMs = nil
    firstFrameDurationMs = nil
    rebufferCount = 0
    rebufferDurationMs = 0
    bufferingStartedAt = nil
    currentError = nil
  }

  private func installStagedHls() throws {
    guard let stagedHls else {
      throw NativePlayerError(
        category: "internal",
        code: "internal.fallback_invariant",
        message: "No prepared HLS asset is staged."
      )
    }
    self.stagedHls = nil
    if !stagedHls.resume {
      channelGeneration = YlBackendGeneration.next()
    }
    let positionMs = stagedHls.resume ? savedPositionMs : (stagedHls.source.loadOptions?.startPositionMs ?? 0)
    resetOpenState(stagedHls.source, resume: stagedHls.resume)
    let loader = try stagedHls.prepared.takeLoader()
    hlsResourceLoader = loader
    installItem(asset: stagedHls.prepared.asset, positionMs: positionMs)
    emitState()
  }

  private func installItem(_ source: YlAppleSourceDescriptor, positionMs: Int64) throws {
    guard let url = source.url else {
      throw NativePlayerError(
        category: "source",
        code: "source.invalid_uri",
        message: "A valid media URI is required."
      )
    }
    installItem(asset: AVURLAsset(url: url), positionMs: positionMs)
  }

  private func installItem(asset: AVURLAsset, positionMs: Int64) {
    itemGeneration &+= 1
    let generation = itemGeneration
    let item = AVPlayerItem(asset: asset)
    let effectiveConfiguration = configuration.forLoad(lastSource)
    item.preferredForwardBufferDuration = effectiveConfiguration.preferredForwardBufferDuration
    player.automaticallyWaitsToMinimizeStalling = effectiveConfiguration.bufferMode != "lowLatency"
    applyQualityConstraint(qualityConstraint, to: item)
    item.add(videoOutput)
    player.replaceCurrentItem(with: item)
    displayLink?.isPaused = false
    observe(item, generation: generation)
    if positionMs > 0 && !resumeAtLiveEdge {
      player.seek(
        to: CMTime(milliseconds: positionMs, preferredTimescale: 1_000),
        toleranceBefore: .zero,
        toleranceAfter: .zero
      )
    }
  }

  private func observe(_ item: AVPlayerItem, generation: UInt64) {
    itemStatusObservation = item.observe(\.status, options: [.initial, .new]) {
      [weak self] item, _ in
      DispatchQueue.main.async { self?.handleItemStatus(item, generation: generation) }
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      guard self?.isCurrent(item, generation: generation) == true else { return }
      self?.stallWatchdog.cancel()
      self?.status = "completed"
      self?.emitState()
    }
    failedObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] notification in
      guard self?.isCurrent(item, generation: generation) == true else { return }
      let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
      self?.handleFailure(error, item: item, generation: generation)
    }
  }

  private func handleItemStatus(_ item: AVPlayerItem, generation: UInt64) {
    guard isCurrent(item, generation: generation) else { return }
    switch item.status {
    case .readyToPlay:
      if !hasBeenReady {
        hasBeenReady = true
        openDurationMs = elapsedMilliseconds(since: openStartedAt)
      }
      if playRequested && player.rate == 0 {
        player.playImmediately(atRate: desiredRate)
      }
      switch player.timeControlStatus {
      case .playing:
        status = "playing"
      case .waitingToPlayAtSpecifiedRate:
        status = "buffering"
      case .paused:
        status = playRequested ? "buffering" : "ready"
      @unknown default:
        status = playRequested ? "buffering" : "ready"
      }
      if resumeAtLiveEdge {
        try? seekToLiveEdge()
      }
      rebuildTracks(item)
      emitState()
      refreshStallWatchdog()
    case .failed:
      handleFailure(item.error, item: item, generation: generation)
    default:
      break
    }
  }

  private func handleTimeControlChange() {
    guard player.currentItem != nil else { return }
    switch player.timeControlStatus {
    case .waitingToPlayAtSpecifiedRate:
      if hasBeenReady && bufferingStartedAt == nil {
        rebufferCount += 1
        bufferingStartedAt = CACurrentMediaTime()
      }
      status = "buffering"
    case .playing:
      finishBuffering()
      status = "playing"
    case .paused:
      finishBuffering()
      if status != "opening" && status != "completed" && status != "error" {
        status = playRequested ? "buffering" : (hasBeenReady ? "paused" : status)
      }
    @unknown default:
      break
    }
    emitState()
    refreshStallWatchdog()
  }

  private func finishBuffering() {
    if let started = bufferingStartedAt {
      rebufferDurationMs += Int64((CACurrentMediaTime() - started) * 1_000)
      bufferingStartedAt = nil
    }
  }

  private func handleFailure(
    _ error: Error?,
    item: AVPlayerItem? = nil,
    generation: UInt64? = nil
  ) {
    let failureGeneration = generation ?? itemGeneration
    guard failureGate.begin(generation: failureGeneration) else { return }
    stallWatchdog.cancel()
    if !services.compatibility.reconnectsAvPlayer {
      finishFailure(error as NSError?, log: nil, generation: failureGeneration)
      return
    }
    let nsError = error as NSError?
    if let source = lastSource,
       YlAvPlayerRecoveryPolicy.shouldReconnect(
         source: source,
         usesResourceLoader: hlsResourceLoader != nil,
         hasBeenReady: hasBeenReady,
         playRequested: playRequested,
         error: nsError,
         errorLogDomain: nil,
         errorLogStatusCode: nil
       ), liveReconnectController.canRetry {
      finishFailure(nsError, log: nil, generation: failureGeneration)
      return
    }
    guard let item else {
      finishFailure(nsError, log: nil, generation: failureGeneration)
      return
    }

    errorLogCollector.collect(timeoutMs: 500, read: { [item] in
      let event = item.errorLog()?.events.last
      return YlAvPlayerErrorLogSnapshot(
        domain: event?.errorDomain,
        statusCode: event?.errorStatusCode,
        uri: event?.uri
      )
    }) { [weak self] snapshot in
      self?.finishFailure(nsError, log: snapshot, generation: failureGeneration)
    }
  }

  private func finishFailure(
    _ error: NSError?,
    log: YlAvPlayerErrorLogSnapshot?,
    generation: UInt64
  ) {
    guard failureGate.finish(
      generation: generation,
      currentGeneration: itemGeneration
    ), !disposed, active else {
      return
    }
    if services.compatibility.reconnectsAvPlayer, let source = lastSource,
       YlAvPlayerRecoveryPolicy.shouldReconnect(
         source: source,
         usesResourceLoader: hlsResourceLoader != nil,
         hasBeenReady: hasBeenReady,
         playRequested: playRequested,
         error: error,
         errorLogDomain: log?.domain,
         errorLogStatusCode: log?.statusCode
       ), scheduleLiveReconnect(source: source) {
      return
    }

    failureGate.markTerminal(generation: generation)
    status = "error"
    let category = errorCategory(error)
    let diagnostic = YlAvPlayerRecoveryPolicy.diagnostic(
      error: error,
      errorDomain: log?.domain,
      statusCode: log?.statusCode,
      uri: log?.uri
    )
    let details = NativePlayerError(
      category: category,
      code: error.map { "avplayer.\($0.code)" } ?? "avplayer.failed",
      message: "AVPlayer playback failed.",
      diagnostic: diagnostic
    )
    currentError = details
    emit(.failure(details))
    emitState(error: details)
  }

  @objc private func displayLinkTick() {
    guard !disposed, textureId >= 0, player.currentItem != nil else { return }
    let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
    guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime) else { return }
    if services.compatibility.reconnectsAvPlayer { liveReconnectController.markFirstFrame() }
    services.textureOutput.publish(copyPixelBuffer()?.takeRetainedValue())
    if !firstFrameSent {
      firstFrameSent = true
      firstFrameDurationMs = elapsedMilliseconds(since: openStartedAt)
      let size = player.currentItem?.presentationSize ?? .zero
      emit(.firstFrame(width: size.width > 0 ? Int(size.width) : nil, height: size.height > 0 ? Int(size.height) : nil))
      emitState()
      refreshStallWatchdog()
    }
  }

  private func refreshStallWatchdog() {
    let generation = itemGeneration
    stallWatchdog.update(
      active: active,
      wantsToPlay: playRequested,
      hasCurrentItem: player.currentItem != nil,
      isWaiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
      firstFrameSent: firstFrameSent,
      timeoutMs: configuration.network.readTimeoutMs,
      waitingReason: player.reasonForWaitingToPlay?.rawValue
    ) { [weak self] error in
      self?.handleStallTimeout(error, generation: generation)
    }
  }

  private func handleStallTimeout(
    _ error: NativePlayerError,
    generation: UInt64
  ) {
    guard failureGate.begin(generation: generation),
          failureGate.finish(
            generation: generation,
            currentGeneration: itemGeneration
          ), !disposed, active else {
      return
    }
    failureGate.markTerminal(generation: generation)
    stallWatchdog.cancel()
    playRequested = false
    player.pause()
    status = "error"
    let details = NativePlayerError(
      category: error.category,
      code: error.code,
      message: error.message,
      diagnostic: error.diagnostic
    )
    currentError = details
    emit(.failure(details))
    emitState(error: details)
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
    guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
          let buffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
    else {
      return nil
    }
    return Unmanaged.passRetained(buffer)
  }

  func seekToLiveEdge() throws {
    try checkAlive(); guard !stopped else { return }
    guard sourceIsLive || isIndefinite(player.currentItem?.duration) else {
      throw NativePlayerError(
        category: "source",
        code: "source.not_live",
        message: "The current source is not live."
      )
    }
    if !active {
      resumeAtLiveEdge = true
      emitState()
      return
    }
    guard let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else {
      resumeAtLiveEdge = true
      player.seek(to: .positiveInfinity)
      return
    }
    player.seek(to: CMTimeRangeGetEnd(range), toleranceBefore: .zero, toleranceAfter: .zero)
    resumeAtLiveEdge = false
  }

  func selectAudioTrack(_ trackId: String, cancellationToken: YlOpenCancellationToken? = nil) throws {
    try checkAlive(); guard !stopped else { return }
    try cancellationToken?.throwIfCancelled()
    guard let option = audioOptions[trackId] else {
      throw NativePlayerError(
        category: "source",
        code: "track.not_found",
        message: "The requested audio track is unavailable."
      )
    }
    selectedAudioTrackId = trackId
    guard let item = player.currentItem,
          let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible)
    else {
      emitState()
      return
    }
    item.select(option, in: group)
    rebuildTracks(item)
    emitState()
  }

  func setVideoConstraints(_ constraint: YlAppleVideoConstraints) throws {
    try checkAlive()
    _ = try YlFallbackQualityConstraint(validating: constraint)
    qualityConstraint = constraint
    guard let item = player.currentItem else { return }
    applyQualityConstraint(constraint, to: item)
  }

  private func applyQualityConstraint(_ constraint: YlAppleVideoConstraints, to item: AVPlayerItem) {
    item.preferredPeakBitRate = constraint.maxBitrate.map(Double.init) ?? 0
    let width = constraint.maxWidth.map(Double.init)
    let height = constraint.maxHeight.map(Double.init)
    guard width != nil || height != nil else {
      item.preferredMaximumResolution = .zero
      return
    }
    let resolvedWidth = CGFloat(width ?? 100_000)
    let resolvedHeight = CGFloat(height ?? 100_000)
    item.preferredMaximumResolution = CGSize(width: resolvedWidth, height: resolvedHeight)
  }

  private func rebuildTracks(_ item: AVPlayerItem) {
    audioOptions.removeAll()
    if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
      group.options.enumerated().forEach { index, option in
        let id = "audio-\(index)"
        audioOptions[id] = option
      }
      if let selectedAudioTrackId, let option = audioOptions[selectedAudioTrackId] {
        item.select(option, in: group)
      }
      audioTracks = group.options.enumerated().map { index, option in
        let id = "audio-\(index)"
        return YlNativeTrack(id: id, kind: .audio,
          label: option.displayName, language: option.locale?.identifier,
          isSelected: item.currentMediaSelection.selectedMediaOption(in: group) == option)
      }
    } else {
      audioTracks = []
    }

    videoTracks = item.asset.tracks(withMediaType: .video).enumerated().map { index, track in
      let size = track.naturalSize.applying(track.preferredTransform)
      return YlNativeTrack(id: "video-\(index)", kind: .video,
        bitrate: Int(track.estimatedDataRate), width: Int(abs(size.width)),
        height: Int(abs(size.height)), isSelected: true)
    }
    emit(.tracksChanged(audio: audioTracks, video: videoTracks))
  }

  private func emit(_ event: YlNativeBackendEvent) {
    callbackBinding.emit(YlNativeBackendCallback(generation: channelGeneration, loadRequestId: lastSource?.loadRequestId, event: event))
  }

  func emitState() {
    emitState(error: nil)
  }

  private func emitState(error: NativePlayerError?) {
    guard !disposed, !resetting else { return }
    let item = player.currentItem
    let positionMs = active ? (milliseconds(player.currentTime()) ?? savedPositionMs) : savedPositionMs
    let durationMs = milliseconds(item?.duration)
    let loadedEndMs = item?.loadedTimeRanges.last
      .map { milliseconds(CMTimeRangeGetEnd($0.timeRangeValue)) ?? 0 } ?? 0
    let seekableRange = item?.seekableTimeRanges.last?.timeRangeValue
    let dvrStartMs = seekableRange.flatMap { milliseconds($0.start) }
    let dvrEndMs = seekableRange.flatMap { milliseconds(CMTimeRangeGetEnd($0)) }
    let live = sourceIsLive || isIndefinite(item?.duration)
    let liveOffsetMs = live ? dvrEndMs.map { max(0, $0 - positionMs) } : nil
    let size = item?.presentationSize ?? .zero
    emit(.state(YlNativeState(
      status: status, positionMs: positionMs, durationMs: durationMs,
      bufferedPositionMs: loadedEndMs, isLive: live,
      isSeekable: seekableRange != nil,
      isAtLiveEdge: liveOffsetMs.map { $0 <= 2_000 } ?? false,
      liveOffsetMs: liveOffsetMs, dvrStartMs: dvrStartMs, dvrEndMs: dvrEndMs,
      videoWidth: size.width > 0 ? Int(size.width) : nil,
      videoHeight: size.height > 0 ? Int(size.height) : nil,
      engine: .avPlayer, isHardwareDecoding: false, decoderName: nil,
      audioTracks: audioTracks, videoTracks: videoTracks,
      metrics: YlNativeMetrics(openDurationMs: openDurationMs,
        firstFrameDurationMs: firstFrameDurationMs, rebufferCount: rebufferCount,
        rebufferDurationMs: rebufferDurationMs,
        bufferedDurationMs: max(0, loadedEndMs - positionMs), liveOffsetMs: liveOffsetMs),
      error: error ?? currentError)))
  }

  private func emitStateDelta() {
    guard !disposed, !stopped, !resetting else { return }
    let item = player.currentItem
    let positionMs = active ? (milliseconds(player.currentTime()) ?? savedPositionMs) : savedPositionMs
    let loadedEndMs = item?.loadedTimeRanges.last
      .map { milliseconds(CMTimeRangeGetEnd($0.timeRangeValue)) ?? 0 } ?? 0
    let seekableRange = item?.seekableTimeRanges.last?.timeRangeValue
    let live = sourceIsLive || isIndefinite(item?.duration)
    let dvrEndMs = seekableRange.flatMap { milliseconds(CMTimeRangeGetEnd($0)) }
    let liveOffsetMs = live ? dvrEndMs.map { max(0, $0 - positionMs) } : nil
    emit(.delta(YlNativeTimelineDelta(positionMs: positionMs,
      bufferedPositionMs: loadedEndMs,
      isAtLiveEdge: liveOffsetMs.map { $0 <= 2_000 } ?? false,
      liveOffsetMs: liveOffsetMs,
      metrics: YlNativeMetrics(openDurationMs: openDurationMs,
        firstFrameDurationMs: firstFrameDurationMs, rebufferCount: rebufferCount,
        rebufferDurationMs: rebufferDurationMs,
        bufferedDurationMs: max(0, loadedEndMs - positionMs), liveOffsetMs: liveOffsetMs))))
  }

  func dispose() {
    guard !disposed else { return }
    disposed = true
    cancelLiveReconnect()
    displayLink?.invalidate()
    displayLink = nil
    removeItemObservers()
    timeControlObservation?.invalidate()
    timeControlObservation = nil
    if let observer = periodicObserver {
      player.removeTimeObserver(observer)
      periodicObserver = nil
    }
    player.pause()
    removeCurrentItem(clearOutput: active)
    active = false
    stagedHls?.prepared.discard()
    stagedHls = nil
    lastSource = nil
    // The host owns the shared texture registration across backend replacement.
  }

  private func removeItemObservers() {
    itemStatusObservation?.invalidate()
    itemStatusObservation = nil
    if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
    if let observer = failedObserver { NotificationCenter.default.removeObserver(observer) }
    endObserver = nil
    failedObserver = nil
  }

  private func removeCurrentItem(releaseReplacement: Bool = true, clearOutput: Bool = true) {
    if releaseReplacement { finishReplacement() }
    itemGeneration &+= 1
    stallWatchdog.cancel()
    failureGate.reset()
    removeItemObservers()
    displayLink?.isPaused = true
    player.currentItem?.remove(videoOutput)
    player.replaceCurrentItem(with: nil)
    if clearOutput { services.textureOutput.clear() }
    hlsResourceLoader?.cancelAll()
    hlsResourceLoader = nil
  }

  private func scheduleLiveReconnect(source: YlAppleSourceDescriptor) -> Bool {
    guard active,
          let delayMs = liveReconnectController.nextDelayMs() else {
      return false
    }

    status = "buffering"
    currentError = nil
    removeCurrentItem()
    let expectedGeneration = itemGeneration
    let reconnect = DispatchWorkItem { [weak self] in
      guard let self, !self.disposed, self.active,
            self.itemGeneration == expectedGeneration,
            self.liveReconnectController.shouldInstall(
              reconnectGeneration: expectedGeneration,
              currentGeneration: self.itemGeneration
            ) else {
        return
      }
      self.pendingLiveReconnect = nil
      do {
        try self.installItem(source, positionMs: 0)
        if self.playRequested {
          self.player.playImmediately(atRate: self.desiredRate)
        }
        self.emitState()
        self.refreshStallWatchdog()
      } catch {
        self.handleFailure(error)
      }
    }
    pendingLiveReconnect = reconnect
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(Int(delayMs)),
      execute: reconnect
    )
    emitState()
    return true
  }

  private func cancelLiveReconnect() {
    pendingLiveReconnect?.cancel()
    pendingLiveReconnect = nil
    liveReconnectController.cancel()
    failureGate.reset()
  }

  private func isCurrent(_ item: AVPlayerItem, generation: UInt64) -> Bool {
    !disposed && active && generation == itemGeneration && item === player.currentItem
  }
}









private func errorCategory(_ error: NSError?) -> String {
  guard let error else { return "source" }
  if error.domain == NSURLErrorDomain {
    return "network"
  }
  if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
     underlying.domain == NSURLErrorDomain {
    return "network"
  }
  guard error.domain == AVFoundationErrorDomain else { return "source" }
  switch AVError.Code(rawValue: error.code) {
  case .decoderNotFound, .decoderTemporarilyUnavailable:
    return "decoderUnsupported"
  case .decodeFailed:
    return "decoderFailure"
  case .fileFormatNotRecognized, .invalidSourceMedia, .operationNotSupportedForAsset:
    return "container"
  default:
    return "source"
  }
}





func float(_ value: Any?) -> Float? {
  if let value = value as? NSNumber { return value.floatValue }
  return value as? Float
}

private func double(_ value: Any?) -> Double? {
  if let value = value as? NSNumber { return value.doubleValue }
  return value as? Double
}

private func milliseconds(_ time: CMTime?) -> Int64? {
  guard let time, time.isNumeric, !time.isIndefinite else { return nil }
  let seconds = CMTimeGetSeconds(time)
  guard seconds.isFinite && seconds >= 0 else { return nil }
  return Int64(seconds * 1_000)
}

private func isIndefinite(_ time: CMTime?) -> Bool {
  guard let time else { return false }
  return time.isIndefinite || !time.isNumeric
}

private func elapsedMilliseconds(since start: CFTimeInterval?) -> Int64? {
  start.map { Int64((CACurrentMediaTime() - $0) * 1_000) }
}

private extension CMTime {
  init(milliseconds: Int64, preferredTimescale: CMTimeScale) {
    self.init(
      value: CMTimeValue(milliseconds) * CMTimeValue(preferredTimescale) / 1_000,
      timescale: preferredTimescale
    )
  }
}
