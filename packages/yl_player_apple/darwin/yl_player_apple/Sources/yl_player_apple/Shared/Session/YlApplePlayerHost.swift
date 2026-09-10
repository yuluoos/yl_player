import Foundation
import AVFoundation

/// Only this boundary projects private Pigeon records to native compatibility
/// commands and encodes native measurements back to generated callback records.
final class YlApplePlayerHost: ApplePlayerHostApi {
  let playerId: Int64
  let suffix: String
  let positionUpdateIntervalMs: Int64
  private let options: ApplePlayerOptionsMessage
  private let services: YlPlatformServices
  private let callbacks: ApplePlayerFlutterApiProtocol
  private let reducer: YlAppleStateReducer
  private let outbound = YlAppleOutboundQueue()
  private var coordinator: YlAppleSessionCoordinator!
  private var textureOwner: YlAppleTextureOwner!
  private var attached = false
  private(set) var disposed = false
  private var suspended = false
  private var playbackIntentVersion: UInt64 = 0
  private var restorationVersion: UInt64 = 0
  private var restoring = false
  private var stagedSnapshot: (YlAppleSessionIdentity, YlNativeBackendCallback)?
  private var committedStreamIntent: AppleStreamIntent = .automatic
  private var resumePlayback = false
  private var restoreOnResume = false
  var willCommit: ((Bool) -> Void)?
  var didCommit: (() -> Void)?
  var didRollback: (() -> Void)?
  var didDispose: (() -> Void)?

  init(playerId: Int64, suffix: String, options: ApplePlayerOptionsMessage,
       services: YlPlatformServices, callbacks: ApplePlayerFlutterApiProtocol,
       avPlayer: AVPlayer = AVPlayer(), commandCoordinator: YlAsyncCommandCoordinator = YlAsyncCommandCoordinator(),
       beforeFallbackConstruction: ((YlPlaybackBackend) throws -> Void)? = nil,
       slotCompatibility: YlAppleCompatibility? = nil,
       bufferLedger: YlManagedBufferLedger = YlManagedBufferLedger(),
       videoSessionFactory: YlVTSessionFactory? = nil,
       hardwareEvidenceStage: YlHardwareEvidencePreparation = .init(),
       audioOwnership: YlPlayerAudioOwnership? = nil,
       clock: @escaping () -> Int64 = YlAppleSafeDiagnostics.nowMilliseconds) {
    self.playerId = playerId
    self.suffix = suffix
    self.options = options
    self.positionUpdateIntervalMs = options.positionUpdateIntervalMs
    self.services = services
    self.callbacks = callbacks
    reducer = YlAppleStateReducer(playerId: playerId, clock: clock)
    textureOwner = YlAppleTextureOwner(output: services.textureOutput) { [weak self] identity in
      guard let self, !self.disposed, !self.suspended, !self.restoring else { return }
      self.reducer.publicFrame(identity: identity)
    }
    let audio = audioOwnership ?? (options.audioPolicy == .pluginManagedMediaPlayback
      ? YlPlayerAudioOwnership(coordinator: .shared, key: .init(registry: UUID(), player: suffix)) : nil)
    coordinator = YlAppleSessionCoordinator(playerId: playerId, services: services,
      configuration: PlayerConfiguration(positionEventIntervalMs: options.positionUpdateIntervalMs),
      textureOwner: textureOwner, avPlayer: avPlayer, commandCoordinator: commandCoordinator,
      beforeFallbackConstruction: beforeFallbackConstruction, slotCompatibility: slotCompatibility, bufferLedger: bufferLedger,
      videoSessionFactory: videoSessionFactory, hardwareEvidenceStage: hardwareEvidenceStage, audioOwnership: audio) { [weak self] identity, callback in
        self?.receive(callback, identity: identity)
      }
    reducer.onOutput = { [weak self] output in self?.send(output) }
    reducer.onExhausted = { [weak self] in self?.close() }
    outbound.onFailure = { [weak self] in self?.close() }
  }

