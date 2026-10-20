import yl_player_media_core
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
  func play() throws
  func pause() throws
  func seek(toMs: Int64, cancellationToken: YlOpenCancellationToken?) throws
  func seekToLiveEdge() throws
  func setLivePlaybackMode(_ mode: YlNativeLiveMode, requestId: Int64) throws -> YlNativeLivePlayback
  func setPlaybackSpeed(_ speed: Float) throws
  func setVolume(_ volume: Float) throws
  func selectAudioTrack(_ trackId: String, cancellationToken: YlOpenCancellationToken?) throws
  func setVideoConstraints(_ constraints: YlAppleVideoConstraints) throws
  func requiresAsyncCommand(_ command: YlApplePlaybackCommand) -> Bool
  func emitState()
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>?
  func dispose()
}

extension YlPlaybackBackend {
  func requiresAsyncCommand(_ command: YlApplePlaybackCommand) -> Bool { false }
  func setLivePlaybackMode(_ mode: YlNativeLiveMode, requestId: Int64) throws -> YlNativeLivePlayback {
    throw YlNativeLivePlayback.unsupported
  }
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
    requiresExclusiveResources: Bool = false,
    beforeRollbackActivation: ((YlPlaybackBackend) throws -> Void)? = nil,
    afterActivation: ((YlPlaybackBackend) throws -> Void)? = nil,
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
    // Retaining an HLS candidate must not retain a managed decoder's unique lease.
    let preparesWhileRetaining = compatibility.retainsReplacementHls && !requiresExclusiveResources
    let preparedBeforeQuiescing = preparesWhileRetaining ? try prepare() : nil
    let previous = current
    let previousWasActive = previous.isActive
    if previousWasActive || compatibility.retainsReplacementHls { previous.quiesceForReplacement() }
    defer { if compatibility.retainsReplacementHls { previous.finishReplacement() } }
    do {
      let candidate = try preparedBeforeQuiescing ?? prepare()
      do {
        try candidate.activate()
        try afterActivation?(candidate)
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

  /// Transfer the candidate's current full state to the mode commit barrier;
  /// committing the emitter must not replay an older candidate snapshot later.
  func takeInitialSnapshot() -> YlNativeState? {
    lock.lock(); defer { lock.unlock() }
    guard !committed, !invalidated, let callback = initialState,
          case .state(let value) = callback.event else { return nil }
    initialState = nil
    return value
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

/// Queue entries retain intent and identity validation, never a backend that a
/// preceding same-session mode transaction may replace.
struct YlQueuedPlaybackCommand {
  let command: YlApplePlaybackCommand
  let resolve: () throws -> YlPlaybackBackend
  private func onMain<T>(_ work: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try work() }
    return try DispatchQueue.main.sync(execute: work)
  }
  func run(_ token: YlOpenCancellationToken) throws {
    let backend = try onMain { try token.throwIfCancelled(); return try resolve() }
    let background = onMain { backend.requiresAsyncCommand(command) }
    let fallback = backend as? YlFallbackBackend
    token.onCancel { [weak fallback] in fallback?.interruptControlOperation() }
    defer { fallback?.resumeControlOperation() }
    try token.throwIfCancelled()
    if background {
      try command.apply(to: backend, cancellationToken: token)
    } else {
      try onMain {
        try token.throwIfCancelled()
        guard try resolve() === backend else { throw YlOpenCancellationToken.cancellationError() }
        // An inactive timeline seek only records retained intent on main. Track
        // changes still need their activity checks even when they perform no I/O.
        if case .seek = command, !backend.isActive {
          try command.apply(to: backend)
        } else {
          try command.apply(to: backend, cancellationToken: token)
        }
      }
    }
  }
}
