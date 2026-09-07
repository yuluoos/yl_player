import AppKit
import CoreVideo
import FlutterMacOS
import Foundation

final class YlMacosPlayer: NSObject, FlutterTexture {
  private struct DeferredRestorationCommand {
    let name: String
    let arguments: [String: Any?]
    let completion: (Result<Void, NativePlayerError>) -> Void
  }

  let playerId: Int64
  var textureId: Int64 = -1 {
    didSet { avBackend.textureId = textureId }
  }
  var isActive: Bool { slot.current.isActive }

  private weak var displayView: NSView?
  private let textures: FlutterTextureRegistry
  private let configuration: PlayerConfiguration
  private let emit: ([String: Any?]) -> Void
  private let avBackend: YlAvPlayerBackend
  private let slot: YlBackendSlot
  private let openCoordinator = YlOpenCoordinator()
  private let commandCoordinator = YlAsyncCommandCoordinator()
  private var lastCommittedSource: [String: Any?]?
  private(set) var lastQualityConstraint: [String: Any?] = [:]
  private var lastVolume: Float = 1
  private var lastPlaybackSpeed: Float = 1
  private var disposed = false
  private var hardwareRollbackPlaybackIntent: Bool?
  private var restorationGeneration: UInt64 = 0
  private var activeRestorationGeneration: UInt64?
  private var deferredRestorationCommands = [DeferredRestorationCommand]()

  init(
    playerId: Int64,
    textures: FlutterTextureRegistry,
    configuration: PlayerConfiguration,
    displayView: NSView? = nil,
    emit: @escaping ([String: Any?]) -> Void
  ) {
    let mainEmit: ([String: Any?]) -> Void = { event in
      if Thread.isMainThread {
        emit(event)
      } else {
        DispatchQueue.main.async { emit(event) }
      }
    }
    self.playerId = playerId
    self.displayView = displayView
    self.textures = textures
    self.configuration = configuration
    self.emit = mainEmit
    let avBackend = YlAvPlayerBackend(
      playerId: playerId,
      textures: textures,
      configuration: configuration,
      displayView: displayView,
      emit: mainEmit
    )
    self.avBackend = avBackend
    self.slot = YlBackendSlot(initial: avBackend)
    super.init()
  }

  func beginOpen(
    _ source: [String: Any?],
    willCommit: @escaping (Bool) -> Void,
    didCommit: @escaping () -> Void,
    didRollback: @escaping () -> Void,
    completion: @escaping (Result<Void, NativePlayerError>) -> Void
  ) {
    guard !disposed else {
      completion(.failure(NativePlayerError(
        category: "resource",
        code: "macos.player_disposed",
        message: "The macOS player has been disposed."
      )))
      return
    }
    restorationGeneration &+= 1
    activeRestorationGeneration = nil
    cancelDeferredRestorationCommands()
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
            prepared: try self.prepareFallback(source: source, token: token)
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
            code: "macos.player_disposed",
            message: "The macOS player has been disposed."
          )
        }
        let rollbackPlaybackIntent = self.currentPlaybackIntent
        willCommit(candidate.requiresHardwareDecoderLease)
        do {
          try self.commit(candidate, reactivating: false)
          didCommit()
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
      completion: completion
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
        code: "macos.player_disposed",
        message: "The macOS player has been disposed."
      )))
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
            try self.commit(candidate, reactivating: true)
            didCommit()
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
        let prepared = try self.prepareFallback(source: source, token: token)
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
          try self.commit(candidate, reactivating: true)
          didCommit()
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

  func beginCommand(
    name: String,
    arguments: [String: Any?],
    completion: @escaping (Result<Void, NativePlayerError>) -> Void
  ) {
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
    reactivating: Bool
  ) throws {
    commandCoordinator.cancelCurrent()
    switch candidate {
    case let .avPlayer(source):
      if !lastQualityConstraint.isEmpty {
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
    case let .headeredHls(source, prepared):
      if !lastQualityConstraint.isEmpty {
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
    case let .fallback(source, prepared):
      let qualityConstraint = try YlFallbackQualityConstraint(
        validating: lastQualityConstraint
      )
      let previous = try slot.replace {
        let backend = try YlFallbackBackend(
          playerId: playerId,
          textureId: textureId,
          textures: textures,
          configuration: configuration,
          prepared: prepared,
          qualityConstraint: qualityConstraint,
          generation: slot.generation &+ 1,
          displayView: displayView,
          emit: emit
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
    }
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
    token: YlOpenCancellationToken
  ) throws -> YlPreparedFallback {
    try YlPreparedFallback(
      source: source,
      requireHardwareProbe: false,
      configuration: configuration,
      cancellationToken: token,
      onRetry: { [weak self] attempt, delayMs, error in
        DispatchQueue.main.async {
          guard let self, !self.disposed, !token.isCancelled else { return }
          self.emit(YlFallbackRetryEvent.envelope(
            playerId: self.playerId,
            attempt: attempt,
            delayMs: delayMs,
            error: error
          ))
        }
      }
    )
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
      configuration: configuration.network,
      cancellationToken: token
    )
  }

  private func route(for source: [String: Any?]) -> YlMacosSourceRoute {
    let headers = stringMap(source["headers"]).compactMapValues { $0 as? String }
    return YlSourceRouter.route(YlMacosSourceDescriptor(
      uri: source["uri"] as? String ?? "",
      kind: source["kind"] as? String ?? "",
      formatHint: source["formatHint"] as? String ?? "automatic",
      isLive: source["isLive"] as? Bool ?? false,
      hasHeaders: !headers.isEmpty
    ))
  }

  private static func commandError(_ error: Error) -> NativePlayerError {
    NativePlayerError(
      category: "internal",
      code: "macos.command_failed",
      message: "macOS player command failed.",
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

  private var currentPlaybackIntent: Bool {
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
    emit([
      "playerId": playerId,
      "type": "error",
      "error": errorMap(
        category: error.category,
        code: error.code,
        message: error.message,
        diagnostic: error.diagnostic
      ),
    ])
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    slot.current.copyPixelBuffer()
  }

  func dispose() {
    guard !disposed else { return }
    disposed = true
    restorationGeneration &+= 1
    activeRestorationGeneration = nil
    cancelDeferredRestorationCommands()
    commandCoordinator.cancelCurrent()
    openCoordinator.cancelCurrent()
    avBackend.textureId = -1
    let current = slot.current
    slot.dispose()
    if current !== avBackend { avBackend.dispose() }
    if textureId >= 0 {
      textures.unregisterTexture(textureId)
      textureId = -1
    }
  }

  deinit {
    dispose()
  }
}
