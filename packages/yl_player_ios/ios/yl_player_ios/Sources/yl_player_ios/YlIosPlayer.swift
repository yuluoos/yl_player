import CoreVideo
import Flutter
import Foundation

final class YlIosPlayer: NSObject, FlutterTexture {
  let playerId: Int64
  var textureId: Int64 = -1 {
    didSet { avBackend.textureId = textureId }
  }
  var isActive: Bool { slot.current.isActive }

  private let textures: FlutterTextureRegistry
  private let configuration: PlayerConfiguration
  private let emit: ([String: Any?]) -> Void
  private let avBackend: YlAvPlayerBackend
  private let slot: YlBackendSlot
  private let openCoordinator = YlOpenCoordinator()
  private let commandCoordinator = YlAsyncCommandCoordinator()
  private var lastCommittedSource: [String: Any?]?
  private(set) var lastQualityConstraint: [String: Any?] = [:]
  private var disposed = false

  init(
    playerId: Int64,
    textures: FlutterTextureRegistry,
    configuration: PlayerConfiguration,
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
    self.textures = textures
    self.configuration = configuration
    self.emit = mainEmit
    let avBackend = YlAvPlayerBackend(
      playerId: playerId,
      textures: textures,
      configuration: configuration,
      emit: mainEmit
    )
    self.avBackend = avBackend
    self.slot = YlBackendSlot(initial: avBackend)
    super.init()
  }

  func beginOpen(
    _ source: [String: Any?],
    didCommit: @escaping () -> Void,
    completion: @escaping (Result<Void, NativePlayerError>) -> Void
  ) {
    guard !disposed else {
      completion(.failure(NativePlayerError(
        category: "resource",
        code: "ios.player_disposed",
        message: "The iOS player has been disposed."
      )))
      return
    }
    openCoordinator.begin(
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
            code: "ios.player_disposed",
            message: "The iOS player has been disposed."
          )
        }
        try self.commit(candidate, reactivating: false)
        didCommit()
      },
      completion: completion
    )
  }

  func beginActivation(
    forcePlay: Bool,
    didCommit: @escaping () -> Void,
    completion: @escaping (Result<Void, NativePlayerError>) -> Void
  ) {
    guard !disposed else {
      completion(.failure(NativePlayerError(
        category: "resource",
        code: "ios.player_disposed",
        message: "The iOS player has been disposed."
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
          try self.commit(candidate, reactivating: true)
          didCommit()
        },
        completion: completion
      )
      return
    }

    guard let fallback = slot.current as? YlFallbackBackend,
          fallback.requiresAsyncActivation,
          let source = lastCommittedSource else {
      do {
        try slot.current.activate()
        didCommit()
        completion(.success(()))
      } catch let error as NativePlayerError {
        completion(.failure(error))
      } catch {
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
        try self.commit(candidate, reactivating: true)
        didCommit()
      },
      completion: completion
    )
  }

  func activate() throws {
    try slot.current.activate()
  }

  func deactivate() {
    commandCoordinator.cancelCurrent()
    openCoordinator.cancelCurrent()
    slot.current.deactivate()
  }

  func handleMemoryWarning() {
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
    if name == "stop" {
      commandCoordinator.cancelCurrent()
      openCoordinator.cancelCurrent()
      lastCommittedSource = nil
      // The persistent AV backend may hold an older source while fallback is current.
      if slot.current !== avBackend { avBackend.clearMediaForStop() }
      slot.stop()
      completion(.success(()))
      return
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
      if case .success = result, let qualityConstraint {
        self?.lastQualityConstraint = qualityConstraint
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
      let backend = try YlFallbackBackend(
        playerId: playerId,
        textureId: textureId,
        textures: textures,
        configuration: configuration,
        prepared: prepared,
        qualityConstraint: qualityConstraint,
        generation: slot.generation &+ 1,
        emit: emit
      )
      let previous = try slot.replace { backend }
      if previous !== avBackend { previous.dispose() }
      try backend.command(name: "open", arguments: ["source": source])
      lastCommittedSource = source
    }
  }

  private func prepareFallback(
    source: [String: Any?],
    token: YlOpenCancellationToken
  ) throws -> YlPreparedFallback {
    try YlPreparedFallback(
      source: source,
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

  private func route(for source: [String: Any?]) -> YlIosSourceRoute {
    let headers = stringMap(source["headers"]).compactMapValues { $0 as? String }
    return YlSourceRouter.route(YlIosSourceDescriptor(
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
      code: "ios.command_failed",
      message: "iOS player command failed.",
      diagnostic: String(describing: error)
    )
  }

  func emitState() {
    slot.current.emitState()
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
