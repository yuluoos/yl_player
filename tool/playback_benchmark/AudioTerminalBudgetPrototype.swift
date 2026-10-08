import Foundation

/// Tool-only independent upstream-budget/final-drain experiment. The owner must
/// serialize admission, scheduling, notifications and reset after output stop.
/// Does not bound undocumented downstream allocations or implement media clocks.
final class AudioTerminalBudgetPrototype<Payload> {
  enum Admission { case accepted, backpressure, insufficientLookahead, ledgerLimited, timelineLimited, invalid, finished }
  enum FallbackReason { case tailWait, clockRegression }
  struct Ticket: Hashable { let generation: UInt64; let ordinal: UInt64 }
  fileprivate final class Resource {
    var payload: Payload?
    var requiresPlayback = false
    let token: YlManagedBufferLedger.Token
    let bytes: Int
    let durationUs: Int64
    init(_ payload: Payload, token: YlManagedBufferLedger.Token, bytes: Int, durationUs: Int64) {
      self.payload = payload; self.token = token; self.bytes = bytes; self.durationUs = durationUs
    }
    deinit { retire() }
    func retire() {
      // Submission handles share this owner, not separate strong PCM captures.
      // Only actual rendered/final playedBack (or stopped reset) authorizes this.
      payload = nil
      token.release()
    }
  }
  struct Submission {
    let ticket: Ticket
    let isTerminal: Bool
    fileprivate let resource: Resource
    var payload: Payload? { resource.payload }
    var usesPlayedBack: Bool { resource.requiresPlayback }
  }
  private let scope: YlManagedBufferScope
  private let maxTailWaitUs: UInt64
  private var waitStartedUs: UInt64?
  private var lastObservationUs: UInt64?
  private var lastTicket: Ticket?
  private var lastPlayedBack = false
  private(set) var fallbackReason: FallbackReason?
  var fallbackCount: Int { fallbackReason == nil ? 0 : 1 }
  private let maxCount: Int
  private let maxBytes: Int
  private let maxDurationUs: Int64
  private var generation: UInt64 = 1
  private var ordinal: UInt64 = 0
  private var resources: [Ticket: Resource] = [:]
  private var tail: Ticket?
  private var terminal: Ticket?
  private var terminalDelivered = false
  private var outbox: [Submission] = []
  private(set) var inputFinished = false
  private(set) var pendingBytes = 0
  private(set) var pendingDurationUs: Int64 = 0
  private(set) var peakCount = 0
  var pendingCount: Int { resources.count }
  var drained: Bool { inputFinished && (ordinal == 0 || terminalDelivered) && resources.isEmpty && outbox.isEmpty }

  init(scope: YlManagedBufferScope, maxCount: Int, maxBytes: Int, maxDurationUs: Int64, maxTailWaitUs: UInt64 = 100_000) {
    precondition(maxTailWaitUs > 0)
    self.maxTailWaitUs = maxTailWaitUs
    precondition(maxCount > 0 && maxBytes > 0 && maxDurationUs > 0)
    self.scope = scope; self.maxCount = maxCount; self.maxBytes = maxBytes; self.maxDurationUs = maxDurationUs
  }

