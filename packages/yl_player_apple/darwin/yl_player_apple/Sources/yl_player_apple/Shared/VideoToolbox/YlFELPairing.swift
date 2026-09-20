import Foundation

enum YlFELPairingError: Error {
  case missingTimestamp, duplicate, unregisteredFrame, capacityExceeded, missingEnhancement
}

/// PTS matching belongs to one decoder epoch. A missing EL never emits its BL.
/// The caller owns synchronization; completed pairs leave the queue immediately.
final class YlFELPairing<Frame, Metadata> {
  enum Side { case base, enhancement }
  struct Pair {
    let base: Frame
    let enhancement: Frame
    let metadata: Metadata
  }
  private struct Pending {
    let metadata: Metadata
    var base: Frame?
    var enhancement: Frame?
  }
  private let capacity: Int
  private var generation: UInt64 = 0
  private var pending: [Int64: Pending] = [:]

  init(capacity: Int = 32) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  func reset(generation: UInt64) {
    pending.removeAll(keepingCapacity: true)
    self.generation = generation
  }

  func register(pts: Int64, generation: UInt64, metadata: Metadata) throws {
    guard generation == self.generation else { return }
    guard pts != Int64.min else { throw YlFELPairingError.missingTimestamp }
    guard pending[pts] == nil else { throw YlFELPairingError.duplicate }
    guard pending.count < capacity else { throw YlFELPairingError.capacityExceeded }
    pending[pts] = Pending(metadata: metadata)
  }

  func receive(_ frame: Frame, side: Side, pts: Int64, generation: UInt64) throws -> Pair? {
    guard generation == self.generation else { return nil }
    guard var entry = pending[pts] else { throw YlFELPairingError.unregisteredFrame }
    switch side {
    case .base:
      guard entry.base == nil else { throw YlFELPairingError.duplicate }
      entry.base = frame
    case .enhancement:
      guard entry.enhancement == nil else { throw YlFELPairingError.duplicate }
      entry.enhancement = frame
    }
    if let base = entry.base, let enhancement = entry.enhancement {
      pending.removeValue(forKey: pts)
      return Pair(base: base, enhancement: enhancement, metadata: entry.metadata)
    }
    pending[pts] = entry
    return nil
  }

  func finish(generation: UInt64) throws {
    guard generation == self.generation else { return }
    guard pending.isEmpty else { throw YlFELPairingError.missingEnhancement }
  }
}
