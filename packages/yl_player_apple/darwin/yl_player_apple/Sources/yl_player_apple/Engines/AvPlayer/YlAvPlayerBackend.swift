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
    timeControlStatus: AVPlayer.TimeControlStatus,
    playbackStatus: String,
    firstFrameSent: Bool,
    timeoutMs: Int64,
    waitingReason: String?,
    onTimeout: @escaping (NativePlayerError) -> Void
  ) {
    guard active, wantsToPlay, hasCurrentItem,
          playbackStatus != "completed", playbackStatus != "error" else {
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
    } else if timeControlStatus != .playing {
      // AVPlayer can pause internally while playback is still requested.
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
  #if DEBUG && YL_BOUND_AV
  private var boundAudio: YlBoundAvPlayerAudio?
  #endif
  private let player: AVPlayer
  var onAirPlayChanged: (() -> Void)?
  private var airPlayObservation: NSKeyValueObservation?
  var airPlayEnabled: Bool { !disposed && !stopped && lastSource?.airPlay == true }
  var airPlayActive: Bool { airPlayEnabled && active && player.isExternalPlaybackActive }
  var airPlayPlayer: AVPlayer { player }
  private final class FramePolicy {
    let output: AVPlayerItemVideoOutput
    let generation: UInt64
    let constraints: YlAppleVideoConstraints
    var rotation: Int
    var blocked = false
    var awaitingResumeSeek = false
    var measuredGeometry: YlVideoGeometry? = nil
    var fixedTrack: YlNativeTrack?
    var catalog: YlDashVideoCatalog?
    init(output: AVPlayerItemVideoOutput, generation: UInt64,
      constraints: YlAppleVideoConstraints, rotation: Int) {
      self.output = output; self.generation = generation
      self.constraints = constraints; self.rotation = rotation
    }
  }
  private let framePolicyLock = NSLock()
  private var framePolicy: FramePolicy?
  private let makePlayerItem: (AVURLAsset) -> AVPlayerItem
  private let makeVideoOutput: ([String: Any]) -> AVPlayerItemVideoOutput
  private let errorLogCollector = YlAvPlayerErrorLogCollector()
  private var videoOutput = AVPlayerItemVideoOutput(
    pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
  )
  private var videoOutputConfigured = true
  private var displayLink: (any YlDisplayDriving)?
  private var periodicObserver: Any?
  private var itemStatusObservation: NSKeyValueObservation?
  private var timeControlObservation: NSKeyValueObservation?
  private var endObserver: NSObjectProtocol?
  private var failedObserver: NSObjectProtocol?
  private var audioOptions: [String: AVMediaSelectionOption] = [:]
  private var audioIdentityRegistry = YlAudioSelectionIdentityRegistry()
  private var dashAudioCatalog: [YlNativeTrack]?
  private var audioTracks: [YlNativeTrack] = []
  private var videoTracks: [YlNativeTrack] = []
  private var dashVideoCatalog: YlDashVideoCatalog?
  private(set) var videoSelection = YlNativeVideoSelection()
  private var automaticDashCandidate: YlPreparedHlsAsset?
  private var confirmedDashPositionUs: Int64 = 0
  private var unconfirmedFixedLanding = false
  private var fixedRecoveryDeadline: DispatchWorkItem?
  var onAutomaticFallback: (() -> Void)?
  var confirmedVideoTracks: [YlNativeTrack] {
    dashVideoCatalog?.tracks(at: confirmedPositionUs()) ?? []
  }
  private func confirmedPositionUs() -> Int64 {
    if pendingRuntimeResume != nil || (videoSelection.fixedTrackId != nil && (pendingUserSeek != nil || unconfirmedFixedLanding)) {
      return confirmedDashPositionUs
    }
    return active ? (microseconds(player.currentTime()) ?? confirmedDashPositionUs) : confirmedDashPositionUs
  }
  func acceptVideoSelection(_ selection: YlNativeVideoSelection) {
    videoSelection = selection
    emitState()
  }
  private var videoGeometry: YlVideoGeometry?
  private var audioGroup: AVMediaSelectionGroup?
  private var metadataTask: Task<Void, Never>?
  private var automaticLiveCatchUpAllowed = true
  private var lastLiveCatchUpSeek: TimeInterval?
  private var liveCatchUpRate = false
  private var liveMode: YlNativeLiveMode?
  private var liveModeRequestId: Int64?
  private var effectiveConfiguration: PlayerConfiguration {
    var result = configuration.forLoad(lastSource)
    if let liveMode { result = result.forLiveMode(liveMode) }
    return result
  }
  private func livePlaybackState(_ live: Bool) -> YlNativeLivePlayback? {
    guard live, let source = lastSource, source.intent != .onDemand,
          source.loadOptions?.bufferStrategy != .bounded,
          source.drm == nil, let url = source.url,
          YlEngineRouter.resolvedFormat(source, url: url) == .hls, dashVideoCatalog == nil else { return nil }
    if liveMode == nil {
      liveMode = source.loadOptions?.bufferStrategy == .lowLatency ? .lowLatency : .smoothPlayback
      applyLiveBufferPolicy()
    }
    return YlNativeLivePlayback(mode: liveMode!, switchableModes: [.smoothPlayback, .lowLatency],
      committedRequestId: liveModeRequestId)
  }
  private func applyLiveBufferPolicy() {
    let policy = effectiveConfiguration
    player.currentItem?.preferredForwardBufferDuration = policy.preferredForwardBufferDuration
    player.automaticallyWaitsToMinimizeStalling = policy.bufferMode != "lowLatency"
    if liveCatchUpRate, player.rate != 0 { player.rate = desiredRate }
    liveCatchUpRate = false
  }
  func setLivePlaybackMode(_ mode: YlNativeLiveMode, requestId: Int64) throws -> YlNativeLivePlayback {
    try checkAlive()
    guard isActive, !stopped, currentError == nil,
          livePlaybackState(sourceIsLive || isIndefinite(player.currentItem?.duration)) != nil else {
      throw YlNativeLivePlayback.unsupported
    }
    liveMode = mode
    lastSource?.loadOptions?.bufferStrategy = mode == .lowLatency ? .lowLatency : .smoothPlayback
    lastSource?.livePlaybackRequestId = requestId
    liveModeRequestId = requestId
    applyLiveBufferPolicy()
    return YlNativeLivePlayback(mode: mode, switchableModes: [.smoothPlayback, .lowLatency], committedRequestId: requestId)
  }
  private var sourceIsLive = false
  private var status = "idle"
  private var stopped = false
  private var resetting = false
  private var disposed = false
  private var firstFrameSent = false
  private var playRequested = false
  // AVPlayer rate observations may arrive after pause/item retirement. Native
  // output cannot recreate playback intent once this backend is inactive.
  var playbackIntent: Bool { playRequested || (active && player.rate > 0) }
  var requiresExternalRollbackActivation: Bool {
    guard services.compatibility.retainsReplacementHls == false || videoSelection.fixedTrackId != nil,
          let source = lastSource else { return false }
    return [YlAppleSourceRoute.headeredHls, .dashHls].contains(YlSourceRouter.route(source))
  }
  private var desiredRate: Float = 1
  private var openStartedAt: CFTimeInterval?
  private var openDurationMs: Int64?
  private var firstFrameDurationMs: Int64?
  private var metricsCollector = YlMetricsCollector()
  private var awaitingReconnectFrame: UInt64?
  private var hasBeenReady = false
  private var currentError: NativePlayerError?
  private let failureGate = YlAvPlayerFailureGate()
  private let stallWatchdog = YlAvPlayerStallWatchdog()
  private let videoProgressProbe = YlAvPlayerVideoProgressProbe()
  private var active = false
  private var lastSource: YlAppleSourceDescriptor?
  private var savedPositionMs: Int64 = 0
  private var savedPositionUs: Int64 = 0
  private var pendingRuntimeResume: (id: UUID, positionUs: Int64)?
  // Only replacement consumes this intent; ordinary publication uses the clock.
  private var pendingUserSeek: (id: UUID, generation: UInt64, positionUs: Int64)?
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
    makePlayerItem: @escaping (AVURLAsset) -> AVPlayerItem = { AVPlayerItem(asset: $0) },
    makeVideoOutput: @escaping ([String: Any]) -> AVPlayerItemVideoOutput = { AVPlayerItemVideoOutput(pixelBufferAttributes: $0) },
    emit: @escaping (YlNativeBackendCallback) -> Void
  ) {
    self.playerId = playerId
    self.services = services
    self.player = player
    self.makePlayerItem = makePlayerItem
    self.makeVideoOutput = makeVideoOutput
    self.liveReconnectController = YlLiveReconnectController(configuration: configuration.network)
    self.configuration = configuration
    self.callbackBinding = CallbackBinding(emit)
    super.init()

    player.allowsExternalPlayback = false
    airPlayObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async {
        guard let self, !self.disposed else { return }
        self.videoProgressProbe.reset()
        self.refreshStallWatchdog()
        self.onAirPlayChanged?()
      }
    }
    player.automaticallyWaitsToMinimizeStalling = configuration.bufferMode != "lowLatency"
    installCallbackObservers()
  }

  /// Rebind permanent observers with an immutable authority captured before delivery.
  /// Retired periodic/display/observation closures cannot relabel queued old work.
  func bindCallbacks(_ emit: @escaping (YlNativeBackendCallback) -> Void) {
    videoProgressProbe.reset()
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
  var beforeAudioOutput: () throws -> Void = {}

  private func startOutput() throws {
    try beforeAudioOutput()
    if effectiveConfiguration.bufferMode == "stable", hlsResourceLoader == nil {
      // Respect AVPlayer's buffering decision for smooth playback. Immediate
      // playback bypasses that decision even when automatic waiting is enabled.
      player.rate = desiredRate
    } else {
      player.playImmediately(atRate: desiredRate)
    }
  }

  func play() throws {
    try checkAlive(); guard !stopped else { return }
    try startOutput()
    playRequested = true
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
    videoProgressProbe.reset()
    stallWatchdog.cancel()
    player.pause()
  }
  func seek(toMs milliseconds: Int64, cancellationToken: YlOpenCancellationToken? = nil) throws {
    try checkAlive(); guard !stopped else { return }
    try cancellationToken?.throwIfCancelled()
    automaticLiveCatchUpAllowed = YlLiveCatchUpPolicy.endAutomaticCatchUp(
      requestedRate: desiredRate, playing: active && playRequested && player.rate != 0) { player.rate = $0 }
    liveCatchUpRate = false
    videoProgressProbe.reset()
    resumeAtLiveEdge = false
    if active {
      let generation = itemGeneration
      let binding = callbackBinding
      fixedRecoveryDeadline?.cancel(); fixedRecoveryDeadline = nil
      let seekId = UUID()
      let targetUs = Self.microsecondsFromMilliseconds(milliseconds)
      if videoSelection.fixedTrackId != nil { confirmedDashPositionUs = confirmedPositionUs() }
      pendingUserSeek = (seekId, generation, targetUs)
      unconfirmedFixedLanding = videoSelection.fixedTrackId != nil
      refreshFramePolicy()
      let resumeId = pendingRuntimeResume.map { _ in seekId }
      if let resumeId { pendingRuntimeResume = (resumeId, targetUs) }
      #if DEBUG && YL_BOUND_AV
      boundAudio?.install(targetUs: targetUs)
      #endif
      player.seek(to: CMTime(milliseconds: milliseconds, preferredTimescale: 1_000),
        toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
          DispatchQueue.main.async {
            guard let self, self.itemGeneration == generation, self.callbackBinding === binding,
                  self.active, !self.stopped, self.pendingUserSeek?.id == seekId else { return }
            self.pendingUserSeek = nil
            if finished {
              self.unconfirmedFixedLanding = false
              self.confirmedDashPositionUs = microseconds(self.player.currentTime()) ?? self.confirmedDashPositionUs
              // Completion belongs to the old end position. AVPlayer remains
              // paused after a paused seek and may emit no time-control change,
              // so publish the successful interior landing explicitly. Preserve
              // EOF for a seek to the end and never restart paused output.
              if self.status == "completed", !self.playRequested,
                 let landed = microseconds(self.player.currentTime()),
                 let duration = microseconds(self.player.currentItem?.duration),
                 landed < duration {
                self.status = "paused"
              }
            } else if self.videoSelection.fixedTrackId != nil { self.unconfirmedFixedLanding = true }
            if let resumeId, self.pendingRuntimeResume?.id == resumeId {
              self.pendingRuntimeResume = nil
              self.refreshFramePolicy()
            }
            self.refreshFramePolicy()
            // A cancelled fixed seek has no landing authority. Keep its last
            // coherent catalog and gate output until a guarded landing succeeds.
            if finished || self.videoSelection.fixedTrackId == nil { self.emitState() }
            else { self.recoverFixedLanding() }
          }
        }
    } else {
      savedPositionMs = max(0, milliseconds)
      savedPositionUs = Self.microsecondsFromMilliseconds(savedPositionMs)
      emitState()
    }
  }
  /// One recovery attempt owns an item generation and a seek UUID. A cancelled
  /// landing must neither manufacture PD-01 nor leave output gated indefinitely.
  private func recoverFixedLanding() {
    guard active, !stopped, let fixedId = videoSelection.fixedTrackId else { return }
    let generation = itemGeneration, seekId = UUID(), binding = callbackBinding
    let target = confirmedDashPositionUs
    pendingUserSeek = (seekId, generation, target)
    unconfirmedFixedLanding = true
    refreshFramePolicy()
    let fail = { [weak self] in
      guard let self, self.itemGeneration == generation, self.callbackBinding === binding,
            self.pendingUserSeek?.id == seekId, self.active, !self.stopped else { return }
      self.pendingUserSeek = nil
      self.fixedRecoveryDeadline?.cancel(); self.fixedRecoveryDeadline = nil
      self.failVideoConstraints(generation: generation, error: NativePlayerError(category: "source",
        code: "source.seek_failed", message: "The playback position could not be restored."))
    }
    fixedRecoveryDeadline?.cancel()
    let deadline = DispatchWorkItem(block: fail)
    fixedRecoveryDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: deadline)
    player.seek(to: CMTime(value: target, timescale: 1_000_000), toleranceBefore: .zero,
      toleranceAfter: .zero) { [weak self] finished in
      DispatchQueue.main.async {
        guard let self, self.itemGeneration == generation, self.callbackBinding === binding,
              self.pendingUserSeek?.id == seekId, self.active, !self.stopped else { return }
        let measured = microseconds(self.player.currentTime())
        guard finished, let measured,
              self.dashVideoCatalog?.tracks(at: measured).contains(where: { $0.id == fixedId }) == true else {
          fail(); return
        }
        self.fixedRecoveryDeadline?.cancel(); self.fixedRecoveryDeadline = nil
        self.pendingUserSeek = nil
        self.unconfirmedFixedLanding = false
        self.confirmedDashPositionUs = measured
        self.refreshFramePolicy()
        self.emitState()
      }
    }
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
    if source.loadOptions?.autoplay == true || (resume && playRequested) { try beforeAudioOutput() }
    stagedHls?.prepared.discard()
    stagedHls = StagedHls(source: source, prepared: prepared, resume: resume)
  }

  /// Preparation has succeeded. All fallible checks precede item/output mutation.
  /// Installation retains the session generation and samples transport intent now.
  func replaceActiveDash(source: YlAppleSourceDescriptor, prepared: YlPreparedHlsAsset, selection requestedSelection: YlNativeVideoSelection? = nil) throws {
    try checkAlive()
    guard active, YlSourceRouter.route(source) == .dashHls else {
      throw YlAppleVideoConstraints.reloadRequired
    }
    let shouldPlay = playRequested
    if shouldPlay { try beforeAudioOutput() }
    let coherentPosition = confirmedPositionUs()
    var selection = requestedSelection ?? videoSelection
    var chosen = prepared
    if let id = selection.fixedTrackId,
       prepared.loader.videoCatalog?.tracks(at: coherentPosition).contains(where: { $0.id == id }) != true {
      guard let automatic = prepared.takeAutomaticCandidate() else { throw YlNativeVideoSelection.unsupported }
      chosen = automatic
      selection = .init(reason: "trackUnavailable")
    }
    let loader = try chosen.takeLoader()
    let pendingSeekUs = pendingUserSeek.flatMap { $0.generation == itemGeneration ? $0.positionUs : nil }
    let positionUs = pendingSeekUs ?? currentPositionUs()
    resetOpenState(source, resume: true)
    savedPositionUs = positionUs
    savedPositionMs = positionUs / 1_000
    playRequested = shouldPlay
    qualityConstraint = loader.videoConstraints
    videoSelection = selection
    confirmedDashPositionUs = coherentPosition
    automaticDashCandidate = chosen.takeAutomaticCandidate()
    hlsResourceLoader = loader
    installItem(asset: chosen.asset, positionMs: savedPositionMs, resumePositionUs: positionUs,
      anchorRuntimeResume: true, forceResumeSeek: pendingSeekUs != nil)
    // Ready/status callbacks resume output using the preserved rate and intent.
    emitState()
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
        diagnostic: YlAppleSafeDiagnostics.diagnostic(error)
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
      installItem(asset: retained.asset, positionMs: savedPositionMs, resumePositionUs: savedPositionUs)
      if retained.shouldPlay { try startOutput() }
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
    videoSelection = .init()
    confirmedDashPositionUs = 0
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
    player.allowsExternalPlayback = false
    onAirPlayChanged?()
    liveMode = nil
    liveModeRequestId = nil
    qualityConstraint = .unconstrained
    channelGeneration = YlBackendGeneration.next()
    savedPositionMs = 0
    savedPositionUs = 0
    resumeAtLiveEdge = false
    sourceIsLive = false
    selectedAudioTrackId = nil
    audioOptions.removeAll()
    audioTracks.removeAll()
    videoTracks.removeAll()
    firstFrameSent = false
    hasBeenReady = false
    metricsCollector = YlMetricsCollector(); awaitingReconnectFrame = nil
    openStartedAt = nil
    openDurationMs = nil
    firstFrameDurationMs = nil
    currentError = nil
    status = "idle"
    resetting = false
  }

  func quiesceForReplacement() {
    deactivate(retainingHlsForReplacement: services.compatibility.retainsReplacementHls && videoSelection.fixedTrackId == nil)
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
    savedPositionUs = currentPositionUs()
    savedPositionMs = savedPositionUs / 1_000
    // A finite seekable tail is not a live edge. Static DASH is always finite,
    // and an unavailable duration alone cannot establish live playback.
    let live = dashVideoCatalog == nil && (sourceIsLive || player.currentItem?.duration.isIndefinite == true)
    if !live {
      resumeAtLiveEdge = false
    } else if let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue,
       let position = milliseconds(player.currentTime()),
       let end = milliseconds(CMTimeRangeGetEnd(range)),
       end - position <= 2_000 {
      resumeAtLiveEdge = true
    }
    finishBuffering()
    active = false
    playRequested = false
    player.pause()
    removeCurrentItem(releaseReplacement: !retainingHlsForReplacement, preserveDashCatalog: true, preserveAudioIdentity: true)
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

  func open(_ source: YlAppleSourceDescriptor, videoConstraints: YlAppleVideoConstraints? = nil) throws {
    try checkAlive()
    try validateOpen(source)
    if let videoConstraints { _ = try YlFallbackQualityConstraint(validating: videoConstraints) }
    if source.loadOptions?.autoplay == true { try beforeAudioOutput() }
    if stopped && services.platform == .ios { try configureAudioSession() }
    channelGeneration = YlBackendGeneration.next()
    resetOpenState(source, resume: false)
    if let videoConstraints { qualityConstraint = videoConstraints }
    try installItem(source, positionMs: source.loadOptions?.startPositionMs ?? 0)
    emitState()
  }

  private func resetOpenState(_ source: YlAppleSourceDescriptor, resume: Bool) {
    stopped = false
    cancelLiveReconnect()
    liveReconnectController = YlLiveReconnectController(configuration: configuration.network)
    removeCurrentItem(preserveAudioIdentity: resume)
    lastSource = source
    player.allowsExternalPlayback = source.airPlay
    liveMode = nil
    liveModeRequestId = source.livePlaybackRequestId
    let loadOptions = source.loadOptions
    if !resume, source.loadOptions != nil {
      qualityConstraint = loadOptions?.videoConstraints ?? .unconstrained
    }
    if !resume {
      automaticLiveCatchUpAllowed = true
      lastLiveCatchUpSeek = nil
      videoSelection = .init()
      confirmedDashPositionUs = 0
      savedPositionMs = 0
      savedPositionUs = 0
      resumeAtLiveEdge = false
      selectedAudioTrackId = nil
    }
    active = true
    sourceIsLive = source.isLive
    status = "opening"
    playRequested = !resume && (loadOptions?.autoplay ?? false)
    firstFrameSent = false
    hasBeenReady = false
    if !resume { metricsCollector = YlMetricsCollector(); awaitingReconnectFrame = nil }
    openStartedAt = CACurrentMediaTime()
    openDurationMs = nil
    firstFrameDurationMs = nil
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
    let resumePositionUs = stagedHls.resume ? savedPositionUs : nil
    let loader = try stagedHls.prepared.takeLoader()
    resetOpenState(stagedHls.source, resume: stagedHls.resume)
    // DASH's projection is immutable. Ordinary HLS restoration instead keeps
    // preferences successfully changed while its manifest was being prepared.
    if !stagedHls.resume || YlSourceRouter.route(stagedHls.source) == .dashHls {
      qualityConstraint = loader.videoConstraints
    }
    hlsResourceLoader = loader
    automaticDashCandidate = stagedHls.prepared.takeAutomaticCandidate()
    installItem(asset: stagedHls.prepared.asset, positionMs: positionMs, resumePositionUs: resumePositionUs,
      anchorRuntimeResume: videoSelection.fixedTrackId != nil,
      forceResumeSeek: stagedHls.resume && videoSelection.fixedTrackId != nil)
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
    let asset: AVURLAsset
    if #available(macOS 14.0, iOS 17.0, *), [YlSourceFormat.mp4, .mov].contains(source.formatHint) {
      // Preserve the explicit or inspected format when the URL has no usable
      // extension. AVFoundation otherwise rejects even a validated MP4/MOV prefix.
      asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: source.formatHint == .mov ? "video/quicktime" : "video/mp4"])
    } else {
      asset = AVURLAsset(url: url)
    }
    installItem(asset: asset, positionMs: positionMs)
  }

  private func installItem(asset: AVURLAsset, positionMs: Int64, resumePositionUs: Int64? = nil, anchorRuntimeResume: Bool = false, forceResumeSeek: Bool = false) {
    dashVideoCatalog = hlsResourceLoader?.videoCatalog
    // Empty explicit catalog retains the legacy AV asset-audio path (including
    // in-band audio). Only declared alternate renditions require NAME matching.
    dashAudioCatalog = hlsResourceLoader?.audioCatalog.flatMap { $0.isEmpty ? nil : $0 }
    // A pending or retired item's edge intent cannot override static DASH time.
    if dashVideoCatalog != nil { resumeAtLiveEdge = false }
    itemGeneration &+= 1
    if anchorRuntimeResume, let positionUs = resumePositionUs, positionUs > 0 || forceResumeSeek {
      pendingRuntimeResume = (UUID(), positionUs)
    }
    let generation = itemGeneration
    let item = makePlayerItem(asset)
    #if DEBUG && YL_BOUND_AV
    boundAudio = YlBoundFlutterProbe.current?.observeAvPlayer(player, item: item)
    #endif
    let effectiveConfiguration = self.effectiveConfiguration
    item.preferredForwardBufferDuration = effectiveConfiguration.preferredForwardBufferDuration
    player.automaticallyWaitsToMinimizeStalling = effectiveConfiguration.bufferMode != "lowLatency"
    applyQualityConstraint(qualityConstraint, to: item)
    videoOutput = makeVideoOutput([
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ])
    videoOutputConfigured = services.nativeViewType == nil
    item.add(videoOutput)
    refreshFramePolicy()
    player.replaceCurrentItem(with: item)
    displayLink?.isPaused = false
    observe(item, generation: generation)
    if let media = lastSource?.airPlayMedia {
      let binding = callbackBinding
      media.observeFailure { [weak self, weak media] error in
        DispatchQueue.main.async {
          guard let self, let media, !self.disposed, !self.stopped, self.active,
            self.itemGeneration == generation, self.callbackBinding === binding,
            self.lastSource?.airPlayMedia === media else { return }
          self.reportRestorationFailure(error)
        }
      }
    }
    // DASH Period boundaries can fall between milliseconds. Preserve the saved
    // program time through either restoration route; ordinary sources and new
    // Load start positions retain their existing millisecond seek contract.
    let exactResumeUs = dashVideoCatalog == nil ? nil : resumePositionUs
    if (forceResumeSeek || (exactResumeUs.map { $0 > 0 } ?? (positionMs > 0))) && !resumeAtLiveEdge {
      let position = exactResumeUs.map { CMTime(value: $0, timescale: 1_000_000) }
        ?? CMTime(milliseconds: positionMs, preferredTimescale: 1_000)
      if let pending = pendingRuntimeResume {
        player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
          DispatchQueue.main.async {
            guard let self, self.isCurrent(item, generation: generation),
                  self.pendingRuntimeResume?.id == pending.id else { return }
            self.pendingRuntimeResume = nil
            if finished {
              self.unconfirmedFixedLanding = false
              self.confirmedDashPositionUs = microseconds(self.player.currentTime()) ?? self.confirmedDashPositionUs
            } else if self.videoSelection.fixedTrackId != nil { self.unconfirmedFixedLanding = true }
            self.refreshFramePolicy()
            if finished || self.videoSelection.fixedTrackId == nil { self.emitState() }
            else { self.recoverFixedLanding() }
          }
        }
      } else {
        player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
      }
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
        do { try startOutput() }
        catch { handleFailure(error, item: item, generation: generation); return }
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
      loadMetadata(item, generation: generation)
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

  private func finishBuffering() { metricsCollector.observe(.playback("paused")) }

  private func handleFailure(
    _ error: Error?,
    item: AVPlayerItem? = nil,
    generation: UInt64? = nil
  ) {
    let failureGeneration = generation ?? itemGeneration
    guard failureGate.begin(generation: failureGeneration) else { return }
    stallWatchdog.cancel()
    // Identity restoration is a player contract error, not an AVFoundation
    // NSError. Preserve its public code instead of bridging it to avplayer.1.
    if let selectionError = error as? NativePlayerError, selectionError.code == "track.not_found" {
      guard failureGate.finish(generation: failureGeneration, currentGeneration: itemGeneration),
            !disposed, active else { return }
      failureGate.markTerminal(generation: failureGeneration)
      status = "error"
      currentError = selectionError
      emit(.failure(selectionError))
      emitState(error: selectionError)
      return
    }
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
    recordPlaybackDiagnostic(event: "playbackFailure", error: error, errorLogCode: log?.statusCode)
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
    guard !disposed, !airPlayActive, videoOutputConfigured, textureId >= 0, player.currentItem != nil else { return }
    let generation = itemGeneration
    var framePublished = false
    defer { observeVideoProgress(framePublished: framePublished) }
    let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
    guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime) else { return }
    if services.compatibility.reconnectsAvPlayer { liveReconnectController.markFirstFrame() }
    if let reconnect = awaitingReconnectFrame {
      metricsCollector.observe(.reconnect(id: reconnect)); awaitingReconnectFrame = nil
    }
    guard let buffer = copyPixelBuffer()?.takeRetainedValue() else { return }
    let frameGeometry = YlVideoGeometryResolver.avPlayer(pixelBuffer: buffer,
      rotationDegrees: videoGeometry?.rotationDegrees ?? 0)
    let geometryChanged = frameGeometry.map {
      videoGeometry?.encodedSize != $0.encodedSize ||
        videoGeometry?.displaySize != $0.displaySize ||
        videoGeometry?.pixelAspectRatio != $0.pixelAspectRatio
    } ?? false
    if let frameGeometry { videoGeometry = frameGeometry }
    if geometryChanged { emitState() }
    // Current-Period reconciliation can synchronously install automatic output.
    guard generation == itemGeneration else { return }
    services.textureOutput.publish(buffer)
    framePublished = true
    if !firstFrameSent {
      firstFrameSent = true
      firstFrameDurationMs = elapsedMilliseconds(since: openStartedAt)
      let size = hasDashDimensionLimits ? (videoGeometry?.finalDisplaySize ?? .zero) : (player.currentItem?.presentationSize ?? .zero)
      emit(.firstFrame(width: size.width > 0 ? Int(size.width) : nil, height: size.height > 0 ? Int(size.height) : nil))
      emitState()
      refreshStallWatchdog()
    }
  }

  private func observeVideoProgress(framePublished: Bool) {
    guard !airPlayActive, active, playRequested, firstFrameSent,
          player.currentItem?.status == .readyToPlay,
          status != "completed", status != "error" else {
      videoProgressProbe.reset()
      return
    }
    guard let observation = videoProgressProbe.observe(enabled: true,
      framePublished: framePublished, positionMs: milliseconds(player.currentTime()),
      nowMs: YlAppleSafeDiagnostics.nowMilliseconds(),
      timeoutMs: configuration.network.readTimeoutMs) else { return }
    recordPlaybackDiagnostic(event: observation.kind.rawValue, observation: observation)
  }

  /// Only package-owned labels and numeric state are logged. Never interpolate
  /// source URLs, request IDs/headers, NSError descriptions or error-log URIs.
  private func recordPlaybackDiagnostic(event: String,
    observation: YlAvPlayerVideoProgressProbe.Observation? = nil,
    error: NSError? = nil, errorLogCode: Int? = nil) {
    let item = player.currentItem
    let positionMs = observation?.positionMs ?? milliseconds(player.currentTime()) ?? -1
    let loadedEndMs = item?.loadedTimeRanges.last
      .flatMap { milliseconds(CMTimeRangeGetEnd($0.timeRangeValue)) } ?? -1
    var errorCodes = [Int]()
    var underlying = error
    for _ in 0..<8 {
      guard let current = underlying else { break }
      errorCodes.append(current.code)
      underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    NSLog("%@", "[YLPlayer][AVPlayer] event=\(event) player=\(playerId) item=\(itemGeneration)"
      + " positionMs=\(positionMs) frameGapMs=\(observation?.frameGapMs ?? -1)"
      + " timelineGapMs=\(observation?.timelineGapMs ?? -1)"
      + " timeControl=\(player.timeControlStatus.rawValue) itemStatus=\(item?.status.rawValue ?? -1)"
      + " rate=\(player.rate) bufferEmpty=\(item?.isPlaybackBufferEmpty ?? false)"
      + " likelyToKeepUp=\(item?.isPlaybackLikelyToKeepUp ?? false) loadedEndMs=\(loadedEndMs)"
      + " headeredHls=\(hlsResourceLoader != nil) errorCodes=\(errorCodes) errorLogCode=\(errorLogCode ?? 0)")
  }

  private func refreshStallWatchdog() {
    let generation = itemGeneration
    stallWatchdog.update(
      active: active,
      wantsToPlay: playRequested,
      hasCurrentItem: player.currentItem != nil,
      timeControlStatus: player.timeControlStatus,
      playbackStatus: status,
      firstFrameSent: firstFrameSent || airPlayActive,
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
    recordPlaybackDiagnostic(event: "stallTimeout")
    // A silent read stall is recoverable just like an explicit network timeout.
    // Keep playback intent and the last frame until native retries are exhausted.
    if services.compatibility.reconnectsAvPlayer, let source = lastSource,
       YlAvPlayerRecoveryPolicy.shouldReconnect(
         source: source,
         usesResourceLoader: hlsResourceLoader != nil,
         hasBeenReady: hasBeenReady,
         playRequested: playRequested,
         error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
         errorLogDomain: nil,
         errorLogStatusCode: nil
       ), scheduleLiveReconnect(source: source) {
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

  // Raster callbacks may run off-main. Their immutable item authority and the
  // rejection latch share one lock; only the terminal event is queued to main.
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    framePolicyLock.lock()
    guard let policy = framePolicy, !policy.blocked, !policy.awaitingResumeSeek else { framePolicyLock.unlock(); return nil }
    let rotation = policy.rotation
    let fixedTrack = policy.fixedTrack, catalog = policy.catalog
    framePolicyLock.unlock()
    let itemTime = policy.output.itemTime(forHostTime: CACurrentMediaTime())
    guard policy.output.hasNewPixelBuffer(forItemTime: itemTime),
          let buffer = policy.output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
    else { return nil }
    let caps = policy.constraints
    let geometry = YlVideoGeometryResolver.avPlayer(pixelBuffer: buffer, rotationDegrees: rotation)
    if let fixed = fixedTrack {
      let framePosition = microseconds(itemTime) ?? 0
      let available = catalog?.tracks(at: framePosition).contains { $0.id == fixed.id } == true
      guard available else {
        DispatchQueue.main.async { [weak self] in
          guard let self, self.itemGeneration == policy.generation else { return }
          self.emitState()
        }
        return nil
      }
      guard geometry?.encodedSize.width == CGFloat(fixed.width ?? 0),
            geometry?.encodedSize.height == CGFloat(fixed.height ?? 0) else {
        scheduleVideoConstraintFailure(generation: policy.generation)
        return nil
      }
    }
    let permitted = Self.permits(geometry, constraints: caps)
    framePolicyLock.lock()
    guard framePolicy === policy, !policy.blocked, !policy.awaitingResumeSeek, policy.rotation == rotation else { framePolicyLock.unlock(); return nil }
    if !permitted { policy.blocked = true }
    else { policy.measuredGeometry = geometry }
    framePolicyLock.unlock()
    guard permitted else {
      scheduleVideoConstraintFailure(generation: policy.generation)
      return nil
    }
    return Unmanaged.passRetained(buffer)
  }

  private func refreshFramePolicy() {
    let constraints = lastSource.map { YlSourceRouter.route($0) == .dashHls } == true
      ? qualityConstraint : .unconstrained
    framePolicyLock.lock()
    if let policy = framePolicy, policy.generation == itemGeneration, policy.output === videoOutput {
      policy.rotation = videoGeometry?.rotationDegrees ?? 0
    } else {
      let blocked = framePolicy.map { $0.generation == itemGeneration && $0.blocked } ?? false
      let measured = framePolicy.flatMap { $0.generation == itemGeneration ? $0.measuredGeometry : nil }
      framePolicy = FramePolicy(output: videoOutput, generation: itemGeneration,
        constraints: constraints, rotation: videoGeometry?.rotationDegrees ?? 0)
      framePolicy?.blocked = blocked
      framePolicy?.measuredGeometry = measured
    }
    framePolicy?.fixedTrack = videoSelection.fixedTrackId.flatMap { id in
      dashVideoCatalog?.tracks(at: confirmedDashPositionUs).first { $0.id == id }
    }
    framePolicy?.catalog = dashVideoCatalog
    framePolicy?.awaitingResumeSeek = pendingRuntimeResume != nil
      || (videoSelection.fixedTrackId != nil && (pendingUserSeek != nil || unconfirmedFixedLanding))
    framePolicyLock.unlock()
  }

  private static func permits(_ geometry: YlVideoGeometry?, constraints: YlAppleVideoConstraints) -> Bool {
    guard constraints.maxWidth != nil || constraints.maxHeight != nil else { return true }
    guard let size = geometry?.finalDisplaySize, size.width.isFinite, size.height.isFinite,
          size.width > 0, size.height > 0 else { return false }
    return (constraints.maxWidth.map { CGFloat($0) >= size.width } ?? true)
      && (constraints.maxHeight.map { CGFloat($0) >= size.height } ?? true)
  }

  private var hasDashDimensionLimits: Bool {
    lastSource.map { YlSourceRouter.route($0) == .dashHls } == true
      && (qualityConstraint.maxWidth != nil || qualityConstraint.maxHeight != nil)
  }

  private func scheduleVideoConstraintFailure(generation: UInt64) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.disposed, self.itemGeneration == generation else { return }
      self.failVideoConstraints(generation: generation)
    }
  }

  private func failVideoConstraints(generation: UInt64, error: NativePlayerError = YlAppleVideoConstraints.unsupportedOutput) {
    guard generation == itemGeneration, !disposed, status != "error" else { return }
    framePolicyLock.lock(); framePolicy?.blocked = true; framePolicyLock.unlock()
    failureGate.markTerminal(generation: generation)
    stallWatchdog.cancel()
    displayLink?.isPaused = true
    playRequested = false
    player.pause()
    status = "error"
    currentError = error
    emit(.failure(error))
    emitState(error: error)
  }

  func seekToLiveEdge() throws {
    automaticLiveCatchUpAllowed = true
    try checkAlive(); guard !stopped else { return }
    guard sourceIsLive || isIndefinite(player.currentItem?.duration) else {
      throw NativePlayerError(
        category: "source",
        code: "source.not_live",
        message: "The current source is not live."
      )
    }
    videoProgressProbe.reset()
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
          let group = audioGroup
    else {
      emitState()
      return
    }
    item.select(option, in: group)
    try rebuildAudioTracks(item)
    emitState()
  }

  func setVideoConstraints(_ constraint: YlAppleVideoConstraints) throws {
    try checkAlive()
    _ = try YlFallbackQualityConstraint(validating: constraint)
    if let source = lastSource, YlSourceRouter.route(source) == .dashHls,
       constraint != qualityConstraint { throw YlAppleVideoConstraints.reloadRequired }
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

  @discardableResult
  func applyMetadataGeometry(_ geometry: YlVideoGeometry?, hasVideoTracks: Bool) -> Bool {
    if videoSelection.fixedTrackId != nil { return true }
    guard hasDashDimensionLimits else {
      if let geometry { videoGeometry = geometry }
      return true
    }
    // Missing HLS tracks are normal; an existing track with invalid transform
    // evidence cannot authorize a new display geometry for constrained output.
    guard hasVideoTracks else { return true }
    // Seeking gates raster output, not valid metadata or audio-group discovery.
    framePolicyLock.lock()
    guard let policy = framePolicy, !policy.blocked else { framePolicyLock.unlock(); return false }
    let resolved: YlVideoGeometry?
    if let geometry, let measured = policy.measuredGeometry {
      resolved = YlVideoGeometry(encodedSize: measured.encodedSize, cleanAperture: measured.cleanAperture,
        displaySize: measured.displaySize, pixelAspectRatio: measured.pixelAspectRatio,
        rotationDegrees: geometry.rotationDegrees)
    } else { resolved = geometry }
    guard Self.permits(resolved, constraints: policy.constraints) else {
      policy.blocked = true
      framePolicyLock.unlock()
      scheduleVideoConstraintFailure(generation: policy.generation)
      return false
    }
    policy.rotation = resolved?.rotationDegrees ?? 0
    framePolicyLock.unlock()
    videoGeometry = resolved
    return true
  }

  private func loadMetadata(_ item: AVPlayerItem, generation: UInt64) {
    guard metadataTask == nil else { return }
    // State publication must never synchronously inspect a network asset. On
    // merged Flutter threads that also blocks the app's loopback HTTP server.
    metadataTask = Task { @MainActor [weak self, weak item] in
      guard let item else { return }
      do {
        let tracks = try await item.asset.loadTracks(withMediaType: .video)
        var catalog = [YlNativeTrack]()
        var geometry: YlVideoGeometry?
        var selectedFormat: CMVideoFormatDescription?
        for (index, track) in tracks.enumerated() {
          let (size, transform, bitrate, formats) = try await track.load(
            .naturalSize, .preferredTransform, .estimatedDataRate, .formatDescriptions)
          try Task.checkCancellation()
          let display = size.applying(transform)
          catalog.append(YlNativeTrack(id: "video-\(index)", kind: .video,
            bitrate: Int(bitrate), width: Int(abs(display.width)),
            height: Int(abs(display.height)), isSelected: true))
          if index == 0 {
            selectedFormat = formats.first
            geometry = YlVideoGeometryResolver.avPlayer(
              presentationSize: item.presentationSize, naturalSize: size,
              preferredTransform: transform, format: formats.first)
          }
        }
        guard let self, self.isCurrent(item, generation: generation) else { return }
        if self.services.nativeViewType != nil {
          // Adaptive HLS can change precision after its initial track metadata.
          // Keep that output at 10 bits; fixed SDR files retain the 8-bit path.
          let adaptive = self.lastSource?.url.map {
            YlEngineRouter.resolvedFormat(self.lastSource!, url: $0) == .hls
          } ?? false
          if selectedFormat.map(YlHDRVideoPolicy.isHDR) == true || adaptive {
            let pixelFormat = selectedFormat.map(YlHDRVideoPolicy.pixelFormat)
            let hdrPixelFormat = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
              ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            item.remove(self.videoOutput)
            self.videoOutput = self.makeVideoOutput([
              kCVPixelBufferPixelFormatTypeKey as String: hdrPixelFormat,
              kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ])
            item.add(self.videoOutput)
          }
          self.videoOutputConfigured = true
        }
        // Do not erase frame-measured HLS geometry when the asset has no tracks.
        guard self.applyMetadataGeometry(geometry, hasVideoTracks: !tracks.isEmpty) else { return }
        self.applyMetadataVideoTracks(catalog, for: item)
        self.refreshFramePolicy()
        self.emitState()
        let group = try await item.asset.loadMediaSelectionGroup(for: .audible)
        try Task.checkCancellation()
        guard self.isCurrent(item, generation: generation) else { return }
        self.audioGroup = group
        try self.rebuildAudioTracks(item)
        self.emitState()
      } catch {
        guard !Task.isCancelled, let self,
              self.isCurrent(item, generation: generation) else { return }
        self.handleFailure(error, item: item, generation: generation)
      }
    }
  }

  func applyMetadataVideoTracks(_ tracks: [YlNativeTrack], for item: AVPlayerItem) {
    guard player.currentItem === item, dashVideoCatalog == nil else { return }
    videoTracks = tracks
  }

  private func rebuildAudioTracks(_ item: AVPlayerItem) throws {
    guard let group = audioGroup else {
      guard selectedAudioTrackId == nil else {
        throw NativePlayerError(category: "source", code: "track.not_found", message: "The requested audio track is unavailable.")
      }
      guard dashAudioCatalog?.isEmpty != false else { throw YlDashBounds.unsupported }
      audioOptions = [:]; audioTracks = []
      emit(.tracksChanged(audio: audioTracks, video: videoTracks)); return
    }
    let options = group.options
    guard options.count <= 128 else { throw YlDashBounds.unsupported }
    let ids: [String]
    if let catalog = dashAudioCatalog {
      // HLS NAME is exposed through common title metadata. displayName is only
      // an exact-token fallback, never a language or localized-label heuristic.
      let names = options.map { option in
        [option.displayName] + option.commonMetadata.filter { $0.commonKey == .commonKeyTitle }.compactMap(\.stringValue)
      }
      ids = try YlDashAudioOptionMapping.identities(names: names, catalog: catalog)
    } else {
      ids = try audioIdentityRegistry.identities(options: options,
        restore: { group.mediaSelectionOption(withPropertyList: $0) },
        encode: { $0.propertyList() })
    }
    let mapped = Dictionary(uniqueKeysWithValues: zip(ids, options))
    if let selectedAudioTrackId {
      guard let option = mapped[selectedAudioTrackId] else {
        throw NativePlayerError(category: "source", code: "track.not_found", message: "The requested audio track is unavailable.")
      }
      item.select(option, in: group)
    }
    let selected = item.currentMediaSelection.selectedMediaOption(in: group)
    let tracks = zip(ids, options).map { id, option -> YlNativeTrack in
      var track = dashAudioCatalog?.first { $0.id == id } ?? YlNativeTrack(id: id, kind: .audio,
        label: option.displayName, language: option.extendedLanguageTag ?? option.locale?.identifier)
      track.isSelected = selected == option
      return track
    }
    audioOptions = mapped
    audioTracks = dashAudioCatalog == nil ? tracks : tracks.sorted { $0.id < $1.id }
    emit(.tracksChanged(audio: audioTracks, video: videoTracks))
  }

  private func emit(_ event: YlNativeBackendEvent) {
    callbackBinding.emit(YlNativeBackendCallback(generation: channelGeneration, loadRequestId: lastSource?.loadRequestId, event: event))
  }

  // Access logs report actual transferred media bytes, but AVFoundation may
  // update them in batches. No observed/indicated bitrate is used as traffic.
  var networkBytesReceived: Int64? {
    guard lastSource?.url?.isFileURL == false, let item = player.currentItem else { return nil }
    // Custom HLS loads may replay cached bytes over loopback: count only the
    // origin URLSession callbacks, never AVPlayer's local proxy transfers.
    if let loader = hlsResourceLoader { return loader.trafficScope?.networkBytesReceived }
    guard let bytes = metricsCollector.accessLogNetworkBytes(item: item,
      transferred: item.accessLog()?.events.map(\.numberOfBytesTransferred) ?? []) else { return nil }
    let total = bytes.addingReportingOverflow(lastSource?.bufferScope?.networkBytesReceived ?? 0)
    return total.overflow ? Int64.max : total.partialValue
  }

  private func collectMetrics(liveOffsetMs: Int64?) -> YlNativeMetrics {
    if let ready = openDurationMs { metricsCollector.observe(.ready(durationMs: ready)) }
    if let frame = firstFrameDurationMs { metricsCollector.observe(.firstFrame(durationMs: frame)) }
    metricsCollector.observe(.playback(status))
    var metrics = metricsCollector.snapshot
    metrics.liveOffsetMs = liveOffsetMs
    metrics.networkBytesReceived = networkBytesReceived
    return metrics
  }

  func emitState() {
    emitState(error: nil)
  }

  private static func microsecondsFromMilliseconds(_ value: Int64) -> Int64 {
    let (result, overflow) = value.multipliedReportingOverflow(by: 1_000)
    return overflow ? Int64.max : result
  }

  private func currentPositionUs() -> Int64 {
    pendingRuntimeResume?.positionUs ?? (active ? (microseconds(player.currentTime()) ?? savedPositionUs) : savedPositionUs)
  }

  @discardableResult
  private func refreshDashVideoTracks(at positionUs: Int64) -> Bool {
    guard let dashVideoCatalog else { return false }
    if status == "error", videoSelection.fixedTrackId != nil { return false }
    let coherent = videoSelection.fixedTrackId == nil ? positionUs : confirmedPositionUs()
    if let id = videoSelection.fixedTrackId,
       pendingRuntimeResume == nil, pendingUserSeek == nil, !unconfirmedFixedLanding,
       !dashVideoCatalog.tracks(at: coherent).contains(where: { $0.id == id }),
       let source = lastSource {
      guard let automatic = automaticDashCandidate else {
        failVideoConstraints(generation: itemGeneration)
        return false
      }
      automaticDashCandidate = nil
      do {
        onAutomaticFallback?()
        try replaceActiveDash(source: source, prepared: automatic, selection: .init(reason: "trackUnavailable"))
      } catch {
        // Do not claim auto if the automatic item could not be installed.
        automatic.discard()
        failVideoConstraints(generation: itemGeneration)
      }
      return true
    }
    if pendingRuntimeResume == nil && pendingUserSeek == nil && !unconfirmedFixedLanding { confirmedDashPositionUs = coherent }
    let tracks = dashVideoCatalog.tracks(at: coherent)
    guard tracks.count != videoTracks.count || !zip(tracks, videoTracks).allSatisfy({
      $0.id == $1.id && $0.codec == $1.codec && $0.isSelected == $1.isSelected
    }) else { return false }
    videoTracks = tracks
    emit(.tracksChanged(audio: audioTracks, video: videoTracks))
    return true
  }

  private func emitState(error: NativePlayerError?, positionUs sampledPositionUs: Int64? = nil) {
    guard !disposed, !resetting else { return }
    let item = player.currentItem
    let positionUs = sampledPositionUs ?? currentPositionUs()
    let positionMs = positionUs / 1_000
    let generation = itemGeneration
    refreshDashVideoTracks(at: positionUs)
    guard generation == itemGeneration else { return }
    let durationMs = milliseconds(item?.duration)
    let loadedEndMs = item?.loadedTimeRanges.last
      .map { milliseconds(CMTimeRangeGetEnd($0.timeRangeValue)) ?? 0 } ?? 0
    let seekableRange = item?.seekableTimeRanges.last?.timeRangeValue
    let dvrStartMs = seekableRange.flatMap { milliseconds($0.start) }
    let dvrEndMs = seekableRange.flatMap { milliseconds(CMTimeRangeGetEnd($0)) }
    let live = sourceIsLive || isIndefinite(item?.duration)
    let liveOffsetMs = live ? dvrEndMs.map { max(0, $0 - positionMs) } : nil
    let size = hasDashDimensionLimits ? (videoGeometry?.finalDisplaySize ?? .zero) : (item?.presentationSize ?? .zero)
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
      metrics: collectMetrics(liveOffsetMs: liveOffsetMs),
      error: error ?? currentError, geometry: videoGeometry, videoSelection: videoSelection, livePlayback: livePlaybackState(live))))
  }

  private func emitStateDelta() {
    guard !disposed, !stopped, !resetting else { return }
    let item = player.currentItem
    let positionUs = currentPositionUs()
    let generation = itemGeneration
    if refreshDashVideoTracks(at: positionUs) {
      guard generation == itemGeneration else { return }
      // One sample owns both timeline and catalog, including fractional-ms edges.
      emitState(error: nil, positionUs: positionUs)
      return
    }
    let positionMs = positionUs / 1_000
    let loadedEndMs = item?.loadedTimeRanges.last
      .map { milliseconds(CMTimeRangeGetEnd($0.timeRangeValue)) ?? 0 } ?? 0
    let seekableRange = item?.seekableTimeRanges.last?.timeRangeValue
    let live = sourceIsLive || isIndefinite(item?.duration)
    let dvrEndMs = seekableRange.flatMap { milliseconds(CMTimeRangeGetEnd($0)) }
    let liveOffsetMs = live ? dvrEndMs.map { max(0, $0 - positionMs) } : nil
    let now = CACurrentMediaTime()
    let action = YlLiveCatchUpPolicy.action(lowLatency: liveMode == .lowLatency,
      playing: playRequested, active: active && !stopped,
      automaticEdgeAllowed: automaticLiveCatchUpAllowed, requestedRate: desiredRate,
      offsetMs: liveOffsetMs, targetMs: 2_000, hasSeekableWindow: seekableRange != nil,
      maySeek: lastLiveCatchUpSeek.map { now - $0 >= 30 } ?? true)
    switch action {
    case .none: break
    case .rate(let rate):
      if player.rate != 0 { player.rate = rate; liveCatchUpRate = rate != desiredRate }
    case .edge:
      lastLiveCatchUpSeek = now
      try? seekToLiveEdge()
    }
    emit(.delta(YlNativeTimelineDelta(positionMs: positionMs,
      bufferedPositionMs: loadedEndMs,
      isAtLiveEdge: liveOffsetMs.map { $0 <= 2_000 } ?? false,
      liveOffsetMs: liveOffsetMs,
      metrics: collectMetrics(liveOffsetMs: liveOffsetMs))))
  }

  func dispose() {
    airPlayObservation?.invalidate(); airPlayObservation = nil
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
    liveMode = nil
    liveModeRequestId = nil
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

  private func removeCurrentItem(releaseReplacement: Bool = true, clearOutput: Bool = true, preserveDashCatalog: Bool = false, preserveAudioIdentity: Bool = false) {
    _ = networkBytesReceived
    automaticDashCandidate?.discard(); automaticDashCandidate = nil
    fixedRecoveryDeadline?.cancel(); fixedRecoveryDeadline = nil
    unconfirmedFixedLanding = false
    pendingRuntimeResume = nil
    pendingUserSeek = nil
    if !preserveDashCatalog { dashVideoCatalog = nil; dashAudioCatalog = nil }
    if !preserveAudioIdentity {
      audioIdentityRegistry.reset()
      selectedAudioTrackId = nil
    }
    framePolicyLock.lock(); framePolicy = nil; framePolicyLock.unlock()
    videoProgressProbe.reset()
    metadataTask?.cancel()
    metadataTask = nil
    videoGeometry = nil
    audioGroup = nil
    audioOptions.removeAll()
    audioTracks.removeAll()
    videoTracks.removeAll()
    if releaseReplacement { finishReplacement() }
    itemGeneration &+= 1
    stallWatchdog.cancel()
    failureGate.reset()
    removeItemObservers()
    displayLink?.isPaused = true
    #if DEBUG && YL_BOUND_AV
    boundAudio?.detach(); boundAudio = nil
    #endif
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
    // Reconnect the same live source without flashing an empty texture between
    // items. The next frame replaces it; stop and source changes still clear it.
    removeCurrentItem(clearOutput: false, preserveAudioIdentity: true)
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
        self.awaitingReconnectFrame = self.itemGeneration
        if self.playRequested {
          try self.startOutput()
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

private func microseconds(_ time: CMTime?) -> Int64? {
  guard let time, time.isNumeric, !time.isIndefinite else { return nil }
  let converted = CMTimeConvertScale(time, timescale: 1_000_000, method: .roundTowardZero)
  guard converted.isNumeric else { return nil }
  return max(0, converted.value)
}

private func milliseconds(_ time: CMTime?) -> Int64? {
  microseconds(time).map { $0 / 1_000 }
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


/// Session-local option identities restored by the platform's property-list API.
/// New options never inherit a removed option's array-index identity.
struct YlAudioSelectionIdentityRegistry {
  private var records: [(String, Any)] = []
  private var next = 0
  mutating func reset() { records.removeAll() }
  mutating func identities<Option: Equatable>(options: [Option], restore: (Any) -> Option?, encode: (Option) -> Any) throws -> [String] {
    guard options.count <= 128 else { throw YlDashBounds.unsupported }
    let restored = records.compactMap { record -> (String, Option)? in
      restore(record.1).map { (record.0, $0) }
    }
    var used = Set<String>()
    var candidate: [(String, Any)] = []
    for option in options {
      let matches = restored.filter { $0.1 == option }
      guard matches.count <= 1 else { throw YlDashBounds.unsupported }
      let id: String
      if let match = matches.first { id = match.0 }
      else {
        guard next < Int.max else { throw YlDashBounds.unsupported }
        id = "audio-\(next)"; next += 1
      }
      guard used.insert(id).inserted else { throw YlDashBounds.unsupported }
      candidate.append((id, encode(option)))
    }
    records = candidate
    return candidate.map { $0.0 }
  }
}

/// Resolves compiler-owned NAME tokens without relying on AV option ordering.
enum YlDashAudioOptionMapping {
  static func identities(names: [[String]], catalog: [YlNativeTrack]) throws -> [String] {
    guard names.count == catalog.count else { throw YlDashBounds.unsupported }
    let expected = Set(catalog.map(\.id))
    guard expected.count == catalog.count else { throw YlDashBounds.unsupported }
    var used = Set<String>()
    return try names.map { values in
      let matches = Set(values).intersection(expected)
      guard matches.count == 1, let id = matches.first, used.insert(id).inserted else { throw YlDashBounds.unsupported }
      return id
    }
  }
}
