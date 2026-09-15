import AVFoundation
import CoreVideo
import Foundation
import YlFFmpegBridge

final class YlAppleSessionCoordinator: NSObject {
  private final class PreparedRestorationRevision {
    var value: UInt64
    init(_ value: UInt64) { self.value = value }
  }

  private struct DeferredRestorationCommand {
    let command: YlApplePlaybackCommand
    let completion: (Result<Void, NativePlayerError>) -> Void
  }

  let playerId: Int64
  var textureId: Int64 { services.textureOutput.textureId }
  var isActive: Bool { slot.current.isActive }

  private let services: YlPlatformServices
  private let audioOwnership: YlPlayerAudioOwnership?
  private var audioToken: UUID?
  private let textureOwner: YlAppleTextureOwner
  private let avTexture: YlAppleAvTextureBinding
  private var activeTexture: YlAppleTextureLease?
  private let videoSessionFactory: YlVTSessionFactory?
  private let hardwareEvidenceStage: YlHardwareEvidencePreparation
  private let bufferLedger: YlManagedBufferLedger
  private let configuration: PlayerConfiguration
  private let emit: (YlAppleSessionIdentity, YlNativeBackendCallback) -> Void
  private let avBackend: YlAvPlayerBackend
  private let slot: YlBackendSlot
  private let openCoordinator = YlOpenCoordinator()
  private let commandCoordinator: YlAsyncCommandCoordinator
  private let beforeFallbackConstruction: ((YlPlaybackBackend) throws -> Void)?
  private var lastCommittedSource: YlAppleSourceDescriptor?
  private var committedHlsCredentials: YlHlsCredentialContext?
  private(set) var lastQualityConstraint = YlAppleVideoConstraints.unconstrained
  private var synchronousIntentRevision: UInt64 = 0
  private var restorationIntentRevision: UInt64 = 0
  private var pendingSeekIntent: (revision: UInt64, positionMs: Int64)?
  private var pendingPauseIntent: UInt64?
  private var lastVolume: Float = 1
  private var lastPlaybackSpeed: Float = 1
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
       beforeFallbackConstruction: ((YlPlaybackBackend) throws -> Void)? = nil,
       slotCompatibility: YlAppleCompatibility? = nil,
       bufferLedger: YlManagedBufferLedger = YlManagedBufferLedger(),
       videoSessionFactory: YlVTSessionFactory? = nil,
       hardwareEvidenceStage: YlHardwareEvidencePreparation = .init(),
       audioOwnership: YlPlayerAudioOwnership? = nil,
       emit: @escaping (YlAppleSessionIdentity, YlNativeBackendCallback) -> Void) {
    self.audioOwnership = audioOwnership
    self.videoSessionFactory = videoSessionFactory
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
      configuration: configuration, player: avPlayer, emit: { _ in })
    self.avBackend = avBackend
    self.slot = YlBackendSlot(initial: avBackend, compatibility: slotCompatibility ?? services.compatibility)
    super.init()
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
    beginOpen(source, decision: assessment, identity: identity, willCommit: willCommit,
      didCommit: didCommit, didRollback: didRollback, completion: completion)
  }

  var acceptedVideoConstraints: YlAppleVideoConstraints {
    lastQualityConstraint
  }

  func execute(_ command: YlApplePlaybackCommand,
    completion: @escaping (Result<Void, NativePlayerError>) -> Void) {
    if case .constraints(let constraints) = command, let fallback = slot.current as? YlFallbackBackend {
      do { try fallback.validateQualityConstraint(YlFallbackQualityConstraint(validating: constraints)) }
      catch let error as NativePlayerError { completion(.failure(error)); return }
      catch { completion(.failure(Self.commandError(error))); return }
    }
    beginCommand(command) { [weak self] result in
      if case .success = result, case .track = command { self?.restorationIntentRevision &+= 1 }
      completion(result)
    }
  }

  /// Synchronous transport methods acknowledge validated intent here. Queued
  /// effects may be cancelled with their backend; acknowledged intent cannot be.
  func executeSynchronous(_ command: YlApplePlaybackCommand) throws {
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
    case let .constraints(constraints): lastQualityConstraint = constraints
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
    // A candidate owns fresh provenance; failed/cancelled work never writes the
    // surviving session's context or a later user Load's context.
    let hlsCredentials = YlHlsCredentialContext()
    let requestedLoadRequestId = identity.loadRequestId
    pendingLoadRequestId = requestedLoadRequestId
    var openGeneration: UInt64 = 0
    openGeneration = openCoordinator.begin(
      prepare: { [weak self] token in
        guard let self else { throw YlOpenCancellationToken.cancellationError() }
        try token.throwIfCancelled()
        switch decision.candidate {
        case .avPlayer:
          return try self.prepareNativeOrMp4(source: source, token: token, identity: identity)
        case .localMatroska, .networkMatroska, .networkFlv:
          return .fallback(
            source: source,
            prepared: try self.prepareFallback(source: source, token: token, identity: identity)
          )
        case .headeredHls:
          return .headeredHls(
            source: source,
            prepared: try self.prepareHeaderedHls(source: source, token: token, credentialContext: hlsCredentials)
          )
        case .inspect:
          let inspected = try YlSourceInspector.inspect(source, configuration: self.configuration.network, token: token)
          let refined = YlEngineRouter.assess(inspected)
          if let error = refined.rejection { throw error }
          switch refined.candidate {
          case .avPlayer: return try self.prepareNativeOrMp4(source: inspected, token: token, identity: identity)
          case .headeredHls: return .headeredHls(source: inspected,
            prepared: try self.prepareHeaderedHls(source: inspected, token: token, credentialContext: hlsCredentials))
          case .localMatroska, .networkMatroska, .networkFlv:
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
        let rollbackPlaybackIntent = self.currentPlaybackIntent
        willCommit(candidate.requiresHardwareDecoderLease)
        do {
          try self.commit(candidate, identity: identity, reactivating: false)
          self.identity = identity
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
    if slot.current === avBackend,
       let source = lastCommittedSource,
       route(for: source) == .headeredHls,
       let hlsCredentials = committedHlsCredentials {
      openCoordinator.begin(
        prepare: { [weak self] token in
          guard let self else { throw YlOpenCancellationToken.cancellationError() }
          return .headeredHls(
            source: source,
            prepared: try self.prepareHeaderedHls(source: source, token: token, credentialContext: hlsCredentials)
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
        let prepared = try self.prepareFallback(source: source, token: token, identity: identity, reactivating: true)
        try prepared.prepareForReactivation(resumeState)
        try token.throwIfCancelled()
        return .fallback(source: source, prepared: prepared)
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
    restorationGeneration &+= 1
    activeRestorationGeneration = nil
    cancelDeferredRestorationCommands()
    commandCoordinator.cancelCurrent()
    openCoordinator.cancelCurrent()
    slot.current.deactivate()
  }

  func handleMemoryWarning() {
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
    let commandCompletion = completion
    let backend = slot.current
    if let fallback = backend as? YlFallbackBackend {
      let runsInBackground = fallback.requiresAsyncCommand(command)
      guard runsInBackground || commandCoordinator.hasCurrent else {
        completeCommandSynchronously(
          backend: backend,
          command: command,
          completion: commandCompletion
        )
        return
      }
      commandCoordinator.begin(
        operation: { token in
          token.onCancel { [weak fallback] in fallback?.interruptControlOperation() }
          defer { fallback.resumeControlOperation() }
          try token.throwIfCancelled()
          if runsInBackground {
            try command.apply(to: fallback, cancellationToken: token)
          } else {
            try DispatchQueue.main.sync {
              try token.throwIfCancelled()
              try command.apply(to: backend)
            }
          }
        },
        completion: commandCompletion
      )
      return
    }
    completeCommandSynchronously(
      backend: backend,
      command: command,
      completion: commandCompletion
    )
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
    reactivating: Bool
  ) throws {
    commandCoordinator.cancelCurrent()
    let preservedIdentity = reactivating ? (slot.current as? YlFallbackBackend)?.channelGeneration : nil
    let priorEvents = activeEvents
    let priorTexture = activeTexture
    let candidateTexture = textureOwner.makeLease(identity: identity)
    let candidateEvents: YlAppleCommitEmitter
    if case let .fallback(_, prepared) = candidate, let events = prepared.commitEvents {
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
    case let .avPlayer(source): wantsOutput = source.loadOptions?.autoplay ?? false
    case let .headeredHls(source, _): wantsOutput = reactivating ? currentPlaybackIntent : (source.loadOptions?.autoplay ?? false)
    case let .fallback(_, prepared): wantsOutput = prepared.resumeState?.shouldPlay ?? false
    }
    if wantsOutput { try candidateServices.beforeAudioOutput() }
    switch candidate {
    case let .avPlayer(source):
      avTexture.lease = candidateTexture
      avBackend.bindCallbacks(candidateEvents.accept)
      if source.loadOptions == nil {
        try avBackend.setVideoConstraints(lastQualityConstraint)
      }
      applyPersistentPlaybackControls(to: avBackend)
      if slot.current !== avBackend {
        let previous = try slot.replace(beforeRollbackActivation: beforeRollbackActivation) { avBackend }
        previous.dispose()
      } else {
        try avBackend.activate()
      }
      try avBackend.open(source)
      lastCommittedSource = source
      committedHlsCredentials = nil
      if !reactivating, source.loadOptions != nil { lastQualityConstraint = source.loadOptions?.videoConstraints ?? .unconstrained }
    case let .headeredHls(source, prepared):
      avTexture.lease = candidateTexture
      avBackend.bindCallbacks(candidateEvents.accept)
      if source.loadOptions == nil {
        try avBackend.setVideoConstraints(lastQualityConstraint)
      }
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
      if !reactivating, source.loadOptions != nil { lastQualityConstraint = source.loadOptions?.videoConstraints ?? .unconstrained }
    case let .fallback(source, prepared):
      let qualityConstraint = try YlFallbackQualityConstraint(
        validating: reactivating || source.loadOptions == nil ? lastQualityConstraint : source.loadOptions?.videoConstraints ?? .unconstrained
      )
      let previous = try slot.replace(beforeRollbackActivation: beforeRollbackActivation) {
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
      backend.emitState()
      lastCommittedSource = source
      committedHlsCredentials = nil
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

  private func prepareHeaderedHls(
    source: YlAppleSourceDescriptor,
    token: YlOpenCancellationToken,
    credentialContext: YlHlsCredentialContext
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
    return try YlPreparedHlsAsset(
      originURL: url,
      headers: source.headers,
      credentials: source.credentials,
      configuration: configuration.network,
      cancellationToken: token,
      credentialContext: credentialContext,
      opaqueRetention: try bufferLedger.acquireOpaqueHlsRetention()
    )
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
    hardwareRollbackPlaybackIntent = currentPlaybackIntent
    slot.current.quiesceForReplacement()
  }

  func restoreAfterHardwareDecoderRollback(forcePlay: Bool? = nil) {
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
    return slot.current === avBackend && avBackend.playbackIntent
  }

  private func reportRestorationFailure(_ error: NativePlayerError) {
    if let fallback = slot.current as? YlFallbackBackend {
      fallback.reportRestorationFailure(error)
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
    committedHlsCredentials = nil
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
