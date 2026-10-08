import Foundation

/// Tool-only experiment. ALL calls, output scheduling and completion delivery must
/// share one serial executor. Does not implement a production renderer, media
/// clock, route handling, converter/ledger admission, or physical output cursor.
final class AudioBoundaryPrototype<Payload> {
  enum Admission { case accepted, backpressure, invalid, finished }
  struct Ticket: Hashable { let generation: UInt64; let ordinal: UInt64 }
  struct Submission {
    let ticket: Ticket
    let payload: Payload
    let isBoundary: Bool
  }
  private struct Reservation {
    let bytes: Int
    let durationUs: Int64
    var resourcesReleased = false
  }
  private let groupSize: Int
  private let maxCount: Int
  private let maxBytes: Int
  private let maxDurationUs: Int64
  private var generation: UInt64 = 1
  private var ordinal: UInt64 = 0
  private var reservations: [Ticket: Reservation] = [:]
  private var groups: [Ticket: [Ticket]] = [:]
  private var members: [Ticket] = []
  private var tail: (Ticket, Payload)?
  private var outbox: [Submission] = []
  private(set) var inputFinished = false
  private(set) var pendingBytes = 0
  private(set) var pendingDurationUs: Int64 = 0
  private(set) var peakCount = 0
  var pendingCount: Int { reservations.count }
  var drained: Bool { inputFinished && reservations.isEmpty && outbox.isEmpty }

  init(groupSize: Int, maxCount: Int, maxBytes: Int, maxDurationUs: Int64) {
    precondition(groupSize > 0 && maxCount > 0 && maxBytes > 0 && maxDurationUs >= 0)
    self.groupSize = groupSize; self.maxCount = maxCount
    self.maxBytes = maxBytes; self.maxDurationUs = maxDurationUs
  }

  func enqueue(_ payload: Payload, bytes: Int, durationUs: Int64) -> Admission {
    guard !inputFinished else { return .finished }
    guard bytes > 0 && bytes <= maxBytes && durationUs >= 0 && durationUs <= maxDurationUs else {
      return .invalid
    }
    // Subtraction avoids overflow at Int.max, including synthetic zero durations.
    guard pendingCount < maxCount, bytes <= maxBytes - pendingBytes,
          durationUs <= maxDurationUs - pendingDurationUs else {
      sealBoundary() // A blocked producer cannot be relied upon to discover EOF.
      return .backpressure
    }
    if let previous = tail {
      outbox.append(.init(ticket: previous.0, payload: previous.1, isBoundary: false))
    }
    precondition(ordinal < UInt64.max)
    ordinal += 1
    let ticket = Ticket(generation: generation, ordinal: ordinal)
    reservations[ticket] = .init(bytes: bytes, durationUs: durationUs)
    pendingBytes += bytes; pendingDurationUs += durationUs
    peakCount = max(peakCount, pendingCount)
    members.append(ticket); tail = (ticket, payload)
    if members.count >= groupSize || pendingCount == maxCount || pendingBytes == maxBytes
        || pendingDurationUs == maxDurationUs { sealBoundary() }
    return .accepted
  }

  /// Also required when the producer stalls before filling a group. No timer or
  /// silence is inserted; the held real PCM becomes this group's actual tail.
  func sealBoundary() {
    guard let last = tail else { return }
    groups[last.0] = members
    outbox.append(.init(ticket: last.0, payload: last.1, isBoundary: true))
    tail = nil; members.removeAll(keepingCapacity: true)
  }

  func finishInput() {
    guard !inputFinished else { return }
    inputFinished = true; sealBoundary()
  }

  func takeSubmissions() -> [Submission] {
    let result = outbox; outbox.removeAll(keepingCapacity: true); return result
  }

  /// A render event does not change playback reservations or logical drain.
  func resourcesReleased(_ ticket: Ticket) {
    guard ticket.generation == generation, reservations[ticket] != nil else { return }
    reservations[ticket]?.resourcesReleased = true
  }

  /// Call ONLY from the real tail's dataPlayedBack notification. Retire exactly
  /// its sealed group, never infer delivery for another outstanding group.
  func playedBack(_ ticket: Ticket) {
    guard ticket.generation == generation, let completed = groups.removeValue(forKey: ticket) else { return }
    for member in completed {
      if let reservation = reservations.removeValue(forKey: member) {
        pendingBytes -= reservation.bytes; pendingDurationUs -= reservation.durationUs
      }
    }
  }

  /// Caller must stop/reset the output first, on the same serial executor.
  func resetAfterOutputStop() {
    precondition(generation < UInt64.max)
    generation += 1; ordinal = 0
    reservations.removeAll(); groups.removeAll(); members.removeAll()
    tail = nil; outbox.removeAll(); inputFinished = false
    pendingBytes = 0; pendingDurationUs = 0; peakCount = 0
  }
}
