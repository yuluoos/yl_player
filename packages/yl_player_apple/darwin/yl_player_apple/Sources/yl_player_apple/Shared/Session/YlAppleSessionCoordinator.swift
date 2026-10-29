import yl_player_media_core
import AVFoundation
import CoreVideo
import Foundation
import YlFFmpegBridge
#if os(iOS)
import UIKit
#endif

final class YlAppleSessionCoordinator: NSObject {
  private final class PreparedRestorationRevision {
    var value: UInt64
    init(_ value: UInt64) { self.value = value }
  }

  private struct DeferredRestorationCommand {
    let command: YlApplePlaybackCommand
    let completion: (Result<Void, NativePlayerError>) -> Void
  }

  var drmBridge: YlFairPlayBridge?
  var protectedSurface: AppleProtectedSurfaceMessage? {
    (slot.current as? YlFairPlayBackend)?.record.identity.message
  }
  func cancelProtectedLoad(_ requestId: String) {
    if pendingLoadRequestId == requestId { openCoordinator.cancelCurrent() }
  }

  let playerId: Int64
  var textureId: Int64 { services.textureOutput.textureId }
  var isActive: Bool { slot.current.isActive }
  var onAirPlayChanged: (() -> Void)?
  var airPlayEnabled: Bool { identity != nil && slot.current === avBackend && avBackend.airPlayEnabled }
  var airPlayActive: Bool { airPlayEnabled && avBackend.airPlayActive }
  var airPlayPlayer: AVPlayer? { airPlayEnabled ? avBackend.airPlayPlayer : nil }

  func setExternalPlaybackActive(_ active: Bool) {
    #if os(iOS)
    avBackend.airPlayPlayer.audiovisualBackgroundPlaybackPolicy = active ? .continuesIfPossible : .automatic
    #endif
  }