  var initialState: AppleStateMessage { encode(reducer.state) }
  var managesAudio: Bool { options.audioPolicy == .pluginManagedMediaPlayback }
  var isActive: Bool { coordinator.isActive }
  var playbackIntent: Bool { coordinator.currentPlaybackIntent }
  var acceptedVideoConstraints: YlAppleVideoConstraints { coordinator.acceptedVideoConstraints }
  var sessionId: String? { reducer.identity?.sessionId }

  func attach() throws {
    try alive()
    guard !attached else { return }
    attached = true
    send(.state(reducer.state))
  }
  func assess(request: AppleAssessRequest) throws -> AppleAssessmentReply {
    try alive()
    do {
      let recipe = try YlAppleNativeInput.load(source: request.source, options: request.options,
        defaults: options, loadRequestId: nil)
      let assessment = YlEngineRouter.assess(recipe.source)
      let outcome: AppleAssessmentOutcome
      switch assessment.outcome {
      case .compatible: outcome = .compatible
      case .incompatible: outcome = .incompatible
      case .requiresInspection: outcome = .requiresInspection
      }
      return AppleAssessmentReply(outcome: outcome,
        candidateEngine: assessment.engine.map(Self.engine),
        satisfiedRequirements: assessment.satisfiedRequirements.map(\.rawValue),
        limitations: assessment.limitations.map(\.rawValue),
        rejection: assessment.rejection.map { YlAppleFailureMapper.message($0, scope: .command) })
    } catch {
      return AppleAssessmentReply(outcome: .incompatible, candidateEngine: nil,
        satisfiedRequirements: [], limitations: [], rejection: YlAppleFailureMapper.message(error, scope: .command))
    }
  }
  func load(request: AppleLoadRequest) async throws -> AppleLoadReply {
    try await onMain { completion in
      do {
        try self.alive()
        guard !request.loadRequestId.isEmpty else { throw YlAppleFailureMapper.invalid() }
        let recipe = try YlAppleNativeInput.load(source: request.source, options: request.options,
          defaults: self.options, loadRequestId: request.loadRequestId)
        // Validation precedes cancellation, identity allocation and saved intent.
        guard !self.suspended else { throw YlOpenCancellationToken.cancellationError() }
        self.restorationVersion &+= 1
        self.restoring = false
        self.stagedSnapshot = nil
        let identity = self.reducer.makeIdentity(loadRequestId: request.loadRequestId)
        self.coordinator.load(recipe, identity: identity,
          willCommit: { self.willCommit?($0) },
          didCommit: {
            self.committedStreamIntent = request.source.intent
            self.reducer.commit(identity, deferInitialPublication: recipe.source.loadOptions?.decoderPolicy == .hardwareRequired)
            self.resumePlayback = request.options.autoplay
            self.didCommit?()
          }, didRollback: { self.didRollback?() }, completion: { result in
            completion(result.map { AppleLoadReply(loadRequestId: identity.loadRequestId,
              sessionId: identity.sessionId) }.mapError { $0 as Error })
          })
      } catch { completion(.failure(error)) }
    }
  }
  func play(command: AppleSessionCommand) async throws {
    try await onMain { completion in
      do {
        try self.session(command.sessionId)
        self.playbackIntentVersion &+= 1
        if self.suspended { self.resumePlayback = true; self.restoreOnResume = true; completion(.success(())); return }
        self.restore(forcePlay: true, completion: completion)
      } catch { completion(.failure(error)) }
    }
  }
  func pause(command: AppleSessionCommand) throws {
    try session(command.sessionId)
    try runSynchronous(.pause)
    playbackIntentVersion &+= 1
    resumePlayback = false
    reducer.projectPaused()
  }
  func seekTo(command: AppleSeekCommand) throws {
    try session(command.sessionId)
    guard command.positionMs >= 0, command.positionMs <= Int64.max / 1000 else { throw YlAppleFailureMapper.command(YlAppleFailureMapper.invalid()) }
    if let snapshot = reducer.state.snapshot, snapshot.engine == .managedFallback {
      do {
        try YlFallbackSeekPolicy(isSeekable: snapshot.isSeekable) { _ in }
          .seek(toUs: command.positionMs * 1_000)
      } catch {
        throw YlAppleFailureMapper.command(error)
      }
    }
    try runSynchronous(.seek(command.positionMs))
  }
  func seekToLiveEdge(command: AppleSessionCommand) async throws {
    try await perform(sessionId: command.sessionId, command: .liveEdge)
  }
  func setPlaybackSpeed(command: AppleSpeedCommand) throws {
    try session(command.sessionId)
    guard command.speed.isFinite, (0.25...4).contains(command.speed) else {
      throw YlAppleFailureMapper.command(YlAppleFailureMapper.invalid())
    }
    try runSynchronous(.speed(command.speed))
  }
  func selectAudioTrack(command: AppleTrackCommand) async throws {
    try await onMain { completion in
      do {
        try self.session(command.sessionId)
        guard !command.trackId.isEmpty else { throw YlAppleFailureMapper.invalid() }
        guard self.reducer.state.snapshot?.audioTracks.contains(where: { $0.id == command.trackId }) == true else {
          throw NativePlayerError(category: "source", code: "track.not_found", message: "The requested audio track is unavailable.")
        }
        self.coordinator.execute(.track(command.trackId)) { completion($0.mapError { $0 as Error }) }
      } catch { completion(.failure(error)) }
    }
  }
  func setVideoConstraints(command: AppleVideoConstraintsCommand) throws {
    try session(command.sessionId)
    do { try runSynchronous(.constraints(try YlAppleNativeInput.constraints(command.constraints))) }
    catch { throw YlAppleFailureMapper.command(error) }
  }
  func setVolume(volume: Double) throws {
    try alive()
    guard volume.isFinite, (0...1).contains(volume) else {
      throw YlAppleFailureMapper.command(YlAppleFailureMapper.invalid())
    }
    try runSynchronous(.volume(volume))
  }
  func stop() async throws {
    try await onMain { completion in
      do {
        try self.alive()
        self.restorationVersion &+= 1
        self.restoring = false
        self.stagedSnapshot = nil
        self.resumePlayback = false
        self.reducer.stop()
        self.coordinator.stop()
        completion(.success(()))
      } catch { completion(.failure(error)) }
    }
  }
  func dispose() async throws {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { self.close(); continuation.resume() }
    }
  }
  func close() {
    guard !disposed else { return }
    disposed = true
    restorationVersion &+= 1
    stagedSnapshot = nil
    outbound.close()
    coordinator.dispose()
    textureOwner.dispose()
    didDispose?()
  }
  func suspend() {
    guard !disposed, !suspended else { return }
    restoreOnResume = coordinator.isActive
    suspended = true
    restorationVersion &+= 1
    restoring = false
    stagedSnapshot = nil
    resumePlayback = coordinator.currentPlaybackIntent
    coordinator.deactivate()
    reducer.projectPaused()
  }
  func handleMemoryWarning() {
    guard !disposed else { return }
    restorationVersion &+= 1
    restoring = false
    stagedSnapshot = nil
    coordinator.handleMemoryWarning()
    reducer.projectPaused()
  }
  func cancelAutomaticResume() {
    resumePlayback = false
    try? coordinator.executeSynchronous(.pause)
  }
  func resume() {
    guard suspended, !disposed else { return }
    suspended = false
    let shouldRestore = restoreOnResume
    restoreOnResume = false
    guard shouldRestore, reducer.identity != nil else { return }
    restore(forcePlay: resumePlayback) { [weak self] result in
      if case .failure(let error) = result,
         (error as? NativePlayerError)?.code != "network.cancelled" {
        self?.reducer.fail(error as? NativePlayerError ?? YlAppleFailureMapper.invalid("platform.restoration_failed"))
      }
    }
  }
  func refreshState() { coordinator.emitState() }
  func deactivateForPeer() { coordinator.deactivate(); reducer.projectPaused() }
  func quiesce() { coordinator.quiesceForHardwareDecoderLease(); reducer.projectPaused() }
  func restorePeer() { coordinator.restoreAfterHardwareDecoderRollback() }

  private func restore(forcePlay: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let identity = reducer.identity else { completion(.failure(YlOpenCancellationToken.cancellationError())); return }
    restorationVersion &+= 1
    let version = restorationVersion
    let requestedIntentVersion = playbackIntentVersion
    restoring = true
    coordinator.beginActivation(forcePlay: forcePlay,
      willCommit: { self.willCommit?($0) }, didCommit: { self.didCommit?() },
      didRollback: { self.didRollback?() }, completion: { result in
        guard !self.disposed, !self.suspended, self.restorationVersion == version,
          self.reducer.identity == identity else {
          completion(.failure(YlOpenCancellationToken.cancellationError())); return
        }
        switch result {
        case .success:
          // A Pause accepted while preparation was held supersedes the captured
          // resume intent. Reconcile before releasing the staged public snapshot.
          func settlePlaybackIntent() {
            let acceptedVersion = self.playbackIntentVersion
            let shouldPlay = acceptedVersion == requestedIntentVersion ? forcePlay : self.resumePlayback
            self.coordinator.execute(shouldPlay ? .play : .pause) { result in
              guard !self.disposed, !self.suspended, self.restorationVersion == version,
                self.reducer.identity == identity else {
                completion(.failure(YlOpenCancellationToken.cancellationError())); return
              }
              guard self.playbackIntentVersion == acceptedVersion else {
                settlePlaybackIntent(); return
              }
              if case .success = result {
                self.resumePlayback = shouldPlay
                self.coordinator.emitState()
              }
              self.restoring = false
              if case .success = result, let staged = self.stagedSnapshot, staged.0 == identity {
                self.reducer.accept(staged.1, identity: identity)
              }
              self.stagedSnapshot = nil
              completion(result.mapError { $0 as Error })
            }
          }
          settlePlaybackIntent()
        case .failure(let error):
          self.restoring = false
          self.stagedSnapshot = nil
          completion(.failure(error))
        }
      })
  }
  private func receive(_ callback: YlNativeBackendCallback, identity: YlAppleSessionIdentity) {
    guard !disposed, reducer.identity == identity else { return }
    if case .failure = callback.event { coordinator.releaseAudioAfterFailure(identity: identity) }
    if restoring || suspended {
      if case .state = callback.event { stagedSnapshot = (identity, callback) }
      return
    }
    reducer.accept(callback, identity: identity)
  }
  private func alive() throws {
    if disposed { throw YlAppleFailureMapper.command(NativePlayerError(category: "resource",
      code: "player.disposed", message: "Player is disposed.")) }
  }
  private func session(_ sessionId: String) throws {
    try alive()
    guard !sessionId.isEmpty, reducer.identity?.sessionId == sessionId else {
      throw YlAppleFailureMapper.command(NativePlayerError(category: "cancelled",
        code: "session.stale", message: "Session is no longer current."))
    }
    guard reducer.state.failure == nil else {
      throw YlAppleFailureMapper.command(NativePlayerError(category: "resource", code: "session.failed", message: "Session has failed."))
    }
  }
  private func runSynchronous(_ command: YlApplePlaybackCommand) throws {
    do { try coordinator.executeSynchronous(command) }
    catch { throw YlAppleFailureMapper.command(error) }
  }
  private func perform(sessionId: String, command: YlApplePlaybackCommand) async throws {
    try await onMain { completion in
      do {
        try self.session(sessionId)
        if case .liveEdge = command {
          guard self.committedStreamIntent != .onDemand,
            self.committedStreamIntent == .live || self.reducer.state.snapshot?.isLive == true else {
            throw NativePlayerError(category: "source", code: "source.not_live", message: "The current source is not live.")
          }
        }
        self.coordinator.execute(command) { completion($0.mapError { $0 as Error }) }
      } catch { completion(.failure(error)) }
    }
  }
  private func onMain<T>(_ operation: @escaping (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
    do {
      return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.main.async { operation { continuation.resume(with: $0) } }
      }
    } catch { throw YlAppleFailureMapper.command(error) }
  }
}

