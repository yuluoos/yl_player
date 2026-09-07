import CoreVideo
import Foundation

protocol YlPlaybackBackend: AnyObject {
  var isActive: Bool { get }
  func activate() throws
  func quiesceForReplacement()
  func stop()
  func deactivate()
  func command(name: String, arguments: [String: Any?]) throws
  func emitState()
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>?
  func dispose()
}

extension YlPlaybackBackend {
  func quiesceForReplacement() { deactivate() }
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
      try? previous.activate()
      throw error
    }
    current = candidate
    generation &+= 1
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