  private let services: YlPlatformServices
  private let audioOwnership: YlPlayerAudioOwnership?
  private var audioToken: UUID?
  private let textureOwner: YlAppleTextureOwner
  private let avTexture: YlAppleAvTextureBinding
  private var activeTexture: YlAppleTextureLease?
  private let videoSessionFactory: YlVTSessionFactory?
  private let audioRendererFactory: any YlAudioRendererMaking
  private let audioTerminalCandidateEnabled: Bool
  private let hardwareEvidenceStage: YlHardwareEvidencePreparation
  private let bufferLedger: YlManagedBufferLedger
  private let configuration: PlayerConfiguration
  private let emit: (YlAppleSessionIdentity, YlNativeBackendCallback) -> Void
  private let avBackend: YlAvPlayerBackend
  private let slot: YlBackendSlot
  private let openCoordinator = YlOpenCoordinator()
  private let dashRecovery: YlDashAutoRecoveryController
  private var dashRecoveryTimer: Timer?
  private var dashRecoveryObserver: NSObjectProtocol?
  private var dashRecoveryRevision: UInt64 = 0
  var diagnosticProxySnapshot: [String: Double] { avBackend.diagnosticProxySnapshot }
  var diagnosticResumeSeekPending: Bool { avBackend.diagnosticResumeSeekPending }
  var onDashRecoveryEvent: (([String: Any]) -> Void)? {
    get { dashRecovery.onEvent }
    set { dashRecovery.onEvent = newValue }
  }
  var onDashRecoveryDecision: (([String: Any]) -> Void)? {
    get { dashRecovery.onDecision }
    set { dashRecovery.onDecision = newValue }
  }
  var dashRecoveryDecision: [String: Any] { dashRecovery.policy.decision }
  var dashRecoveryEvents: [[String: Any]] { dashRecovery.events }
  var dashRecoveryAttempts: Int { dashRecovery.policy.attempts }
  private let capsCoordinator = YlOpenCoordinator(label: "dev.ylplayer.dash.caps")
  private let afterDashRecoveryPreparation: ((YlOpenCancellationToken) -> Void)?
  private let beforeDashCapsPreparation: ((YlOpenCancellationToken) throws -> Void)?
  private var committedDashSnapshot: YlDashManifestSnapshot?
  private let commandCoordinator: YlAsyncCommandCoordinator
  private let beforeFallbackConstruction: ((YlPlaybackBackend) throws -> Void)?
  private var lastCommittedSource: YlAppleSourceDescriptor?
  private var committedHlsCredentials: YlHlsCredentialContext?
  private(set) var lastQualityConstraint = YlAppleVideoConstraints.unconstrained
  private var synchronousIntentRevision: UInt64 = 0
  private var restorationIntentRevision: UInt64 = 0
  /// Monotonic authority for acknowledged transport/track intents within this owner.
  var acknowledgedTransportRevision: UInt64 { restorationIntentRevision }
  private var pendingSeekIntent: (revision: UInt64, positionMs: Int64)?
  private var pendingPauseIntent: UInt64?
  private var lastVolume: Float = 1
  private var lastPlaybackSpeed: Float = 1
  var onNetworkBytesReceived: ((String, Int64?) -> Void)?
  private var trafficTimer: Timer?
  private var trafficSource: YlAppleSourceDescriptor?
  private func startTraffic(_ source: YlAppleSourceDescriptor) {
    trafficTimer?.invalidate()
    trafficSource = source
    trafficTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let self, !self.disposed, let source = self.trafficSource,
            let requestId = source.loadRequestId else { return }
      let committed = self.identity?.loadRequestId == requestId && self.pendingLoadRequestId == nil
      let bytes = committed && self.slot.current === self.avBackend
        ? self.avBackend.networkBytesReceived : source.bufferScope?.networkBytesReceived
      self.onNetworkBytesReceived?(requestId, bytes)
      // Wall time is required while AVPlayer is loading/paused and its media
      // time observer does not advance. Existing backend snapshots stay fenced.
      if committed { self.slot.current.emitState() }
    }
  }
  private func stopTraffic() {
    trafficTimer?.invalidate(); trafficTimer = nil; trafficSource = nil
  }
  private var pendingLoadRequestId: String?
  private(set) var identity: YlAppleSessionIdentity?
  private var activeEvents: YlAppleCommitEmitter?
  private var disposed = false
  private var hardwareRollbackPlaybackIntent: Bool?
  private var restorationGeneration: UInt64 = 0
  private var activeRestorationGeneration: UInt64?
  private var deferredRestorationCommands = [DeferredRestorationCommand]()

  init(playerId: Int64, services: YlPlatformServices,
       configuration: PlayerConfiguration, textureOwner: YlAppleTextureOwner, avPlayer: AVPlayer = AVPlayer(),
       commandCoordinator: YlAsyncCommandCoordinator = YlAsyncCommandCoordinator(),
       automaticDashRecoveryEnabled: Bool = true,
       dashRecoveryController: YlDashAutoRecoveryController = YlDashAutoRecoveryController(),
       afterDashRecoveryPreparation: ((YlOpenCancellationToken) -> Void)? = nil,
       beforeDashCapsPreparation: ((YlOpenCancellationToken) throws -> Void)? = nil,
       makeAvPlayerVideoOutput: @escaping ([String: Any]) -> AVPlayerItemVideoOutput = { AVPlayerItemVideoOutput(pixelBufferAttributes: $0) },
       beforeFallbackConstruction: ((YlPlaybackBackend) throws -> Void)? = nil,
       slotCompatibility: YlAppleCompatibility? = nil,
       bufferLedger: YlManagedBufferLedger = YlManagedBufferLedger(),
       videoSessionFactory: YlVTSessionFactory? = nil,
       audioRendererFactory: any YlAudioRendererMaking = YlPlatformAudioRendererFactory(),
       audioTerminalCandidateEnabled: Bool = false,
       hardwareEvidenceStage: YlHardwareEvidencePreparation = .init(),
       audioOwnership: YlPlayerAudioOwnership? = nil,
       emit: @escaping (YlAppleSessionIdentity, YlNativeBackendCallback) -> Void) {
    self.dashRecovery = dashRecoveryController
    self.afterDashRecoveryPreparation = afterDashRecoveryPreparation
    self.beforeDashCapsPreparation = beforeDashCapsPreparation
    self.audioOwnership = audioOwnership
    self.videoSessionFactory = videoSessionFactory
    self.audioRendererFactory = audioRendererFactory
    self.audioTerminalCandidateEnabled = audioTerminalCandidateEnabled
    self.hardwareEvidenceStage = hardwareEvidenceStage
    self.bufferLedger = bufferLedger
    self.commandCoordinator = commandCoordinator
    self.beforeFallbackConstruction = beforeFallbackConstruction
    self.playerId = playerId
    self.services = services
    self.textureOwner = textureOwner
    let avTexture = YlAppleAvTextureBinding(textureId: services.textureOutput.textureId)
    self.avTexture = avTexture
    self.configuration = configuration
    self.emit = emit
    let avBackend = YlAvPlayerBackend(playerId: playerId, services: services.borrowing(avTexture),
      configuration: configuration, player: avPlayer, makeVideoOutput: makeAvPlayerVideoOutput, emit: { _ in })
    self.avBackend = avBackend
    self.slot = YlBackendSlot(initial: avBackend, compatibility: slotCompatibility ?? services.compatibility)
    super.init()
    avBackend.onAirPlayChanged = { [weak self] in self?.onAirPlayChanged?() }
    avBackend.onAutomaticFallback = { [weak self] in self?.capsCoordinator.cancelCurrent(); self?.invalidateDashRecovery() }
    avBackend.onDashRecoveryInvalidated = { [weak self] in self?.invalidateDashRecovery() }
    #if os(iOS)
    if services.platform == .ios && automaticDashRecoveryEnabled {
      let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.pollDashRecovery() }
      RunLoop.main.add(timer, forMode: .common); dashRecoveryTimer = timer
      dashRecoveryObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
        object: nil, queue: .main) { [weak self] _ in self?.invalidateDashRecovery() }
    }
    #endif
  }

  func load(_ recipe: YlAppleLoadRecipe, identity: YlAppleSessionIdentity,
    willCommit: @escaping (Bool) -> Void, didCommit: @escaping () -> Void,
    didRollback: @escaping () -> Void,
    completion: @escaping (Result<Void, NativePlayerError>) -> Void) {
    let assessment = YlEngineRouter.assess(recipe.source)
    if let rejection = assessment.rejection { completion(.failure(rejection)); return }
    var source = recipe.source
    do {
      if source.loadOptions?.bufferStrategy == .bounded {
        guard let options = source.loadOptions, let low = options.minDurationMs,
              let high = options.maxDurationMs, let bytes = options.maxManagedBytes else {
          throw YlManagedBufferLedger.unsupported()
        }
        source.boundedPlan = try YlBoundedBufferPlan(minDurationMs: low, maxDurationMs: high, maxBytes: bytes)
      }
      source.bufferScope = try bufferLedger.makeScope(maxBytes: source.boundedPlan?.maxBytes)
    } catch let error as NativePlayerError { completion(.failure(error)); return }
    catch { completion(.failure(YlManagedBufferLedger.unsupported())); return }
    invalidateDashRecovery()
    startTraffic(source)
    beginOpen(source, decision: assessment, identity: identity, willCommit: willCommit,
      didCommit: didCommit, didRollback: didRollback, completion: completion)
  }

  var acceptedVideoConstraints: YlAppleVideoConstraints {
    lastQualityConstraint
  }

  func setLivePlaybackMode(_ mode: YlNativeLiveMode, requestId: Int64,
    validate: @escaping () throws -> Void,
    willCommit: @escaping (Bool) -> Void, didCommit: @escaping () -> Void,
    didRollback: @escaping () -> Void,
    commit publish: @escaping (YlNativeLivePlayback, YlNativeState?) throws -> Void,
    completion: @escaping (Result<Void, NativePlayerError>) -> Void) {
    let expectedIdentity = identity
    commandCoordinator.begin(operation: { [weak self] token in
      guard let self else { throw YlOpenCancellationToken.cancellationError() }
      var fallback: YlFallbackBackend?
      var source: YlAppleSourceDescriptor?
      var original: YlPlaybackBackend?
      try DispatchQueue.main.sync {
        try token.throwIfCancelled(); try validate()
        guard !self.disposed, self.identity == expectedIdentity, self.slot.current.isActive,
              self.pendingLoadRequestId == nil, self.activeRestorationGeneration == nil else {
          throw YlOpenCancellationToken.cancellationError()
        }
        original = self.slot.current
        if let current = self.slot.current as? YlFallbackBackend,
           current.livePlaybackState?.mode != mode {
          fallback = current
          source = self.lastCommittedSource
          if let intent = source?.managedRequestIntent {
            guard intent.terminalFailure == nil else { throw YlNativeLivePlayback.unsupported }
            source?.managedRequestIntent = intent.candidate()
          }
          guard source?.boundedPlan == nil else { throw YlNativeLivePlayback.unsupported }
          source?.loadOptions?.bufferStrategy = mode == .lowLatency ? .lowLatency : .smoothPlayback
          source?.livePlaybackRequestId = requestId
        } else {
          let value = try self.slot.current.setLivePlaybackMode(mode, requestId: requestId)
          self.lastCommittedSource?.loadOptions?.bufferStrategy = mode == .lowLatency ? .lowLatency : .smoothPlayback
          self.lastCommittedSource?.livePlaybackRequestId = requestId
          try publish(value, nil)
        }
      }
      guard let fallback, let source, let expectedIdentity else { return }
      let prepare = {
        // A rejected candidate releases its own input without changing command intent.
        try self.prepareFallback(source: source, token: token.makeChild(), identity: expectedIdentity, reactivating: true)
      }
      let prepared = try ["rtmp", "rtmps"].contains(source.url?.scheme?.lowercased() ?? "")
        ? source.rtmpRecovery.prepareRestoration(token: token, work: prepare) : prepare()
      defer { prepared.discard() }
      // Candidates remain silent until the complete policy/resource transaction commits.
      var selectedAudio: Int32?
      try DispatchQueue.main.sync {
        try token.throwIfCancelled(); try validate()
        guard self.slot.current === original, self.identity == expectedIdentity else { throw YlOpenCancellationToken.cancellationError() }
        selectedAudio = fallback.reactivationState(forcePlay: false).selectedAudioStreamIndex
      }
      try prepared.prepareForReactivation(.init(positionUs: 0, selectedAudioStreamIndex: selectedAudio, shouldPlay: false))
      try DispatchQueue.main.sync {
        try token.throwIfCancelled(); try validate()
        guard !self.disposed, self.slot.current === original, self.identity == expectedIdentity,
          fallback.isActive, self.pendingLoadRequestId == nil else { throw YlOpenCancellationToken.cancellationError() }
        let shouldPlay = self.currentPlaybackIntent
        let continuity = fallback.liveRecoveryContinuity
        willCommit(true)
        do {
          try self.commit(.fallback(source: source, prepared: prepared), identity: expectedIdentity,
            reactivating: true, cancelCommands: false)
        } catch {
          didRollback()
          if self.slot.takeRollbackRequiresExternalActivation() {
            self.slot.current.stop()
            self.emit(.init(sessionId: expectedIdentity.sessionId, loadRequestId: expectedIdentity.loadRequestId,
              startedAtMs: expectedIdentity.startedAtMs), .init(generation: 0, event: .failure(Self.commandError(error))))
          }
          throw error
        }
        didCommit()
        guard let installed = self.slot.current as? YlFallbackBackend else { throw YlNativeLivePlayback.unsupported }
        installed.retainLiveRecoveryContinuity(continuity)
        do {
          // A silent candidate starts ready. Commit the retained pause intent
          // as well as play intent before publishing this mode transaction.
          if shouldPlay { try installed.play() } else { try installed.pause() }
          let value = try installed.setLivePlaybackMode(mode, requestId: requestId)
          installed.emitState()
          guard let current = self.activeEvents?.takeInitialSnapshot() else {
            throw YlAppleFailureMapper.invalid("protocol.mismatch")
          }
          try publish(value, current)
          self.activeEvents?.commit()
          if let texture = self.activeTexture { self.textureOwner.commit(texture) }
        } catch {
          installed.stop()
          self.emit(expectedIdentity, .init(generation: 0, event: .failure(Self.commandError(error))))
          throw error
        }
      }
    }, completion: completion)
  }

  func validateTimeSeek() throws {
    if ["rtmp", "rtmps"].contains(lastCommittedSource?.url?.scheme?.lowercased() ?? "") {
      throw ylRtmpError("policy.unsupported")
    }
  }

  func execute(_ command: YlApplePlaybackCommand,
    completion: @escaping (Result<Void, NativePlayerError>) -> Void) {
    invalidateDashRecovery()
    let policy: (YlAppleVideoConstraints, YlNativeVideoSelection)?
    switch command {
    case .constraints(let constraints): policy = (constraints, avBackend.videoSelection)
    case .videoTrack(let id): policy = (lastQualityConstraint, .init(fixedTrackId: id, reason: "user"))
    default: policy = nil
    }
    if let (constraints, selection) = policy, !(slot.current is YlDashProgramBackend) {
      capsCoordinator.cancelCurrent()
      if let source = lastCommittedSource, route(for: source) == .dashHls {
        do {
          _ = try YlFallbackQualityConstraint(validating: constraints)
          guard pendingLoadRequestId == nil else { throw YlOpenCancellationToken.cancellationError() }
          if constraints == lastQualityConstraint && selection.fixedTrackId == avBackend.videoSelection.fixedTrackId {
            if case .videoTrack = command { avBackend.acceptVideoSelection(selection) }
            completion(.success(())); return
          }
          guard slot.current === avBackend, avBackend.isActive, activeRestorationGeneration == nil,
                let snapshot = committedDashSnapshot, let credentials = committedHlsCredentials,
                let identity else {
            if case .constraints = command { throw YlAppleVideoConstraints.reloadRequired }
            throw YlNativeVideoSelection.unsupported
          }
          guard pendingLoadRequestId == nil else { throw YlOpenCancellationToken.cancellationError() }
          if case .videoTrack(let id) = command, let id {
            guard avBackend.confirmedVideoTracks.contains(where: { $0.id == id }) else {
              throw YlNativeVideoSelection.unsupported
            }
          }
          capsCoordinator.begin(prepare: { [weak self] token in
            guard let self else { throw YlOpenCancellationToken.cancellationError() }
            try self.beforeDashCapsPreparation?(token)
            try token.throwIfCancelled()
            return .headeredHls(source: source, prepared: try self.prepareHeaderedHls(
              source: source, token: token, credentialContext: credentials,
              videoConstraints: constraints, dashSnapshot: snapshot, fixedTrackId: selection.fixedTrackId))
          }, commit: { [weak self] candidate in
            guard let self, !self.disposed, self.identity == identity,
                  self.pendingLoadRequestId == nil, self.slot.current === self.avBackend,
                  self.avBackend.isActive, self.activeRestorationGeneration == nil,
                  case let .headeredHls(_, prepared) = candidate else {
              throw YlOpenCancellationToken.cancellationError()
            }
            try self.avBackend.replaceActiveDash(source: source, prepared: prepared, selection: selection)
            self.lastQualityConstraint = constraints
          }, completion: completion)
        } catch let error as NativePlayerError { completion(.failure(error)) }
        catch { completion(.failure(Self.commandError(error))) }
        return
      }
      if case .videoTrack = command { completion(.failure(YlNativeVideoSelection.unsupported)); return }
    }
    if case .constraints(let constraints) = command, let fallback = slot.current as? YlFallbackBackend {
      do { try fallback.validateQualityConstraint(YlFallbackQualityConstraint(validating: constraints)) }
      catch let error as NativePlayerError { completion(.failure(error)); return }
      catch { completion(.failure(Self.commandError(error))); return }
    }
    beginCommand(command) { [weak self] result in
      if case .success = result {
        if case .track = command { self?.restorationIntentRevision &+= 1 }
        if case .constraints(let constraints) = command { self?.lastQualityConstraint = constraints }
      }
      completion(result)
    }
  }

  /// Synchronous transport methods acknowledge validated intent here. Queued
  /// effects may be cancelled with their backend; acknowledged intent cannot be.
  func executeSynchronous(_ command: YlApplePlaybackCommand) throws {
    // Reject source policy before acknowledging or retaining a restoration intent.
    if case .seek = command { try validateTimeSeek() }
    let revision = synchronousIntentRevision &+ 1
    var immediate: Result<Void, NativePlayerError>?
    execute(command) { [weak self] result in
      immediate = result
      guard case .success = result, let self else { return }
      if self.pendingSeekIntent?.revision == revision { self.pendingSeekIntent = nil }
      if self.pendingPauseIntent == revision { self.pendingPauseIntent = nil }
    }
    if case let .failure(error) = immediate { throw error }
    synchronousIntentRevision = revision
    switch command {
    case let .volume(volume): lastVolume = Float(volume)
    case let .speed(speed): lastPlaybackSpeed = Float(speed)
    case .constraints: break
    case let .seek(position):
      restorationIntentRevision &+= 1
      pendingSeekIntent = immediate == nil ? (revision, position) : nil
    case .pause:
      restorationIntentRevision &+= 1
      pendingPauseIntent = immediate == nil ? revision : nil
      if hardwareRollbackPlaybackIntent != nil { hardwareRollbackPlaybackIntent = false }
    default: break
    }
  }

  private func reactivationState(_ fallback: YlFallbackBackend, forcePlay: Bool) -> YlFallbackResumeState {
    let state = fallback.reactivationState(forcePlay: forcePlay)
    return YlFallbackResumeState(
      positionUs: pendingSeekIntent.map { $0.positionMs * 1_000 } ?? state.positionUs,
      selectedAudioStreamIndex: state.selectedAudioStreamIndex,
      shouldPlay: forcePlay || (pendingPauseIntent == nil && state.shouldPlay)
    )
  }

  func stop() {
    invalidateDashRecovery()
      stopTraffic()
      capsCoordinator.cancelCurrent()
      commandCoordinator.cancelCurrent()
      openCoordinator.cancelCurrent()
      restorationGeneration &+= 1
      activeRestorationGeneration = nil
      hardwareRollbackPlaybackIntent = nil
      cancelDeferredRestorationCommands()
      activeEvents?.invalidate()
      activeEvents = nil
      lastCommittedSource = nil
      committedHlsCredentials = nil
      committedDashSnapshot = nil
      pendingSeekIntent = nil
      pendingPauseIntent = nil
      lastQualityConstraint = .unconstrained
      // The persistent AV backend may hold an older source while fallback is current.
      if slot.current !== avBackend { avBackend.clearMediaForStop() }
      slot.stop()

    audioOwnership?.stop()
    audioToken = nil
    identity = nil
    activeTexture?.dispose()
    activeTexture = nil
    textureOwner.stop()
  }

  private func beginOpen(
    _ source: YlAppleSourceDescriptor,
    decision: YlSourceAssessment,
    identity: YlAppleSessionIdentity,
    willCommit: @escaping (Bool) -> Void,
    didCommit: @escaping () -> Void,
    didRollback: @escaping () -> Void,
    completion: @escaping (Result<Void, NativePlayerError>) -> Void
  ) {
    guard !disposed else {
      completion(.failure(NativePlayerError(
        category: "resource",
        code: "\(YlApplePlatform.current.rawValue).player_disposed",
        message: "The Apple player has been disposed."
      )))
      return
    }
    restorationGeneration &+= 1
    activeRestorationGeneration = nil
    cancelDeferredRestorationCommands()
    capsCoordinator.cancelCurrent()
    // A candidate owns fresh provenance; failed/cancelled work never writes the
    // surviving session's context or a later user Load's context.
    let hlsCredentials = YlHlsCredentialContext()
    let loadConstraints = source.loadOptions?.videoConstraints ?? lastQualityConstraint
    let requestedLoadRequestId = identity.loadRequestId
    pendingLoadRequestId = requestedLoadRequestId
    var openGeneration: UInt64 = 0
    openGeneration = openCoordinator.begin(
      prepare: { [weak self] token in
        guard let self else { throw YlOpenCancellationToken.cancellationError() }
        try token.throwIfCancelled()
        switch decision.candidate {
        case .fairPlay:
          guard let bridge = self.drmBridge else { throw YlFairPlayFailure.error("drm.unsupported") }
          return .fairPlay(source: source, backend: try YlFairPlayBackend.prepare(source: source,
            identity: identity, bridge: bridge, token: token, emit: self.emit))
        case .avPlayer:
          if source.airPlay { return try self.prepareAirPlay(source, token: token) }
          return try self.prepareNativeOrMp4(source: source, token: token, identity: identity)
        case .localMatroska, .networkMatroska, .networkFlv, .networkRtmp, .transportStream, .programStream, .progressiveMp4, .avi:
          return .fallback(
            source: source,
            prepared: try self.prepareFallback(source: source, token: token, identity: identity)
          )
        case .dashHls, .dashProgram:
          return try self.prepareDash(source: source, token: token, credentials: hlsCredentials, constraints: loadConstraints)
        case .headeredHls:
          return .headeredHls(
            source: source,
            prepared: try self.prepareHeaderedHls(source: source, token: token, credentialContext: hlsCredentials, videoConstraints: loadConstraints)
          )
        case .inspect:
          let inspected = try YlSourceInspector.inspect(source, configuration: self.configuration.network, token: token)
          let refined = YlEngineRouter.assess(inspected)
          if let error = refined.rejection { throw error }
          switch refined.candidate {
          case .avPlayer: return try self.prepareNativeOrMp4(source: inspected, token: token, identity: identity)
          case .dashHls, .dashProgram:
            return try self.prepareDash(source: inspected, token: token, credentials: hlsCredentials, constraints: loadConstraints)
          case .headeredHls: return .headeredHls(source: inspected,
            prepared: try self.prepareHeaderedHls(source: inspected, token: token, credentialContext: hlsCredentials, videoConstraints: loadConstraints))
          case .localMatroska, .networkMatroska, .networkFlv, .networkRtmp, .transportStream, .programStream, .progressiveMp4, .avi:
            return .fallback(source: inspected, prepared: try self.prepareFallback(source: inspected, token: token, identity: identity))
          default: throw NativePlayerError(category: "container", code: "container.unsupported", message: "Inspection could not establish a supported route.")
          }
        case .reject, nil: throw YlAppleFailureMapper.unsupported
        }
      },
      commit: { [weak self] candidate in
        guard let self, !self.disposed else {
          throw NativePlayerError(
            category: "resource",
            code: "\(YlApplePlatform.current.rawValue).player_disposed",
            message: "The Apple player has been disposed."
          )
        }
        // Reject known fixed-stream limits before willCommit can quiesce this
        // session or peer decoders. Construction keeps its own defensive check.
        if case let .fallback(_, prepared) = candidate {
          try YlFallbackQualityPolicy.validate(
            constraint: YlFallbackQualityConstraint(validating: loadConstraints),
            stream: .init(width: Int(prepared.videoStream.width),
                          height: Int(prepared.videoStream.height), bitrate: nil)
          )
        }
        let rollbackPlaybackIntent = self.currentPlaybackIntent
        willCommit(candidate.requiresHardwareDecoderLease)
        do {
          try self.commit(candidate, identity: identity, reactivating: false, loadVideoConstraints: loadConstraints)
          self.identity = identity
          self.dashRecovery.useSource(identity)
          didCommit()
          self.activeEvents?.commit()
          if let activeTexture = self.activeTexture { self.textureOwner.commit(activeTexture) }
        } catch {
          let requiresExternalRollback = self.slot
            .takeRollbackRequiresExternalActivation()
          didRollback()
          if requiresExternalRollback {
            let failedOpenGeneration = openGeneration
            let scheduledRestorationGeneration = self.restorationGeneration
            DispatchQueue.main.async { [weak self] in
              guard let self,
                    self.restorationGeneration == scheduledRestorationGeneration,
                    self.openCoordinator.canBeginRecovery(
                      after: failedOpenGeneration
                    ) else { return }
              self.restoreAfterHardwareDecoderRollback(
                forcePlay: rollbackPlaybackIntent
              )
            }
          } else if self.slot.current.isActive {
            self.reconcilePendingActiveIntents()
            if rollbackPlaybackIntent { try? self.slot.current.play() }
          }
          throw error
        }
      },
      completion: { [weak self] result in
        if self?.pendingLoadRequestId == requestedLoadRequestId { self?.pendingLoadRequestId = nil }
        if case .failure = result, self?.trafficSource?.loadRequestId == requestedLoadRequestId {
          self?.stopTraffic()
        }
        completion(result)
      }
    )
  }

  func beginActivation(
    forcePlay: Bool,
    willCommit: @escaping (Bool) -> Void,
    didCommit: @escaping () -> Void,
    didRollback: @escaping () -> Void,
    completion: @escaping (Result<Void, NativePlayerError>) -> Void
  ) {
    guard !disposed else {
      completion(.failure(NativePlayerError(
        category: "resource",
        code: "\(YlApplePlatform.current.rawValue).player_disposed",
        message: "The Apple player has been disposed."
      )))
      return
    }
    guard let identity = self.identity else {
      completion(.failure(YlOpenCancellationToken.cancellationError()))
      return
    }
    if let dash = slot.current as? YlDashProgramBackend, dash.needsAsyncActivation(forcePlay: forcePlay) {
      let seek = pendingSeekIntent, pause = pendingPauseIntent, constraints = lastQualityConstraint
      willCommit(true)
      commandCoordinator.begin(operation: { [weak self, weak dash] token in
        guard let self, let dash else { throw YlOpenCancellationToken.cancellationError() }
        try dash.prepareActivation(positionMs: seek?.positionMs, constraints: constraints, forcePlay: forcePlay, cancellation: token)
        // Activation belongs to the same FIFO operation as preparation. A later
        // seek/pause cannot run between worker completion and main activation.
        try DispatchQueue.main.sync {
          try token.throwIfCancelled()
          guard !self.disposed, self.slot.current === dash, self.identity == identity else { throw YlOpenCancellationToken.cancellationError() }
          self.applyPersistentPlaybackControls(to: dash)
          if pause != nil && !forcePlay { try dash.pause() }
          try dash.activate()
          if forcePlay { try dash.play(cancellationToken: token) }
          if self.pendingSeekIntent?.revision == seek?.revision { self.pendingSeekIntent = nil }
          if self.pendingPauseIntent == pause { self.pendingPauseIntent = nil }
        }
      }, completion: { [weak self, weak dash] result in
        guard let self, let dash, !self.disposed, self.slot.current === dash, self.identity == identity else {
          didRollback(); completion(.failure(YlOpenCancellationToken.cancellationError())); return
        }
        switch result {
        case .success: didCommit(); completion(.success(()))
        case .failure(let error): didRollback(); completion(.failure(error))
        }
      })
      return
    }
    if let protected = slot.current as? YlFairPlayBackend {
      do { try applyAcknowledgedControls(to: protected, forcePlay: forcePlay) }
      catch { completion(.failure(Self.commandError(error))); return }
      willCommit(false)
      protected.restore(forcePlay: forcePlay) { [weak self, weak protected] result in
        guard let self, let protected, self.slot.current === protected,
              self.identity == identity else { completion(.failure(YlOpenCancellationToken.cancellationError())); return }
        switch result {
        case .success: didCommit(); completion(.success(()))
        case .failure(let error): didRollback(); completion(.failure(error))
        }
      }
      return
    }
    // Play on an accepted active session must not start another open: doing
    // so would supersede an unrelated candidate that is still preparing.
    if slot.current === avBackend, !avBackend.isActive,
       let source = lastCommittedSource,
       [YlAppleSourceRoute.headeredHls, .dashHls].contains(route(for: source)),
       let hlsCredentials = committedHlsCredentials {
      let loadConstraints = lastQualityConstraint
      let dashSnapshot = committedDashSnapshot
      let fixedTrackId = avBackend.videoSelection.fixedTrackId
      openCoordinator.begin(
        prepare: { [weak self] token in
          guard let self else { throw YlOpenCancellationToken.cancellationError() }
          return .headeredHls(
            source: source,
            prepared: try self.prepareHeaderedHls(source: source, token: token, credentialContext: hlsCredentials, videoConstraints: loadConstraints, dashSnapshot: dashSnapshot, fixedTrackId: fixedTrackId)
          )
        },
        commit: { [weak self] candidate in
          guard let self, !self.disposed, self.slot.current === self.avBackend else {
            throw YlOpenCancellationToken.cancellationError()
          }
          willCommit(candidate.requiresHardwareDecoderLease)
          do {
            try self.commit(candidate, identity: identity, reactivating: true)
            didCommit()
            self.activeEvents?.commit()
            if let activeTexture = self.activeTexture { self.textureOwner.commit(activeTexture) }
          } catch {
            didRollback()
            throw error
          }
        },
        completion: completion
      )
      return
    }

    guard let fallback = slot.current as? YlFallbackBackend,
          fallback.requiresAsyncActivation,
          let source = lastCommittedSource else {
      do {
        willCommit(self.slot.current is YlFallbackBackend)
        let restoringInactive = !slot.current.isActive
        if restoringInactive {
          commandCoordinator.cancelCurrent()
          try applyAcknowledgedControls(to: slot.current, forcePlay: forcePlay)
        }
        try slot.current.activate()
        if restoringInactive {
          pendingSeekIntent = nil
          pendingPauseIntent = nil
        }
        didCommit()
        completion(.success(()))
      } catch let error as NativePlayerError {
        didRollback()
        completion(.failure(error))
      } catch {
        didRollback()
        completion(.failure(Self.commandError(error)))
      }
      return
    }

    let resumeState = reactivationState(fallback, forcePlay: forcePlay)
    let preparedRevision = PreparedRestorationRevision(restorationIntentRevision)
    openCoordinator.begin(
      prepare: { [weak self] token in
        guard let self else { throw YlOpenCancellationToken.cancellationError() }
        let prepare = {
          let prepared = try self.prepareFallback(source: source, token: token, identity: identity, reactivating: true)
          try prepared.prepareForReactivation(resumeState)
          try token.throwIfCancelled()
          return YlPreparedOpen.fallback(source: source, prepared: prepared)
        }
        if ["rtmp", "rtmps"].contains(source.url?.scheme?.lowercased() ?? "") {
          return try source.rtmpRecovery.prepareRestoration(token: token, work: prepare)
        }
        return try prepare()
      },
      commit: { [weak self, weak fallback] candidate in
        guard let self, let fallback, !self.disposed,
              self.slot.current === fallback else {
          throw YlOpenCancellationToken.cancellationError()
        }
        willCommit(candidate.requiresHardwareDecoderLease)
        do {
          try self.commit(candidate, identity: identity, reactivating: true)
          didCommit()
          self.activeEvents?.commit()
          if let activeTexture = self.activeTexture { self.textureOwner.commit(activeTexture) }
        } catch {
          didRollback()
          throw error
        }
      },
      reconcile: { [weak self, weak fallback] candidate in
        guard let self, let fallback, !self.disposed, self.slot.current === fallback else {
          throw YlOpenCancellationToken.cancellationError()
        }
        guard preparedRevision.value != self.restorationIntentRevision else { return nil }
        guard case let .fallback(_, prepared) = candidate else { return nil }
        let latest = self.reactivationState(fallback, forcePlay: forcePlay)
        let revision = self.restorationIntentRevision
        return { token in
          try token.throwIfCancelled()
          try prepared.prepareForReactivation(latest)
          try token.throwIfCancelled()
          preparedRevision.value = revision
        }
      },
      completion: completion
    )
  }

  func activate() throws {
    try slot.current.activate()
  }

  func deactivate() {
    invalidateDashRecovery()
    capsCoordinator.cancelCurrent()
    restorationGeneration &+= 1
    activeRestorationGeneration = nil
    cancelDeferredRestorationCommands()
    commandCoordinator.cancelCurrent()
    openCoordinator.cancelCurrent()
    slot.current.deactivate()
  }

  func handleMemoryWarning() {
    invalidateDashRecovery()
    capsCoordinator.cancelCurrent()
    restorationGeneration &+= 1
    activeRestorationGeneration = nil
    cancelDeferredRestorationCommands()
    commandCoordinator.cancelCurrent()
    openCoordinator.cancelCurrent()
    if let fallback = slot.current as? YlFallbackBackend {
      fallback.handleMemoryWarning()
    } else {
      slot.current.deactivate()
    }
  }

  private func beginCommand(
    _ command: YlApplePlaybackCommand,
    completion: @escaping (Result<Void, NativePlayerError>) -> Void
  ) {
    if activeRestorationGeneration != nil,
       YlRestorationCommandPolicy.defersUntilRestored(command) {
      deferredRestorationCommands.append(DeferredRestorationCommand(
        command: command,
        completion: completion
      ))
      return
    }
    if YlRestorationCommandPolicy.supersedesRestoration(command) {
      let hadActiveRestoration = activeRestorationGeneration != nil
      restorationGeneration &+= 1
      activeRestorationGeneration = nil
      if hadActiveRestoration {
        cancelDeferredRestorationCommands()
        openCoordinator.cancelCurrent()
      }
    }
    let backend = slot.current
    if backend.requiresAsyncCommand(command) || commandCoordinator.hasCurrent {
      let expectedIdentity = identity
      let queued = YlQueuedPlaybackCommand(command: command, resolve: { [weak self] in
        guard let self, !self.disposed, self.identity == expectedIdentity,
              self.pendingLoadRequestId == nil else { throw YlOpenCancellationToken.cancellationError() }
        return self.slot.current
      })
      commandCoordinator.begin(operation: queued.run, completion: completion)
    } else {
      completeCommandSynchronously(backend: backend, command: command, completion: completion)
    }
  }

  private func completeCommandSynchronously(
    backend: YlPlaybackBackend,
    command: YlApplePlaybackCommand,
    completion: (Result<Void, NativePlayerError>) -> Void
  ) {
    do {
      try command.apply(to: backend)
      completion(.success(()))
    } catch let error as NativePlayerError {
      completion(.failure(error))
    } catch {
      completion(.failure(Self.commandError(error)))
    }
  }

  private func commit(
    _ candidate: YlPreparedOpen,
    identity: YlAppleSessionIdentity,
    reactivating: Bool,
    loadVideoConstraints: YlAppleVideoConstraints? = nil,
    cancelCommands: Bool = true
  ) throws {
    if cancelCommands { commandCoordinator.cancelCurrent() }
    let preservedIdentity = reactivating ? (slot.current as? YlFallbackBackend)?.channelGeneration : nil
    let priorEvents = activeEvents
    let priorTexture = activeTexture
    let candidateTexture = textureOwner.makeLease(identity: identity)
    let candidateEvents: YlAppleCommitEmitter
    if case let .fairPlay(_, backend) = candidate {
      candidateEvents = backend.events
    } else if case let .fallback(_, prepared) = candidate, let events = prepared.commitEvents {
      candidateEvents = events
    } else { candidateEvents = YlAppleCommitEmitter(identity: identity, emit: emit) }
    let audioTransaction = audioOwnership?.beginSession()
    let previousAudioToken = audioToken
    var candidateServices = services.borrowing(candidateTexture)
    if let audioOwnership, let audioTransaction {
      candidateServices.beforeAudioOutput = { try audioOwnership.acquire(audioTransaction.token) }
      avBackend.beforeAudioOutput = candidateServices.beforeAudioOutput
    }
    let restoreAudioAuthority = { [self] in
      if let audioOwnership, let audioTransaction {
        audioOwnership.rollback(audioTransaction)
        avBackend.beforeAudioOutput = {
          guard let previousAudioToken else { throw YlOpenCancellationToken.cancellationError() }
          try audioOwnership.acquire(previousAudioToken)
        }
      }
    }
    let beforeRollbackActivation: (YlPlaybackBackend) throws -> Void = { [self] backend in
      restoreAudioAuthority()
      try reconcileBeforeRollbackActivation(backend)
    }
    var committed = false
    defer {
      if committed {
        audioToken = audioTransaction?.token
        priorEvents?.invalidate()
        activeEvents = candidateEvents
        activeTexture = candidateTexture
        // A successful non-AV commit no longer needs the old AV source for
        // rollback. Release any retired remux HTTP origin and temporary media.
        if slot.current !== avBackend { avBackend.clearMediaForStop() }
      } else {
        restoreAudioAuthority()
        candidateEvents.invalidate()
        candidateTexture.dispose()
        avTexture.lease = priorTexture
        if let priorEvents { avBackend.bindCallbacks(priorEvents.accept) }
      }
    }
    let wantsOutput: Bool
    switch candidate {
    case let .fairPlay(source, _): wantsOutput = source.loadOptions?.autoplay ?? false
    case let .avPlayer(source): wantsOutput = source.loadOptions?.autoplay ?? false
    case let .headeredHls(source, _): wantsOutput = reactivating ? currentPlaybackIntent : (source.loadOptions?.autoplay ?? false)
    case let .dashProgram(_, prepared): wantsOutput = prepared.autoplay
    case let .fallback(_, prepared): wantsOutput = prepared.resumeState?.shouldPlay ?? false
    }
    if wantsOutput { try candidateServices.beforeAudioOutput() }
    switch candidate {
    case let .fairPlay(source, backend):
      backend.beforeAudioOutput = candidateServices.beforeAudioOutput
      applyPersistentPlaybackControls(to: backend)
      let previous = try slot.replace(beforeRollbackActivation: beforeRollbackActivation) { backend }
      if previous !== avBackend { previous.dispose() }
      lastCommittedSource = source
      committedHlsCredentials = nil; committedDashSnapshot = nil
      lastQualityConstraint = .unconstrained
    case let .avPlayer(source):
      avTexture.lease = candidateTexture
      avBackend.bindCallbacks(candidateEvents.accept)
      // A new Load installs its captured policy; a retained backend's previous
      // DASH session has no authority to veto the new source's inheritance.
      let constraints = loadVideoConstraints ?? source.loadOptions?.videoConstraints ?? lastQualityConstraint
      applyPersistentPlaybackControls(to: avBackend)
      if slot.current !== avBackend {
        let previous = try slot.replace(beforeRollbackActivation: beforeRollbackActivation,
          afterActivation: { _ in try self.avBackend.open(source, videoConstraints: constraints) }) { avBackend }
        previous.dispose()
      } else {
        try avBackend.activate()
        try avBackend.open(source, videoConstraints: constraints)
      }
      lastCommittedSource = source
      committedHlsCredentials = nil
      committedDashSnapshot = nil
      lastQualityConstraint = constraints
    case let .headeredHls(source, prepared):
      avTexture.lease = candidateTexture
      avBackend.bindCallbacks(candidateEvents.accept)
      applyPersistentPlaybackControls(to: avBackend)
      try avBackend.stagePreparedHls(
        source: source,
        prepared: prepared,
        resume: reactivating
      )
      if slot.current !== avBackend {
        let previous = try slot.replace(beforeRollbackActivation: beforeRollbackActivation) { avBackend }
        if previous !== avBackend { previous.dispose() }
      } else if avBackend.isActive {
        try avBackend.commitStagedHlsIfActive()
      } else {
        try avBackend.activate()
      }
      lastCommittedSource = source
      committedHlsCredentials = prepared.loader.credentialContext
      committedDashSnapshot = prepared.loader.dashSnapshot
      // New Loads own their captured tuple, and DASH restores its immutable
      // projection. Ordinary HLS resume retains the latest acknowledged intent.
      if !reactivating || route(for: source) == .dashHls {
        lastQualityConstraint = prepared.loader.videoConstraints
      }
    case let .dashProgram(source, prepared):
      let previous = try slot.replace(beforeRollbackActivation: beforeRollbackActivation) {
        let backend = try YlDashProgramBackend(prepared: prepared, services: candidateServices,
          generation: slot.generation &+ 1, loadRequestId: identity.loadRequestId, emit: candidateEvents.accept)
        applyPersistentPlaybackControls(to: backend)
        return backend
      }
      if previous !== avBackend { previous.dispose() }
      lastCommittedSource = source
      committedHlsCredentials = nil; committedDashSnapshot = nil
      lastQualityConstraint = prepared.constraints
    case let .fallback(source, prepared):
      let qualityConstraint = try YlFallbackQualityConstraint(
        validating: reactivating || source.loadOptions == nil ? lastQualityConstraint : source.loadOptions?.videoConstraints ?? .unconstrained
      )
      let previous = try slot.replace(requiresExclusiveResources: true, beforeRollbackActivation: beforeRollbackActivation) {
        try beforeFallbackConstruction?(slot.current)
        let backend = try YlFallbackBackend(
          playerId: playerId,
          services: candidateServices,
          configuration: configuration.forLoad(source),
          prepared: prepared,
          qualityConstraint: qualityConstraint,
          generation: slot.generation &+ 1,
          videoSessionFactory: videoSessionFactory,
          loadRequestId: identity.loadRequestId,
          channelIdentity: preservedIdentity,
          audioRendererFactory: audioRendererFactory,
          audioTerminalCandidateEnabled: audioTerminalCandidateEnabled,
          emit: candidateEvents.accept
        )
        applyPersistentPlaybackControls(to: backend)
        return backend
      }
      guard let backend = slot.current as? YlFallbackBackend else {
        throw NativePlayerError(
          category: "internal",
          code: "internal.fallback_invariant",
          message: "The prepared fallback backend was not installed."
        )
      }
      if previous !== avBackend { previous.dispose() }
      if let requestId = source.livePlaybackRequestId, let mode = backend.livePlaybackState?.mode {
        _ = try backend.setLivePlaybackMode(mode, requestId: requestId)
      }
      backend.emitState()
      lastCommittedSource = source
      committedHlsCredentials = nil
      committedDashSnapshot = nil
      if !reactivating, source.loadOptions != nil { lastQualityConstraint = source.loadOptions?.videoConstraints ?? .unconstrained }
    }
    // Successful replacement/restoration consumed these session intents. A
    // failed candidate leaves them available to the surviving current session.
    pendingSeekIntent = nil
    pendingPauseIntent = nil
    committed = true
  }

  private func reconcileBeforeRollbackActivation(_ backend: YlPlaybackBackend) throws {
    // Network recovery continues through its existing external async path.
    if let fallback = backend as? YlFallbackBackend, fallback.requiresAsyncActivation { return }
    if let dash = backend as? YlDashProgramBackend, dash.requiresAsyncActivation { return }
    try applyAcknowledgedControls(to: backend, forcePlay: false)
    // The inactive backend now owns these values even if activation needs a
    // later external recovery. An untouched active backend has not consumed them.
    pendingSeekIntent = nil
    pendingPauseIntent = nil
  }

  private func reconcilePendingActiveIntents() {
    // A retained transaction can reject its candidate before ever quiescing the
    // current backend. Replay through its existing command FIFO; an active
    // network seek must still run on the command worker, never on this main turn.
    if let revision = pendingPauseIntent {
      execute(.pause) { [weak self] result in
        if case .success = result, self?.pendingPauseIntent == revision { self?.pendingPauseIntent = nil }
      }
    }
    if let seek = pendingSeekIntent {
      execute(.seek(seek.positionMs)) { [weak self] result in
        if case .success = result, self?.pendingSeekIntent?.revision == seek.revision { self?.pendingSeekIntent = nil }
      }
    }
  }

  private func applyAcknowledgedControls(to backend: YlPlaybackBackend, forcePlay: Bool) throws {
    applyPersistentPlaybackControls(to: backend)
    try backend.setVideoConstraints(lastQualityConstraint)
    if let seek = pendingSeekIntent {
      try backend.seek(toMs: seek.positionMs, cancellationToken: nil)
    }
    if pendingPauseIntent != nil && !forcePlay {
      try backend.pause()
    }
  }

  private func applyPersistentPlaybackControls(to backend: YlPlaybackBackend) {
    try? backend.setVolume(lastVolume)
    try? backend.setPlaybackSpeed(lastPlaybackSpeed)
  }

  private func prepareNativeOrMp4(source: YlAppleSourceDescriptor, token: YlOpenCancellationToken,
    identity: YlAppleSessionIdentity) throws -> YlPreparedOpen {
    if let url = source.url,
       source.kind == .network,
       YlEngineRouter.resolvedFormat(source, url: url) == .hls {
      // Discarding a non-HEVC probe cancels its resources, not the Load that
      // must still commit AVPlayer. Stop/replacement cancellation continues
      // to propagate from the Load into the probe (and a retained HEVC session).
      let probeToken = YlOpenCancellationToken()
      token.onCancel { probeToken.cancel() }
      do {
        let prepared = try prepareFallback(source: source, token: probeToken, identity: identity)
        if Int(prepared.videoStream.codec) == YLFCodecHEVC {
          return .fallback(source: source, prepared: prepared)
        }
        prepared.discard()
      } catch let error as NativePlayerError {
        try token.throwIfCancelled()
        // Master, fMP4, encrypted, discontinuous and non-TS playlists keep
        // their established AVPlayer route. Managed playback is only selected
        // after a complete HEVC-in-MPEG-TS preparation succeeds.
        if error.code != "network.cancelled" { return .avPlayer(source: source) }
        throw error
      }
    }
    if try YlMp4CompatibilityInspector.requiresFallback(source, configuration: configuration.network, token: token) {
      return .fallback(source: source, prepared: try prepareFallback(source: source, token: token, identity: identity))
    }
    return .avPlayer(source: source)
  }

  private func prepareFallback(
    source: YlAppleSourceDescriptor,
    token: YlOpenCancellationToken,
    identity: YlAppleSessionIdentity,
    reactivating: Bool = false
  ) throws -> YlPreparedFallback {
    let candidateEvents = YlAppleCommitEmitter(identity: identity, emit: emit)
    let prepared = try YlPreparedFallback(
      source: source,
      requireHardwareProbe: false,
      configuration: configuration.forLoad(source),
      cancellationToken: token,
      commitEvents: candidateEvents,
      onRetry: { attempt, delayMs, error in
        guard !token.isCancelled else { return }
        candidateEvents.accept(YlNativeBackendCallback(generation: 0,
          event: .retry(attempt: attempt, delayMs: delayMs, error: error)))
      }
    )
    if !reactivating, source.loadOptions != nil {
      let options = source.loadOptions
      try prepared.prepareForLoad(positionMs: options?.startPositionMs ?? 0, autoplay: options?.autoplay ?? false)
    }
    try prepared.prepareHardwareEvidence(configuration: configuration.forLoad(source),
      factory: videoSessionFactory, stage: hardwareEvidenceStage, token: token)
    return prepared
  }

  /// Selects the legacy projection only when its complete admission succeeds.
  /// Failed projection cannot restart MPD/index networking or restore credentials.
  private func prepareDash(source: YlAppleSourceDescriptor, token: YlOpenCancellationToken,
                           credentials: YlHlsCredentialContext,
                           constraints: YlAppleVideoConstraints) throws -> YlPreparedOpen {
    guard let url = source.url else { throw YlAppleFailureMapper.unsupported }
    let scope = try source.bufferScope ?? bufferLedger.makeScope(maxBytes: nil)
    let resources = YlDashProgramResources(source: url, headers: source.headers, credentials: source.credentials,
      credentialsAllowed: source.credentialContext.maySendCredentials, rootIntent: source.managedRequestIntent,
      configuration: source.networkConfiguration.map(YlNetworkConfiguration.init(options:)) ?? configuration.network, scope: scope)
    let inspected = try YlDashProgramLoader.inspect(url: url, resources: resources, cancellation: token)
    let manifest = inspected.manifest
    if source.networkPolicy != .managed, source.loadOptions?.decoderPolicy != .hardwareRequired {
      let eligible = (try? YlDashHlsCompiler.compile(data: manifest.data, finalManifestURL: manifest.finalURL,
        sourceURL: url, credentialsStripped: manifest.credentialsStripped, indexes: inspected.indexes,
        videoConstraints: constraints, manifestURL: { url.appendingPathComponent($0) }, mediaURL: { value, _ in value })) != nil
      if eligible {
        let snapshot = YlDashManifestSnapshot(data: manifest.data, effectiveURL: manifest.finalURL,
          credentialsStripped: manifest.credentialsStripped, indexes: inspected.indexes)
        return .headeredHls(source: source, prepared: try prepareHeaderedHls(source: source, token: token,
          credentialContext: credentials, videoConstraints: constraints, dashSnapshot: snapshot))
      }
    }
    let program = try inspected.program(source: url)
    return .dashProgram(source: source, prepared: try YlPreparedDashProgram(program: program,
      resources: resources, scope: scope, cancellation: token, constraints: constraints,
      decoderPolicy: source.loadOptions?.decoderPolicy ?? .systemDefault,
      autoplay: source.loadOptions?.autoplay ?? false, startPositionMs: source.loadOptions?.startPositionMs ?? 0))
  }

  private func prepareHeaderedHls(
    source: YlAppleSourceDescriptor,
    token: YlOpenCancellationToken,
    credentialContext: YlHlsCredentialContext,
    videoConstraints: YlAppleVideoConstraints,
    dashSnapshot: YlDashManifestSnapshot? = nil,
    fixedTrackId: String? = nil
  ) throws -> YlPreparedHlsAsset {
    try token.throwIfCancelled()
    guard let url = source.url else {
      throw NativePlayerError(
        category: "source",
        code: "source.invalid_uri",
        message: "A valid HLS URI is required."
      )
    }
    // Inspection and HLS are two readers of the same original root intent.
    // Seed only that resource; descendant URLs inherit its marker while
    // unrelated HLS resources retain their existing independent history.
    if !source.credentialContext.maySendCredentials {
      credentialContext.strip(url.absoluteString)
    }
    let prepared = try YlPreparedHlsAsset(
      originURL: url,
      isDash: route(for: source) == .dashHls,
      videoConstraints: videoConstraints, fixedTrackId: fixedTrackId,
      headers: source.headers,
      credentials: source.credentials,
      configuration: configuration.network,
      cancellationToken: token,
      dashSnapshot: dashSnapshot,
      credentialContext: credentialContext,
      opaqueRetention: try bufferLedger.acquireOpaqueHlsRetention(), trafficScope: source.bufferScope
    )
    if fixedTrackId != nil {
      prepared.automaticCandidate = try prepareHeaderedHls(source: source, token: token,
        credentialContext: credentialContext, videoConstraints: videoConstraints,
        dashSnapshot: prepared.loader.dashSnapshot)
    }
    return prepared
  }

  private func route(for source: YlAppleSourceDescriptor) -> YlAppleSourceRoute {
    YlSourceRouter.route(source)
  }

  private static func commandError(_ error: Error) -> NativePlayerError {
    NativePlayerError(
      category: "internal",
      code: "\(YlApplePlatform.current.rawValue).command_failed",
      message: "Apple player command failed.",
      diagnostic: YlAppleSafeDiagnostics.diagnostic(error)
    )
  }

  func emitState() {
    slot.current.emitState()
  }

  func quiesceForHardwareDecoderLease() {
    capsCoordinator.cancelCurrent()
    hardwareRollbackPlaybackIntent = currentPlaybackIntent
    slot.current.quiesceForReplacement()
  }

  func restoreAfterHardwareDecoderRollback(forcePlay: Bool? = nil) {
    invalidateDashRecovery()
    let shouldResumePlayback = forcePlay
      ?? hardwareRollbackPlaybackIntent
      ?? currentPlaybackIntent
    hardwareRollbackPlaybackIntent = nil
    restorationGeneration &+= 1
    let recoveryGeneration = restorationGeneration
    activeRestorationGeneration = recoveryGeneration
    beginActivation(
      forcePlay: shouldResumePlayback,
      willCommit: { _ in },
      didCommit: {},
      didRollback: {},
      completion: { [weak self] result in
        guard let self, !self.disposed,
              self.restorationGeneration == recoveryGeneration,
              self.activeRestorationGeneration == recoveryGeneration else { return }
        self.activeRestorationGeneration = nil
        switch result {
        case .success:
          if shouldResumePlayback {
            do {
              try self.slot.current.play()
            } catch let error as NativePlayerError {
              self.failDeferredRestorationCommands(error)
              self.reportRestorationFailure(error)
              return
            } catch {
              let error = Self.commandError(error)
              self.failDeferredRestorationCommands(error)
              self.reportRestorationFailure(error)
              return
            }
          }
          self.runDeferredRestorationCommands()
        case let .failure(error):
          self.failDeferredRestorationCommands(error)
          guard YlFallbackRestorationPolicy.shouldReport(
            error: error,
            isCurrentBackend: true
          ) else { return }
          self.reportRestorationFailure(error)
        }
      }
    )
  }

  var currentPlaybackIntent: Bool {
    if pendingPauseIntent != nil { return false }
    if let fallback = slot.current as? YlFallbackBackend {
      return fallback.playbackIntent
    }
    if let dash = slot.current as? YlDashProgramBackend { return dash.playbackIntent }
    if let protected = slot.current as? YlFairPlayBackend { return protected.playbackIntent }
    return slot.current === avBackend && avBackend.playbackIntent
  }

  private func reportRestorationFailure(_ error: NativePlayerError) {
    if let fallback = slot.current as? YlFallbackBackend {
      fallback.reportRestorationFailure(error)
    } else if let dash = slot.current as? YlDashProgramBackend {
      dash.reportRestorationFailure(error)
    } else if let protected = slot.current as? YlFairPlayBackend {
      protected.fail(error)
    } else {
      avBackend.reportRestorationFailure(error)
    }
  }

  private func runDeferredRestorationCommands() {
    let commands = deferredRestorationCommands
    deferredRestorationCommands.removeAll()
    commands.forEach { command in
      beginCommand(
        command.command,
        completion: command.completion
      )
    }
  }

  private func failDeferredRestorationCommands(_ error: NativePlayerError) {
    let commands = deferredRestorationCommands
    deferredRestorationCommands.removeAll()
    commands.forEach { $0.completion(.failure(error)) }
  }

  private func cancelDeferredRestorationCommands() {
    failDeferredRestorationCommands(YlOpenCancellationToken.cancellationError())
  }

  func releaseAudioAfterFailure(identity: YlAppleSessionIdentity) {
    guard self.identity == identity, let audioToken else { return }
    audioOwnership?.release(ifCurrent: audioToken)
  }

  func emitError(_ error: NativePlayerError) {
    guard let identity else { return }
    emit(identity, YlNativeBackendCallback(generation: 0, event: .failure(error)))
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    slot.current.copyPixelBuffer()
  }

  func dispose() {
    guard !disposed else { return }
    disposed = true
    invalidateDashRecovery()
    dashRecoveryTimer?.invalidate(); dashRecoveryTimer = nil
    if let observer = dashRecoveryObserver { NotificationCenter.default.removeObserver(observer) }
    dashRecoveryObserver = nil
    stopTraffic()
    capsCoordinator.cancelCurrent()
    committedHlsCredentials = nil
    committedDashSnapshot = nil
    lastCommittedSource = nil
    activeEvents?.invalidate()
    activeEvents = nil
    activeTexture?.dispose()
    activeTexture = nil
    restorationGeneration &+= 1
    activeRestorationGeneration = nil
    cancelDeferredRestorationCommands()
    commandCoordinator.cancelCurrent()
    openCoordinator.cancelCurrent()
    let current = slot.current
    slot.dispose()
    if current !== avBackend { avBackend.dispose() }
    audioOwnership?.stop()
    audioToken = nil

  }

  deinit {
    dispose()
  }
}


