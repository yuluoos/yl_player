import CoreVideo
import Foundation

protocol YlPlaybackBackend: AnyObject {
  var isActive: Bool { get }
  func activate() throws
  func quiesceForReplacement()
  func finishReplacement()
  func stop()
  func deactivate()
  func command(name: String, arguments: [String: Any?]) throws
  func emitState()
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>?
  func dispose()
}

extension YlPlaybackBackend {
  func quiesceForReplacement() { deactivate() }
  func finishReplacement() {}
}

final class YlBackendSlot {
  private(set) var current: YlPlaybackBackend
  private(set) var generation: UInt64 = 1
  private var disposed = false

  init(initial: YlPlaybackBackend) {
    current = initial
  }

  @discardableResult
  func replace(_ prepare: () throws -> YlPlaybackBackend) throws -> YlPlaybackBackend {
    guard !disposed else {
      throw NativePlayerError(
        category: "resource",
        code: "ios.player_disposed",
        message: "The iOS player has been disposed."
      )
    }
    let candidate = try prepare()
    let previous = current
    previous.quiesceForReplacement()
    do {
      try candidate.activate()
    } catch {
      candidate.dispose()
      // Always close the transaction, including a failed rollback activation.
      defer { previous.finishReplacement() }
      try? previous.activate()
      throw error
    }
    current = candidate
    generation &+= 1
    previous.finishReplacement()
    return previous
  }

  func accepts(generation: UInt64) -> Bool {
    !disposed && self.generation == generation
  }

  func stop() {
    guard !disposed else { return }
    generation &+= 1
    current.stop()
  }

  func dispose() {
    guard !disposed else { return }
    disposed = true
    current.dispose()
  }

  deinit {
    dispose()
  }
}

/// A private candidate cannot publish state or milestones until slot commit.
/// Its initialized full snapshot is retained; candidate first-frame markers are
/// discarded because they do not establish committed public-output evidence.
final class YlLegacyCommitEmitter {
  private let emit: ([String: Any?]) -> Void
  private let lock = NSRecursiveLock()
  private var committed = false
  private var invalidated = false
  private var generation: UInt64?
  private var initialState: [String: Any?]?

  init(emit: @escaping ([String: Any?]) -> Void) { self.emit = emit }

  func accept(_ event: [String: Any?]) {
    lock.lock()
    defer { lock.unlock() }
    guard !invalidated else { return }
    if committed { publish(event) }
    else if event["type"] as? String == "state" { initialState = event }
  }

  func commit(generation: UInt64? = nil) {
    lock.lock()
    defer { lock.unlock() }
    guard !invalidated else { return }
    self.generation = generation
    committed = true
    if let initialState { publish(initialState) }
    initialState = nil
  }

  func invalidate() {
    lock.lock()
    defer { lock.unlock() }
    invalidated = true
    initialState = nil
  }

  private func publish(_ event: [String: Any?]) {
    // Decide candidate visibility when the callback occurs, then fence again
    // when a background retry reaches the public main-thread channel.
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.publish(event) }
      return
    }
    lock.lock()
    defer { lock.unlock() }
    guard committed, !invalidated else { return }
    var value = event
    if value["generation"] == nil, let generation { value["generation"] = generation }
    emit(value)
  }
}
