import AVFoundation
import CoreVideo
import Foundation

final class YlAppleSessionCoordinator: NSObject {
  private struct DeferredRestorationCommand {
    let name: String
    let arguments: [String: Any?]
    let completion: (Result<Void, NativePlayerError>) -> Void
  }

  let playerId: Int64
  var textureId: Int64 { services.textureOutput.textureId }
  var isActive: Bool { slot.current.isActive }

  private let services: YlPlatformServices
  private let textureOwner: YlAppleTextureOwner
  private let avTexture: YlAppleAvTextureBinding
  private var activeTexture: YlAppleTextureLease?
  private let configuration: PlayerConfiguration
  private let emit: (YlAppleSessionIdentity, YlNativeBackendCallback) -> Void
  private let avBackend: YlAvPlayerBackend
  private let slot: YlBackendSlot
  private let openCoordinator = YlOpenCoordinator()
  private let commandCoordinator: YlAsyncCommandCoordinator
  private var lastCommittedSource: [String: Any?]?
  private(set) var lastQualityConstraint: [String: Any?] = [:]
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
       emit: @escaping (YlAppleSessionIdentity, YlNativeBackendCallback) -> Void) {
    self.commandCoordinator = commandCoordinator
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
    self.slot = YlBackendSlot(initial: avBackend, compatibility: services.compatibility)
    super.init()
  }

  func load(_ recipe: YlAppleLoadRecipe, identity: YlAppleSessionIdentity,
    willCommit: @escaping (Bool) -> Void, didCommit: @escaping () -> Void,
    didRollback: @escaping () -> Void,
    completion: @escaping (Result<Void, NativePlayerError>) -> Void) {
    beginOpen(recipe.source, identity: identity, willCommit: willCommit,
      didCommit: didCommit, didRollback: didRollback, completion: completion)
  }

  var acceptedVideoConstraints: YlAppleVideoConstraints {
    YlAppleVideoConstraints(maxWidth: lastQualityConstraint["maxWidth"] as? Int,
      maxHeight: lastQualityConstraint["maxHeight"] as? Int,
      maxBitrate: lastQualityConstraint["maxBitrate"] as? Int)
  }

  func execute(_ command: YlApplePlaybackCommand,
    completion: @escaping (Result<Void, NativePlayerError>) -> Void) {
    if case .constraints(let constraints) = command, let fallback = slot.current as? YlFallbackBackend {
      do { try fallback.validateQualityConstraint(YlFallbackQualityConstraint(validating: constraints.native)) }
      catch let error as NativePlayerError { completion(.failure(error)); return }
      catch { completion(.failure(Self.commandError(error))); return }
    }
    let native = command.native
    beginCommand(name: native.name, arguments: native.arguments, completion: completion)
  }

  func stop() {
    beginCommand(name: "stop", arguments: [:], completion: { _ in })
    identity = nil
    activeTexture?.dispose()
    activeTexture = nil
    textureOwner.stop()
  }

  private func beginOpen(
    _ source: [String: Any?],
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
    let requestedLoadRequestId = identity.loadRequestId
    pendingLoadRequestId = requestedLoadRequestId
    var openGeneration: UInt64 = 0
    openGeneration = openCoordinator.begin(
      prepare: { [weak self] token in
        guard let self else { throw YlOpenCancellationToken.cancellationError() }
        try token.throwIfCancelled()
        switch self.route(for: source) {
        case .avPlayer:
          try self.avBackend.validateOpen(source)
          return .avPlayer(source: source)
        case .localMatroska, .networkMatroska, .networkFlv:
          return .fallback(
            source: source,
            prepared: try self.prepareFallback(source: source, token: token, identity: identity)
          )
        case .headeredHls:
          return .headeredHls(
            source: source,
            prepared: try self.prepareHeaderedHls(source: source, token: token)
          )
        case let .reject(category, code, message):
          throw NativePlayerError(category: category, code: code, message: message)
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
          } else if rollbackPlaybackIntent, self.slot.current.isActive {
            try? self.slot.current.command(name: "play", arguments: [:])
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
       route(for: source) == .headeredHls {
      openCoordinator.begin(
        prepare: { [weak self] token in
          guard let self else { throw YlOpenCancellationToken.cancellationError() }
          return .headeredHls(
            source: source,
            prepared: try self.prepareHeaderedHls(source: source, token: token)
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
        try slot.current.activate()
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

    let resumeState = fallback.reactivationState(forcePlay: forcePlay)
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
    name: String,
    arguments: [String: Any?],
    completion: @escaping (Result<Void, NativePlayerError>) -> Void
  ) {
    if name == "requestState" { emitState(); completion(.success(())); return }
    if name == "stop" {
      commandCoordinator.cancelCurrent()
      openCoordinator.cancelCurrent()
      restorationGeneration &+= 1
      activeRestorationGeneration = nil
      hardwareRollbackPlaybackIntent = nil
      cancelDeferredRestorationCommands()
      activeEvents?.invalidate()
      activeEvents = nil
      lastCommittedSource = nil
      // The persistent AV backend may hold an older source while fallback is current.
      if slot.current !== avBackend { avBackend.clearMediaForStop() }
      slot.stop()
      completion(.success(()))
      return
    }

    if activeRestorationGeneration != nil,
       YlRestorationCommandPolicy.defersUntilRestored(name) {
      deferredRestorationCommands.append(DeferredRestorationCommand(
        name: name,
        arguments: arguments,
        completion: completion
      ))
      return
    }
    if YlRestorationCommandPolicy.supersedesRestoration(name) {
      let hadActiveRestoration = activeRestorationGeneration != nil
      restorationGeneration &+= 1
      activeRestorationGeneration = nil
      if hadActiveRestoration {
        cancelDeferredRestorationCommands()
        openCoordinator.cancelCurrent()
      }
    }
    guard name != "open" else {
      completion(.failure(NativePlayerError(
        category: "internal",
        code: "internal.fallback_invariant",
        message: "Open commands must use asynchronous preparation."
      )))
      return
    }
    let qualityConstraint = name == "setQualityConstraint"
      ? stringMap(arguments["constraint"])
      : nil
    if let qualityConstraint {
      do {
        _ = try YlFallbackQualityConstraint(validating: qualityConstraint)
      } catch let error as NativePlayerError {
        completion(.failure(error))
        return
      } catch {
        completion(.failure(Self.commandError(error)))
        return
      }
    }
    let commandCompletion: (Result<Void, NativePlayerError>) -> Void = {
      [weak self] result in
      if case .success = result {
        if let qualityConstraint {
          self?.lastQualityConstraint = qualityConstraint
        }
        if name == "setVolume" {
          self?.lastVolume = float(arguments["volume"]) ?? 1
        } else if name == "setPlaybackSpeed" {
          self?.lastPlaybackSpeed = float(arguments["speed"]) ?? 1
        }
      }
      completion(result)
    }
    let backend = slot.current
    if let fallback = backend as? YlFallbackBackend {
      let runsInBackground = fallback.requiresAsyncCommand(name)
      guard runsInBackground || commandCoordinator.hasCurrent else {
        completeCommandSynchronously(
          backend: backend,
          name: name,
          arguments: arguments,
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
            try fallback.command(
              name: name,
              arguments: arguments,
              cancellationToken: token
            )
          } else {
            try DispatchQueue.main.sync {
              try token.throwIfCancelled()
              try backend.command(name: name, arguments: arguments)
            }
          }
        },
        completion: commandCompletion
      )
      return
    }
    completeCommandSynchronously(
      backend: backend,
      name: name,
      arguments: arguments,
      completion: commandCompletion
    )
  }

  private func completeCommandSynchronously(
    backend: YlPlaybackBackend,
    name: String,
    arguments: [String: Any?],
    completion: (Result<Void, NativePlayerError>) -> Void
  ) {
    do {
      try backend.command(name: name, arguments: arguments)
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
    var committed = false
    defer {
      if committed {
        priorEvents?.invalidate()
        activeEvents = candidateEvents
        activeTexture = candidateTexture
      } else {
        candidateEvents.invalidate()
        candidateTexture.dispose()
        avTexture.lease = priorTexture
        if let priorEvents { avBackend.bindCallbacks(priorEvents.accept) }
      }
    }
    switch candidate {
    case let .avPlayer(source):
      avTexture.lease = candidateTexture
      avBackend.bindCallbacks(candidateEvents.accept)
      if source["loadOptions"] == nil && !lastQualityConstraint.isEmpty {
        try avBackend.command(
          name: "setQualityConstraint",
          arguments: ["constraint": lastQualityConstraint]
        )
      }
      applyPersistentPlaybackControls(to: avBackend)
      if slot.current !== avBackend {
        let previous = try slot.replace { avBackend }
        previous.dispose()
      } else {
        try avBackend.activate()
      }
      try avBackend.command(name: "open", arguments: ["source": source])
      lastCommittedSource = source
      if !reactivating, source["loadOptions"] != nil { lastQualityConstraint = stringMap(stringMap(source["loadOptions"])["videoConstraints"]) }
    case let .headeredHls(source, prepared):
      avTexture.lease = candidateTexture
      avBackend.bindCallbacks(candidateEvents.accept)
      if source["loadOptions"] == nil && !lastQualityConstraint.isEmpty {
        try avBackend.command(
          name: "setQualityConstraint",
          arguments: ["constraint": lastQualityConstraint]
        )
      }
      applyPersistentPlaybackControls(to: avBackend)
      try avBackend.stagePreparedHls(
        source: source,
        prepared: prepared,
        resume: reactivating
      )
      if slot.current !== avBackend {
        let previous = try slot.replace { avBackend }
        if previous !== avBackend { previous.dispose() }
      } else if avBackend.isActive {
        try avBackend.commitStagedHlsIfActive()
      } else {
        try avBackend.activate()
      }
      lastCommittedSource = source
      if !reactivating, source["loadOptions"] != nil { lastQualityConstraint = stringMap(stringMap(source["loadOptions"])["videoConstraints"]) }
    case let .fallback(source, prepared):
      let qualityConstraint = try YlFallbackQualityConstraint(
        validating: reactivating || source["loadOptions"] == nil ? lastQualityConstraint : stringMap(stringMap(source["loadOptions"])["videoConstraints"])
      )
      let previous = try slot.replace {
        let backend = try YlFallbackBackend(
          playerId: playerId,
          services: services.borrowing(candidateTexture),
          configuration: configuration.forLoad(source),
          prepared: prepared,
          qualityConstraint: qualityConstraint,
          generation: slot.generation &+ 1,
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
      try backend.command(name: "open", arguments: ["source": source])
      lastCommittedSource = source
      if !reactivating, source["loadOptions"] != nil { lastQualityConstraint = stringMap(stringMap(source["loadOptions"])["videoConstraints"]) }
    }
    committed = true
  }

  private func applyPersistentPlaybackControls(to backend: YlPlaybackBackend) {
    try? backend.command(
      name: "setVolume",
      arguments: ["volume": lastVolume]
    )
    try? backend.command(
      name: "setPlaybackSpeed",
      arguments: ["speed": lastPlaybackSpeed]
    )
  }

  private func prepareFallback(
    source: [String: Any?],
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
    if !reactivating, source["loadOptions"] != nil {
      let options = stringMap(source["loadOptions"])
      try prepared.prepareForLoad(positionMs: int64(options["startPositionMs"]) ?? 0, autoplay: options["autoplay"] as? Bool ?? false)
    }
    return prepared
  }

  private func prepareHeaderedHls(
    source: [String: Any?],
    token: YlOpenCancellationToken
  ) throws -> YlPreparedHlsAsset {
    try token.throwIfCancelled()
    guard let uri = source["uri"] as? String,
          let url = URL(string: uri) else {
      throw NativePlayerError(
        category: "source",
        code: "source.invalid_uri",
        message: "A valid HLS URI is required."
      )
    }
    return try YlPreparedHlsAsset(
      originURL: url,
      headers: stringMap(source["headers"]).compactMapValues { $0 as? String },
      credentials: stringMap(source["credentials"]).compactMapValues { $0 as? String },
      configuration: configuration.network,
      cancellationToken: token
    )
  }

  private func route(for source: [String: Any?]) -> YlAppleSourceRoute {
    YlSourceRouter.route(source)
  }

  private static func commandError(_ error: Error) -> NativePlayerError {
    NativePlayerError(
      category: "internal",
      code: "\(YlApplePlatform.current.rawValue).command_failed",
      message: "Apple player command failed.",
      diagnostic: String(describing: error)
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
              try self.slot.current.command(name: "play", arguments: [:])
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
        name: command.name,
        arguments: command.arguments,
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

  }

  deinit {
    dispose()
  }
}