enum YlAppleNativeInput {
  static func policyInt(_ value: Int64?, positive: Bool, required: Bool = false) throws {
    guard let value else {
      if required { throw YlAppleFailureMapper.invalid() }
      return
    }
    guard value >= (positive ? 1 : 0), value <= Int64(Int32.max) else {
      throw YlAppleFailureMapper.invalid()
    }
  }
  static func constraints(_ value: AppleVideoConstraintsMessage) throws -> YlAppleVideoConstraints {
    try [value.maxWidth, value.maxHeight, value.maxBitrate].forEach { try policyInt($0, positive: true) }
    return YlAppleVideoConstraints(maxWidth: value.maxWidth.map(Int.init),
      maxHeight: value.maxHeight.map(Int.init), maxBitrate: value.maxBitrate.map(Int.init))
  }
  static func load(source: AppleSourceMessage, options: AppleLoadOptionsMessage,
    defaults: ApplePlayerOptionsMessage, loadRequestId: String?) throws -> YlAppleLoadRecipe {
    let limits = try constraints(options.videoConstraints)
    if let position = options.startPositionMs, position < 0 || position > Int64.max / 1000 { throw YlAppleFailureMapper.invalid() }
    let buffer = options.bufferStrategy
    try policyInt(buffer.minDurationMs, positive: false, required: buffer.kind == .bounded)
    try policyInt(buffer.maxDurationMs, positive: false, required: buffer.kind == .bounded)
    try policyInt(buffer.maxManagedBytes, positive: true, required: buffer.kind == .bounded)
    if let low = buffer.minDurationMs, let high = buffer.maxDurationMs, low > high {
      throw YlAppleFailureMapper.invalid()
    }
    if let network = source.networkPolicy {
      try policyInt(network.connectTimeoutMs, positive: true, required: network.kind == .managed)
      try policyInt(network.readTimeoutMs, positive: true, required: network.kind == .managed)
      try policyInt(network.maxRetries, positive: false, required: network.kind == .managed)
      try policyInt(network.baseRetryDelayMs, positive: false, required: network.kind == .managed)
      try policyInt(network.maxRetryDelayMs, positive: false, required: network.kind == .managed)
      try policyInt(network.maxRedirects, positive: false, required: network.kind == .managed)
      if let low = network.baseRetryDelayMs, let high = network.maxRetryDelayMs, low > high {
        throw YlAppleFailureMapper.invalid()
      }
    }
    guard !source.locator.isEmpty,
      source.locator.rangeOfCharacter(from: .controlCharacters) == nil else { throw YlAppleFailureMapper.invalid() }
    let uri: String
    switch source.kind {
    case .file:
      guard source.locator.hasPrefix("/") else { throw YlAppleFailureMapper.invalid() }
      uri = URL(fileURLWithPath: source.locator).absoluteString
    case .network:
      guard let url = URLComponents(string: source.locator),
        ["http", "https"].contains(url.scheme), let host = url.host, !host.isEmpty,
        !host.contains(" "), url.user == nil, url.password == nil,
        url.port == nil || (1...65535).contains(url.port!) else { throw YlAppleFailureMapper.invalid() }
      uri = source.locator
    case .content: throw YlAppleFailureMapper.invalid("source.invalid")
    }
    let request = source.request
    let headers = request?.headers ?? [:]
    let credentials = request?.credentials ?? [:]
    var seen = Set<String>()
    for (values, isCredential) in [(headers, false), (credentials, true)] {
      for (name, value) in values {
        let lower = name.lowercased()
        guard name.range(of: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", options: .regularExpression) != nil,
          value.range(of: "[\\x00-\\x08\\x0a-\\x1f\\x7f]", options: .regularExpression) == nil,
          !["host", "content-length", "connection", "transfer-encoding", "range", "if-range"].contains(lower),
          seen.insert(lower).inserted,
          isCredential || lower.range(of: "auth|cookie|token|key|secret|credential", options: .regularExpression) == nil else {
          throw YlAppleFailureMapper.invalid()
        }
      }
    }
    let format: YlSourceFormat
    switch source.format {
    case .automatic: format = .automatic
    case .hls: format = .hls
    case .mp4: format = .mp4
    case .mov: format = .mov
    case .matroska: format = .matroska
    case .webm: format = .webm
    case .mpegTs: format = .mpegTs
    case .mpegPs: format = .mpegPs
    case .flv: format = .flv
    case .avi: format = .avi
    }
    let strategy: YlBufferGoal
    switch buffer.kind {
    case .automatic: strategy = .automatic
    case .lowLatency: strategy = .lowLatency
    case .smoothPlayback: strategy = .smoothPlayback
    case .bounded: strategy = .bounded
    }
    let decoder: YlDecoderPolicy
    switch options.decoderPolicyOverride ?? defaults.decoderPolicy {
    case .systemDefault: decoder = .systemDefault
    case .hardwarePreferred: decoder = .hardwarePreferred
    case .hardwareRequired: decoder = .hardwareRequired
    }
    let intent: YlSourceIntent
    switch source.intent {
    case .automatic: intent = .automatic
    case .onDemand: intent = .onDemand
    case .live: intent = .live
    }
    return YlAppleLoadRecipe(source: YlAppleSourceDescriptor(uri: uri,
      kind: source.kind == .file ? .file : .network, formatHint: format, intent: intent,
      headers: headers, credentials: credentials,
      networkPolicy: source.networkPolicy?.kind == .managed ? .managed : .platformDefault,
      networkConfiguration: source.networkPolicy.map { network in
        YlAppleNetworkOptions(connectTimeoutMs: network.connectTimeoutMs ?? 10_000,
          readTimeoutMs: network.readTimeoutMs ?? 15_000, maxRetries: Int(network.maxRetries ?? 3),
          baseRetryDelayMs: network.baseRetryDelayMs ?? 500,
          maxRetryDelayMs: network.maxRetryDelayMs ?? 8_000, maxRedirects: Int(network.maxRedirects ?? 5))
      },
      loadOptions: YlAppleLoadOptions(autoplay: options.autoplay,
        startPositionMs: options.startPositionMs, bufferStrategy: strategy,
        minDurationMs: buffer.minDurationMs, maxDurationMs: buffer.maxDurationMs,
        maxManagedBytes: buffer.maxManagedBytes.map(Int.init), videoConstraints: limits, decoderPolicy: decoder),
      loadRequestId: loadRequestId))
  }
}

extension YlApplePlayerHost {
  static func engine(_ engine: YlNativeEngine?) -> AppleEngine {
    switch engine {
    case .avPlayer: .avPlayer
    case .managedFallback: .managedFallback
    case nil: .unknown
    }
  }
  func encode(_ state: YlAppleReducedState) -> AppleStateMessage {
    let value = state.snapshot
    let status: ApplePlaybackStatus
    if state.failure != nil { status = .failed }
    else if state.identity == nil { status = .idle }
    else {
      switch value?.status {
      case "ready": status = .ready
      case "playing": status = .playing
      case "paused": status = .paused
      case "buffering": status = .buffering
      case "completed": status = .completed
      case "error": status = .failed
      default: status = .loading
      }
    }
    var window: AppleDvrWindowMessage?
    if let start = value?.dvrStartMs, let end = value?.dvrEndMs, start >= 0, end >= start {
      window = AppleDvrWindowMessage(startMs: start, endMs: end)
    }
    return AppleStateMessage(loadRequestId: state.identity?.loadRequestId,
      sessionId: state.identity?.sessionId, revision: state.revision, sequence: state.sequence,
      status: status, timeline: AppleTimelineMessage(positionMs: max(0, value?.positionMs ?? 0),
        durationMs: value?.durationMs.map { max(0, $0) },
        bufferedPositionMs: max(0, value?.bufferedPositionMs ?? 0),
        isSeekable: value?.isSeekable ?? false, isLive: value?.isLive ?? false,
        isAtLiveEdge: value?.isLive == true ? value?.isAtLiveEdge : nil,
        liveOffsetMs: YlAppleTimeline.liveOffset(value?.liveOffsetMs), dvrWindow: window),
      geometry: value?.geometry?.message, audioTracks: value?.audioTracks.map(Self.track) ?? [],
      videoTracks: value?.videoTracks.map(Self.track) ?? [], engine: Self.engine(value?.engine),
      decoderMode: YlMetricsCollector.decoderMode(state: value),
      decoderIdentity: value?.decoderName, metrics: Self.metrics(value?.metrics ?? .init()),
      failure: state.failure.map { YlAppleFailureMapper.message($0, scope: .session) })
  }
  static func track(_ value: YlNativeTrack) -> AppleTrackMessage {
    AppleTrackMessage(id: value.id, kind: value.kind == .audio ? .audio : .video,
      label: value.label, language: value.language, codec: value.codec,
      bitrate: value.bitrate.map(Int64.init), width: value.width.map(Int64.init),
      height: value.height.map(Int64.init), isSelected: value.isSelected)
  }
  static func metrics(_ value: YlNativeMetrics) -> AppleMetricsMessage {
    AppleMetricsMessage(loadToReadyMs: value.openDurationMs,
      loadToFirstFrameMs: value.firstFrameDurationMs,
      rebufferCount: value.rebufferCount.map(Int64.init), rebufferDurationMs: value.rebufferDurationMs,
      droppedVideoFrames: value.droppedVideoFrames.map(Int64.init),
      audioUnderruns: value.audioUnderruns.map(Int64.init),
      managedBufferedDurationMs: value.bufferedDurationMs,
      managedBufferedBytes: value.bufferedBytes.map(Int64.init),
      liveOffsetMs: YlAppleTimeline.liveOffset(value.liveOffsetMs), reconnectCount: value.reconnectCount.map(Int64.init))
  }
  func send(_ output: YlAppleReducerOutput) {
    guard attached, !disposed else { return }
    let call: () async throws -> Void
    switch output {
    case .state(let value):
      let state = encode(value)
      call = { [callbacks] in try await callbacks.onState(state: state) }
    case let .delta(meta, previous, value):
      let m = Self.metrics(value.metrics)
      let delta = AppleStateDeltaMessage(sessionId: meta.identity.sessionId,
        previousRevision: previous, revision: meta.revision, sequence: meta.sequence,
        positionMs: max(0, value.positionMs), bufferedPositionMs: max(0, value.bufferedPositionMs),
        hasIsAtLiveEdge: true, isAtLiveEdge: value.isAtLiveEdge,
        hasLiveOffsetMs: true, liveOffsetMs: YlAppleTimeline.liveOffset(value.liveOffsetMs),
        metrics: AppleMetricsDeltaMessage(hasLoadToReadyMs: true, loadToReadyMs: m.loadToReadyMs,
          hasLoadToFirstFrameMs: true, loadToFirstFrameMs: m.loadToFirstFrameMs,
          hasRebufferCount: true, rebufferCount: m.rebufferCount,
          hasRebufferDurationMs: true, rebufferDurationMs: m.rebufferDurationMs,
          hasDroppedVideoFrames: true, droppedVideoFrames: m.droppedVideoFrames,
          hasAudioUnderruns: true, audioUnderruns: m.audioUnderruns,
          hasEstimatedBitrate: false, hasManagedBufferedDurationMs: true,
          managedBufferedDurationMs: m.managedBufferedDurationMs,
          hasManagedBufferedBytes: true, managedBufferedBytes: m.managedBufferedBytes,
          hasLiveOffsetMs: true, liveOffsetMs: m.liveOffsetMs,
          hasReconnectCount: true, reconnectCount: m.reconnectCount))
      call = { [callbacks] in try await callbacks.onStateDelta(delta: delta) }
    case .firstFrame(let m):
      let event = AppleFirstFrameMessage(sessionId: m.identity.sessionId,
        revision: m.revision, sequence: m.sequence, occurredAtMs: m.occurredAtMs)
      call = { [callbacks] in try await callbacks.onFirstFrame(event: event) }
    case let .retry(m, attempt, delay, error):
      let event = AppleRetryScheduledMessage(sessionId: m.identity.sessionId, revision: m.revision,
        sequence: m.sequence, occurredAtMs: m.occurredAtMs, retryIndex: Int64(attempt),
        delayMs: delay, failure: YlAppleFailureMapper.message(error, scope: .session))
      call = { [callbacks] in try await callbacks.onRetryScheduled(event: event) }
    case let .engineChanged(m, previous, current):
      let event = AppleEngineChangedMessage(sessionId: m.identity.sessionId,
        revision: m.revision, sequence: m.sequence, occurredAtMs: m.occurredAtMs,
        previousEngine: Self.engine(previous), engine: Self.engine(current))
      call = { [callbacks] in try await callbacks.onEngineChanged(event: event) }
    case let .failed(m, error):
      let event = ApplePlaybackFailedMessage(sessionId: m.identity.sessionId,
        revision: m.revision, sequence: m.sequence, occurredAtMs: m.occurredAtMs,
        failure: YlAppleFailureMapper.message(error, scope: .session))
      call = { [callbacks] in try await callbacks.onPlaybackFailed(event: event) }
    }
    outbound.enqueue(call)
  }
}

/// Distinct Pigeon callback channels share one acknowledged FIFO and deadline.
final class YlAppleOutboundQueue {
  private var pending: [() async throws -> Void] = []
  private var sending = false
  private var closed = false
  private var token: UInt64 = 0
  private var timeout: DispatchWorkItem?
  private var task: Task<Void, Never>?
  private let acknowledgementTimeout: TimeInterval
  var onFailure: (() -> Void)?
  init(acknowledgementTimeout: TimeInterval = 5) { self.acknowledgementTimeout = acknowledgementTimeout }
  func enqueue(_ call: @escaping () async throws -> Void) {
    guard !closed else { return }
    guard pending.count < 128 else { fail(); return }
    pending.append(call)
    pump()
  }
  private func pump() {
    guard !closed, !sending, !pending.isEmpty else { return }
    sending = true
    token &+= 1
    let expected = token
    let call = pending.removeFirst()
    let timer = DispatchWorkItem { [weak self] in
      guard let self, self.sending, self.token == expected else { return }
      self.fail()
    }
    timeout = timer
    DispatchQueue.main.asyncAfter(deadline: .now() + acknowledgementTimeout, execute: timer)
    task = Task { @MainActor [weak self] in
      do {
        try await call()
        guard let self, !self.closed, self.token == expected else { return }
        self.timeout?.cancel()
        self.sending = false
        self.task = nil
        self.pump()
      } catch { self?.fail() }
    }
  }
  private func fail() { guard !closed else { return }; close(); onFailure?() }
  func close() {
    guard !closed else { return }
    closed = true
    pending.removeAll()
    timeout?.cancel()
    timeout = nil
    task?.cancel()
    task = nil
  }
}
