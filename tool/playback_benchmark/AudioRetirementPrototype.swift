import Foundation

/// Experimental host-clock retirement model, confined to one caller queue.
/// Not linked into the player. Evidence validity must be established by an adapter.
final class AudioRetirementPrototype {
  struct Evidence {
    let observedUs: UInt64
    let downstreamUs: UInt64
    let quantumUs: UInt64
    let route: UInt64
  }
  enum Failure: String {
    case unknownLatency, staleEvidence, routeChanged, clockRegressed
    case invalidTimestamp, capacityExceeded, overflow
  }
  final class Ticket {
    fileprivate enum State { case fresh, waiting, ready, finished, cancelled }
    let generation: UInt64
    fileprivate var state = State.fresh
    fileprivate var body: (() -> Void)?
    fileprivate var renderedUs: UInt64 = 0
    fileprivate var deadlineUs: UInt64 = 0
    init(generation: UInt64, body: @escaping () -> Void) {
      self.generation = generation
      self.body = body
    }
  }

  private(set) var generation: UInt64
  private var route: UInt64
  private let capacity: Int
  private let maxEvidenceAgeUs: UInt64
  private var lastNow: UInt64?
  private var evidence: Evidence?
  private var pending: [Ticket] = []
  private(set) var failure: Failure?
  private(set) var peakPending = 0
  var pendingCount: Int { pending.count }

  init(generation: UInt64, route: UInt64, capacity: Int = 64,
       maxEvidenceAgeUs: UInt64 = 100_000) {
    precondition(capacity > 0 && maxEvidenceAgeUs > 0)
    self.generation = generation
    self.route = route
    self.capacity = capacity
    self.maxEvidenceAgeUs = maxEvidenceAgeUs
  }

  private func clock(_ now: UInt64) -> Bool {
    if let lastNow, now < lastNow { failure = failure ?? .clockRegressed }
    lastNow = max(lastNow ?? now, now)
    return failure == nil
  }

  private func delay(_ value: Evidence, now: UInt64) -> UInt64? {
    guard value.route == route else { failure = .routeChanged; return nil }
    guard value.downstreamUs > 0, value.quantumUs > 0 else { failure = .unknownLatency; return nil }
    guard value.observedUs <= now else { failure = .invalidTimestamp; return nil }
    guard now-value.observedUs <= maxEvidenceAgeUs else { failure = .staleEvidence; return nil }
    let sum = value.downstreamUs.addingReportingOverflow(value.quantumUs)
    guard !sum.overflow else { failure = .overflow; return nil }
    return sum.partialValue
  }

  private func deadline(_ rendered: UInt64, _ duration: UInt64) -> UInt64? {
    let end = rendered.addingReportingOverflow(duration)
    guard !end.overflow else { failure = .overflow; return nil }
    return end.partialValue
  }

  func observe(_ value: Evidence?, nowUs: UInt64) {
    guard clock(nowUs) else { return }
    guard let value else { failure = .unknownLatency; return }
    guard let duration = delay(value, now: nowUs) else { return }
    evidence = value
    for ticket in pending {
      guard let end = deadline(ticket.renderedUs, duration) else { return }
      if end > ticket.deadlineUs {
        ticket.deadlineUs = end
        // A later evidence update may revoke an undelivered ready callback.
        if ticket.state == .ready { ticket.state = .waiting }
      }
    }
  }

  @discardableResult
  func rendered(_ ticket: Ticket, atUs: UInt64, nowUs: UInt64) -> Bool {
    guard ticket.generation == generation, ticket.state == .fresh else { return false }
    guard clock(nowUs) else { return false }
    guard atUs <= nowUs else { failure = .invalidTimestamp; return false }
    guard let evidence else { failure = .unknownLatency; return false }
    guard let duration = delay(evidence, now: nowUs), let end = deadline(atUs, duration) else { return false }
    guard pending.count < capacity else { failure = .capacityExceeded; return false }
    ticket.renderedUs = atUs
    ticket.deadlineUs = end
    ticket.state = .waiting
    pending.append(ticket)
    peakPending = max(peakPending, pending.count)
    return true
  }

  /// The caller must invoke returned callbacks on the same owner queue.
  func poll(nowUs: UInt64) -> [() -> Void] {
    guard clock(nowUs), !pending.isEmpty else { return [] }
    guard let evidence else { failure = .unknownLatency; return [] }
    guard delay(evidence, now: nowUs) != nil else { return [] }
    return pending.filter { $0.state == .waiting && $0.deadlineUs <= nowUs }.map { ticket in
      ticket.state = .ready
      return { [weak self] in self?.deliver(ticket) }
    }
  }

  private func deliver(_ ticket: Ticket) {
    guard failure == nil, ticket.generation == generation, ticket.state == .ready else { return }
    ticket.state = .finished
    pending.removeAll { $0 === ticket }
    let body = ticket.body
    ticket.body = nil
    body?() // State mutation is complete before reentrant client work.
  }

  /// Call only after the output has actually stopped; never a periodic cleanup.
  func resetAfterOutputStop(generation: UInt64, route: UInt64, nowUs: UInt64) {
    let cancelled = pending
    pending = []
    self.generation = generation
    self.route = route
    evidence = nil
    failure = nil
    lastNow = nowUs
    for ticket in cancelled { ticket.state = .cancelled }
    // Invalidate every ticket before dropping bodies that may run deinitializers.
    for ticket in cancelled { ticket.body = nil }
  }
}