extension YlAppleSessionCoordinator {
  private func prepareAirPlay(_ source: YlAppleSourceDescriptor, token: YlOpenCancellationToken) throws -> YlPreparedOpen {
    var candidate = source
    if ["rtmp", "rtmps"].contains(candidate.url?.scheme?.lowercased() ?? "") {
      _ = try YlRtmpAddress.validate(candidate)
      candidate.formatHint = .flv
      candidate.intent = .live
    } else if candidate.formatHint == .automatic {
      candidate = try YlSourceInspector.inspect(candidate, configuration: configuration.network, token: token)
    }
    try token.throwIfCancelled()
    switch YlEngineRouter.airPlayRoute(candidate) {
    case .unsupported, .inspect: throw YlAppleFailureMapper.unsupported
    case .native: return .avPlayer(source: candidate)
    case .remux, .liveRemux:
      let input = try YlAppleDeliveryInput.make(source: candidate, configuration: configuration,
        live: YlEngineRouter.airPlayRoute(candidate) == .liveRemux)
      let media = try services.mediaDeliveryService().prepare(input: input, token: token)
      try token.throwIfCancelled()
      candidate.airPlayMedia = media
      candidate.uri = media.url.absoluteString
      candidate.kind = .network
      candidate.formatHint = .hls
      candidate.headers = [:]; candidate.credentials = [:]
      return .avPlayer(source: candidate)
    }
  }
}

