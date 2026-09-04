import Foundation

enum YlPreparedOpen {
  case avPlayer(source: [String: Any?])
  case headeredHls(source: [String: Any?], prepared: YlPreparedHlsAsset)
  case fallback(source: [String: Any?], prepared: YlPreparedFallback)

  func discard() {
    switch self {
    case .avPlayer:
      break
    case let .headeredHls(_, prepared):
      prepared.discard()
    case let .fallback(_, prepared):
      prepared.discard()
    }
  }
}

final class YlOpenCancellationToken {
  private let lock = NSLock()
  private var cancelled = false
  private var handlers: [() -> Void] = []

  var isCancelled: Bool {
    lock.withLock { cancelled }
  }

  func onCancel(_ handler: @escaping () -> Void) {
    let invokeNow = lock.withLock { () -> Bool in
      guard !cancelled else { return true }
      handlers.append(handler)
      return false
    }
    if invokeNow { handler() }
  }

  func cancel() {
    let pending = lock.withLock { () -> [() -> Void] in
      guard !cancelled else { return [] }
      cancelled = true
      defer { handlers.removeAll() }
      return handlers
    }
    pending.forEach { $0() }
  }

  func throwIfCancelled() throws {
    if isCancelled { throw Self.cancellationError() }
  }

  static func cancellationError() -> NativePlayerError {
    NativePlayerError(
      category: "cancelled",
      code: "network.cancelled",
      message: "The media open was cancelled."
    )
  }
}

final class YlOpenCoordinator {
  typealias Preparation = (YlOpenCancellationToken) throws -> YlPreparedOpen
  typealias Commit = (YlPreparedOpen) throws -> Void
  typealias Completion = (Result<Void, NativePlayerError>) -> Void

  private final class Operation {
    let generation: UInt64
    let token = YlOpenCancellationToken()
    let completion: Completion
    private let lock = NSLock()
    private var completed = false

    init(generation: UInt64, completion: @escaping Completion) {
      self.generation = generation
      self.completion = completion
    }

    func claimCompletion() -> Bool {
      lock.withLock {
        guard !completed else { return false }
        completed = true
        return true
      }
    }

    var isCompleted: Bool {
      lock.withLock { completed }
    }
  }

  private let preparationQueue: DispatchQueue
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var current: Operation?

  init(label: String = "dev.ylplayer.ios.open") {
    preparationQueue = DispatchQueue(label: label, qos: .userInitiated)
  }

  @discardableResult
  func begin(
    prepare: @escaping Preparation,
    commit: @escaping Commit,
    completion: @escaping Completion
  ) -> UInt64 {
    let values = lock.withLock { () -> (Operation?, Operation) in
      generation &+= 1
      let operation = Operation(generation: generation, completion: completion)
      let previous = current
      current = operation
      return (previous, operation)
    }

    if let previous = values.0 {
      previous.token.cancel()
      finish(previous, result: .failure(YlOpenCancellationToken.cancellationError()))
    }

    let operation = values.1
    preparationQueue.async { [weak self] in
      guard let self else { return }
      do {
        try operation.token.throwIfCancelled()
        let candidate = try prepare(operation.token)
        try operation.token.throwIfCancelled()
        DispatchQueue.main.async { [weak self] in
          guard let self else {
            candidate.discard()
            return
          }
          self.commit(candidate, for: operation, using: commit)
        }
      } catch {
        operation.token.cancel()
        self.finish(operation, result: .failure(Self.nativeError(error)))
      }
    }
    return operation.generation
  }

  func cancelCurrent() {
    let operation = lock.withLock { current }
    guard let operation else { return }
    operation.token.cancel()
    finish(operation, result: .failure(YlOpenCancellationToken.cancellationError()))
  }

  private func commit(
    _ candidate: YlPreparedOpen,
    for operation: Operation,
    using commit: Commit
  ) {
    let isCurrent = lock.withLock { current === operation }
    guard isCurrent, !operation.isCompleted, !operation.token.isCancelled else {
      candidate.discard()
      finish(operation, result: .failure(YlOpenCancellationToken.cancellationError()))
      return
    }
    do {
      try commit(candidate)
      finish(operation, result: .success(()))
    } catch {
      operation.token.cancel()
      candidate.discard()
      finish(operation, result: .failure(Self.nativeError(error)))
    }
  }

  private func finish(
    _ operation: Operation,
    result: Result<Void, NativePlayerError>
  ) {
    let finalize = {
      guard operation.claimCompletion() else { return }
      self.lock.withLock {
        if self.current === operation { self.current = nil }
      }
      operation.completion(result)
    }
    if Thread.isMainThread { finalize() }
    else { DispatchQueue.main.async(execute: finalize) }
  }

  fileprivate static func nativeError(_ error: Error) -> NativePlayerError {
    if let error = error as? NativePlayerError { return error }
    return NativePlayerError(
      category: "internal",
      code: "ios.command_failed",
      message: "iOS player command failed.",
      diagnostic: String(describing: error)
    )
  }
}

final class YlAsyncCommandCoordinator {
  typealias OperationBody = (YlOpenCancellationToken) throws -> Void
  typealias Completion = (Result<Void, NativePlayerError>) -> Void

  private final class Operation {
    let token = YlOpenCancellationToken()
    let completion: Completion
    private let lock = NSLock()
    private var completed = false

    init(completion: @escaping Completion) {
      self.completion = completion
    }

    func claimCompletion() -> Bool {
      lock.withLock {
        guard !completed else { return false }
        completed = true
        return true
      }
    }
  }

  private let queue: DispatchQueue
  private let lock = NSLock()
  private var operations: [Operation] = []

  var hasCurrent: Bool {
    lock.withLock { !operations.isEmpty }
  }

  init(label: String = "dev.ylplayer.ios.command") {
    queue = DispatchQueue(label: label, qos: .userInitiated)
  }

  func begin(
    operation body: @escaping OperationBody,
    completion: @escaping Completion
  ) {
    let operation = Operation(completion: completion)
    lock.withLock { operations.append(operation) }

    queue.async {
      let result: Result<Void, NativePlayerError>
      do {
        try operation.token.throwIfCancelled()
        try body(operation.token)
        try operation.token.throwIfCancelled()
        result = .success(())
      } catch {
        result = .failure(YlOpenCoordinator.nativeError(error))
      }
      self.finish(operation, result: result)
    }
  }

  func cancelCurrent() {
    let pending = lock.withLock { operations }
    pending.forEach { $0.token.cancel() }
  }

  private func finish(
    _ operation: Operation,
    result: Result<Void, NativePlayerError>
  ) {
    DispatchQueue.main.async {
      guard operation.claimCompletion() else { return }
      self.lock.withLock {
        self.operations.removeAll { $0 === operation }
      }
      let deliveredResult = operation.token.isCancelled
        ? Result.failure(YlOpenCancellationToken.cancellationError())
        : result
      operation.completion(deliveredResult)
    }
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
