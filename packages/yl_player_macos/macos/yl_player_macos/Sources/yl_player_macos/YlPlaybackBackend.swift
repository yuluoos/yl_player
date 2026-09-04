import CoreVideo
import Foundation

protocol YlPlaybackBackend: AnyObject {
  var isActive: Bool { get }
  var requiresExternalRollbackActivation: Bool { get }
  func activate() throws
  func quiesceForReplacement()
  func deactivate()
  func command(name: String, arguments: [String: Any?]) throws
  func emitState()
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>?
  func dispose()
}

extension YlPlaybackBackend {
  var requiresExternalRollbackActivation: Bool { false }
  func quiesceForReplacement() { deactivate() }
}

final class YlBackendSlot {
  private(set) var current: YlPlaybackBackend
  private(set) var generation: UInt64 = 1
  private var disposed = false
  private var rollbackRequiresExternalActivation = false

  init(initial: YlPlaybackBackend) {
    current = initial
  }

  @discardableResult
  func replace(_ prepare: () throws -> YlPlaybackBackend) throws -> YlPlaybackBackend {
    guard !disposed else {
      throw NativePlayerError(
        category: "resource",
        code: "macos.player_disposed",
        message: "The macOS player has been disposed."
      )
    }
    rollbackRequiresExternalActivation = false
    let previous = current
    let previousWasActive = previous.isActive
    if previousWasActive { previous.quiesceForReplacement() }
    do {
      let candidate = try prepare()
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
      if previousWasActive {
        if previous.requiresExternalRollbackActivation {
          rollbackRequiresExternalActivation = true
        } else {
          do {
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

  func dispose() {
    guard !disposed else { return }
    disposed = true
    current.dispose()
  }

  deinit {
    dispose()
  }
}