private extension YlAppleSessionCoordinator {
  func invalidateDashRecovery() {
    dashRecoveryRevision &+= 1
    dashRecovery.invalidate()
  }

  func recoverySample() -> YlDashAutoRecoveryPolicy.Sample? {
    guard !disposed, pendingLoadRequestId == nil, identity != nil,
      activeRestorationGeneration == nil, slot.current === avBackend,
      !capsCoordinator.hasCurrent, !commandCoordinator.hasCurrent,
      lastQualityConstraint == .unconstrained,
      let source = lastCommittedSource, route(for: source) == .dashHls,
      !source.isLive, !source.airPlay, source.drm == nil,
      let credentials = committedHlsCredentials, committedDashSnapshot != nil else { return nil }
    return avBackend.dashRecoverySample(now: ProcessInfo.processInfo.systemUptime,
      intentRevision: dashRecoveryRevision, credentialRevision: credentials.revision)
  }

  func pollDashRecovery() {
    guard !disposed, pendingLoadRequestId == nil, let identity, let source = lastCommittedSource,
          let credentials = committedHlsCredentials, let snapshot = committedDashSnapshot else { dashRecovery.invalidate(); return }
    dashRecovery.useSource(identity)
    let revision = dashRecoveryRevision
    let credentialRevision = credentials.revision
    dashRecovery.tick(recoverySample(), prepare: { [weak self] token in
      guard let self else { throw YlOpenCancellationToken.cancellationError() }
      // Reuse the committed immutable projection and its credential history.
      // A fresh loader/asset resets AVPlayer's item without refetching a new MPD.
      let candidate = YlPreparedOpen.headeredHls(source: source, prepared: try self.prepareHeaderedHls(source: source,
        token: token, credentialContext: credentials, videoConstraints: .unconstrained, dashSnapshot: snapshot))
      self.afterDashRecoveryPreparation?(token)
      return candidate
    }, currentSample: { [weak self] in self?.recoverySample() }, commit: { [weak self] candidate in
      guard let self, self.identity == identity, self.dashRecoveryRevision == revision,
        self.committedHlsCredentials === credentials, self.pendingLoadRequestId == nil,
        self.slot.current === self.avBackend, self.avBackend.isActive,
        case let .headeredHls(_, prepared) = candidate else { throw YlOpenCancellationToken.cancellationError() }
      let generation = self.avBackend.dashRecoveryItemGeneration
      let accepted = try credentials.withUnchangedRevision(credentialRevision) {
        try self.avBackend.replaceActiveDash(source: source, prepared: prepared)
      }
      guard accepted else { throw YlOpenCancellationToken.cancellationError() }
      return ["itemChanged": generation != self.avBackend.dashRecoveryItemGeneration, "credentialCommitAccepted": accepted]
    })
  }
}