  func enqueue(ptsUs: Int64, durationUs: Int64, bytes: Int, makePayload: () -> Payload) -> Admission {
    guard !inputFinished else { return .finished }
    guard bytes > 0 && bytes <= maxBytes && durationUs > 0 && durationUs <= maxDurationUs,
          ptsUs >= 0, !ptsUs.addingReportingOverflow(durationUs).overflow else { return .invalid }
    guard pendingCount < maxCount && bytes <= maxBytes - pendingBytes && durationUs <= maxDurationUs - pendingDurationUs else {
      // With only an unscheduled tail, there is no callback that could free room.
      return tail != nil && pendingCount == 1 ? .insufficientLookahead : .backpressure
    }
    guard let token = scope.reserve(category: .scheduledAudio, bytes: bytes) else { return .ledgerLimited }
    guard token.carryTiming(ptsUs: ptsUs, durationUs: durationUs) else {
      token.release(); return .timelineLimited
    }
    let resource = Resource(makePayload(), token: token, bytes: bytes, durationUs: durationUs)
    if let previous = tail, let previousResource = resources[previous] {
      outbox.append(.init(ticket: previous, isTerminal: false, resource: previousResource))
    }
    precondition(ordinal < UInt64.max); ordinal += 1
    let ticket = Ticket(generation: generation, ordinal: ordinal)
    resources[ticket] = resource; lastTicket = ticket; lastPlayedBack = false; waitStartedUs = nil
    if fallbackReason != nil {
      resource.requiresPlayback = true
      outbox.append(.init(ticket: ticket, isTerminal: false, resource: resource))
    } else { tail = ticket }
    pendingBytes += bytes; pendingDurationUs += durationUs; peakCount = max(peakCount, pendingCount)
    return .accepted
  }

  /// Caller polls on its serial executor. The threshold selects a scheduling
  /// mode only: it never reports playback completion or releases a reservation.
  /// A pause or queued work starts a fresh continuous-starvation window.
  func observePlayback(playing: Bool, nowUs: UInt64) {
    guard !inputFinished, fallbackReason == nil else { return }
    if let last = lastObservationUs, nowUs < last { useLegacyCompletion(.clockRegression); return }
    lastObservationUs = nowUs
    guard playing, tail != nil, pendingCount == 1 else { waitStartedUs = nil; return }
    if waitStartedUs == nil { waitStartedUs = nowUs }
    if nowUs - waitStartedUs! >= maxTailWaitUs { useLegacyCompletion(.tailWait) }
  }
  private func useLegacyCompletion(_ reason: FallbackReason) {
    guard fallbackReason == nil else { return }
    fallbackReason = reason; waitStartedUs = nil
    if let held = tail, let resource = resources[held] {
      resource.requiresPlayback = true
      outbox.append(.init(ticket: held, isTerminal: false, resource: resource))
      tail = nil
    }
  }

  /// Without observation calls this remains the original unlimited-wait model.
  /// The native policy driver must provide observations while playing/paused.
  func finishInput() {
    guard !inputFinished else { return }
    inputFinished = true
    if let last = tail, let resource = resources[last] {
      terminal = last; tail = nil; resource.requiresPlayback = true
      outbox.append(.init(ticket: last, isTerminal: true, resource: resource))
    } else if fallbackReason != nil {
      terminal = lastTicket; terminalDelivered = lastPlayedBack
    }
  }
  func takeSubmissions() -> [Submission] {
    let result = outbox; outbox.removeAll(keepingCapacity: true); return result
  }
  func rendered(_ ticket: Ticket) {
    guard ticket.generation == generation, ticket != tail, resources[ticket]?.requiresPlayback == false else { return }
    retire(ticket)
  }
  func playedBack(_ ticket: Ticket) {
    guard ticket.generation == generation, resources[ticket]?.requiresPlayback == true else { return }
    if ticket == lastTicket { lastPlayedBack = true }
    if ticket == terminal { terminalDelivered = true }
    retire(ticket)
  }
  private func retire(_ ticket: Ticket) {
    guard let resource = resources.removeValue(forKey: ticket) else { return }
    pendingBytes -= resource.bytes; pendingDurationUs -= resource.durationUs
    resource.retire()
  }
  func resetAfterOutputStop() {
    let old = Array(resources.values)
    precondition(generation < UInt64.max); generation += 1; ordinal = 0
    resources.removeAll(); tail = nil; terminal = nil; terminalDelivered = false
    fallbackReason = nil; waitStartedUs = nil; lastObservationUs = nil; lastTicket = nil; lastPlayedBack = false
    outbox.removeAll(); inputFinished = false; pendingBytes = 0; pendingDurationUs = 0; peakCount = 0
    old.forEach { $0.retire() }
  }
}
