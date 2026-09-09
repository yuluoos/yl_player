import CoreVideo
import Foundation

protocol YlPlaybackBackend: AnyObject {
  var isActive: Bool { get }
  var requiresExternalRollbackActivation: Bool { get }
  func activate() throws
  func finishReplacement()
  func quiesceForReplacement()
  func stop()
  func deactivate()
  func command(name: String, arguments: [String: Any?]) throws
  func emitState()
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>?
  func dispose()
}

extension YlPlaybackBackend {
  func finishReplacement() {}
  var requiresExternalRollbackActivation: Bool { false }
  func quiesceForReplacement() { deactivate() }
}

final class YlBackendSlot {
  private(set) var current: YlPlaybackBackend
  private(set) var generation: UInt64 = 1
  private let compatibility: YlAppleCompatibility
  private var disposed = false
  private var rollbackRequiresExternalActivation = false

  init(initial: YlPlaybackBackend, compatibility: YlAppleCompatibility = .current) {
    self.compatibility = compatibility
    current = initial
  }

  @discardableResult
  func replace(
    beforeRollbackActivation: ((YlPlaybackBackend) throws -> Void)? = nil,
    _ prepare: () throws -> YlPlaybackBackend
  ) throws -> YlPlaybackBackend {
    guard !disposed else {
      throw NativePlayerError(
        category: "resource",
        code: "\(YlApplePlatform.current.rawValue).player_disposed",
        message: "The \(YlApplePlatform.current.displayName) player has been disposed."
      )
    }
    rollbackRequiresExternalActivation = false
    let preparedBeforeQuiescing = compatibility.retainsReplacementHls ? try prepare() : nil
    let previous = current
    let previousWasActive = previous.isActive
    if previousWasActive || compatibility.retainsReplacementHls { previous.quiesceForReplacement() }
    defer { if compatibility.retainsReplacementHls { previous.finishReplacement() } }
    do {
      let candidate = try preparedBeforeQuiescing ?? prepare()
      do {
        try candidate.activate()
      } catch {
        candidate.dispose()
        throw error
      }
      current = candidate
      generation &+= 1
      return previous
    } catch {
      if previousWasActive || compatibility.retainsReplacementHls {
        if previous.requiresExternalRollbackActivation {
          rollbackRequiresExternalActivation = true
        } else {
          do {
            try beforeRollbackActivation?(previous)
            try previous.activate()
          } catch {
            rollbackRequiresExternalActivation = true
          }
        }
      }
      throw error
    }
  }

  func takeRollbackRequiresExternalActivation() -> Bool {
    defer { rollbackRequiresExternalActivation = false }
    return rollbackRequiresExternalActivation
  }

  func accepts(generation: UInt64) -> Bool {
    !disposed && self.generation == generation
  }

  func stop() {
    guard !disposed else { return }
    generation &+= 1
    rollbackRequiresExternalActivation = false
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

/// A private candidate retains only its latest initialized typed snapshot.
/// Its decoder markers never establish public texture publication.
final class YlAppleCommitEmitter {
  let identity: YlAppleSessionIdentity
  private let emit: (YlAppleSessionIdentity, YlNativeBackendCallback) -> Void
  private let lock = NSRecursiveLock()
  private var committed = false
  private var invalidated = false
  private var initialState: YlNativeBackendCallback?

  init(identity: YlAppleSessionIdentity,
       emit: @escaping (YlAppleSessionIdentity, YlNativeBackendCallback) -> Void) {
    self.identity = identity
    self.emit = emit
  }

  func accept(_ callback: YlNativeBackendCallback) {
    lock.lock()
    defer { lock.unlock() }
    guard !invalidated else { return }
    if committed { publish(callback) }
    else if case .state = callback.event { initialState = callback }
  }

  func commit() {
    lock.lock()
    defer { lock.unlock() }
    guard !invalidated else { return }
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

  private func publish(_ callback: YlNativeBackendCallback) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in self?.publish(callback) }
      return
    }
    lock.lock()
    defer { lock.unlock() }
    guard committed, !invalidated else { return }
    emit(identity, callback)
  }
}
