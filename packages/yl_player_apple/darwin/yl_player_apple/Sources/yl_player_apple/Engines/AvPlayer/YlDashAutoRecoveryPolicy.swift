import Foundation

struct YlDashAutoRecoveryPolicy {
  struct Variant: Equatable {
    let id: String, width: Int, height: Int
    let bandwidth: Double
  }
  struct Sample {
    let time: Double, generation: UInt64, allowed: Bool
    let catalog: [Variant], current: Variant?
    let position: Double, remaining: Double, bufferAhead: Double
    let bytes: Int64, transfer: Double, requests: Int, overdue: Int
    var intentRevision: UInt64 = 0
    var credentialRevision: UInt64 = 0
    var highFrameCount = 0
    var highFrameSeconds = 0.0
    var highFrameStart: Double?
  }
  struct Ticket {
    let id: UUID, generation: UInt64, attempt: Int, due: Double
    let intentRevision: UInt64, credentialRevision: UInt64
    let catalog: [Variant]
  }
  private(set) var attempts = 0
  private(set) var roundLimit = 2
  private var lastReservation: Double?
  private var lastInstallation: Double?
  private(set) var decision: [String: Any] = [:]
  private var generation: UInt64?
  private var intentRevision: UInt64?
  private var credentialRevision: UInt64?
  private var sawHigh = false
  private var catalog: [Variant] = []
  private var target: Variant?
  private var anchor: Sample?
  private var windows = 0
  private var last: Sample?
  private var pending: Ticket?
  private var inFlight: Ticket?
  static func contiguousAhead(position: Double, ranges: [(Double, Double)]) -> Double {
    guard position.isFinite, position >= 0 else { return 0 }
    var end = position
    for range in ranges.filter({ $0.0.isFinite && $0.1.isFinite && $0.1 >= $0.0 }).sorted(by: { $0.0 < $1.0 }) {
      if range.1 < position { continue }
      if range.0 > end { break }
      end = max(end, range.1)
    }
    return max(0, end - position)
  }
  mutating func invalidateIntent() {
    pending = nil; inFlight = nil; anchor = nil; windows = 0; last = nil
  }
  private func eligible(_ s: Sample) -> Bool {
    s.allowed && s.catalog.count >= 2 && Set(s.catalog.map(\.id)).count == s.catalog.count &&
      s.catalog.allSatisfy { $0.width > 0 && $0.height > 0 && $0.bandwidth.isFinite && $0.bandwidth > 0 } &&
      s.current.map { s.catalog.contains($0) } == true && s.time.isFinite && s.position.isFinite && s.remaining.isFinite &&
      s.bufferAhead.isFinite && s.transfer.isFinite && s.time >= 0 && s.position >= 0 &&
      s.transfer >= 0 && s.bytes >= 0 && s.requests >= 0 && s.remaining >= 20 && s.bufferAhead >= 5
  }
  mutating func observe(_ s: Sample) -> Ticket? {
    var reason = "invalidSample"
    var windowBitrate: Double?
    var windowRequests: Int?
    func finite(_ value: Double) -> Any { value.isFinite ? value as Any : NSNull() }
    defer {
      decision = ["elapsed": finite(s.time), "generation": s.generation, "intentRevision": s.intentRevision, "credentialRevision": s.credentialRevision, "allowed": s.allowed,
        "width": s.current?.width ?? 0, "position": finite(s.position), "remaining": finite(s.remaining),
        "bufferAhead": finite(s.bufferAhead), "bytes": s.bytes, "transfer": finite(s.transfer),
        "requests": s.requests, "overdue": s.overdue, "reason": reason, "attempts": attempts,
        "budgetVersion": 2, "roundLimit": roundLimit,
        "lastReservation": lastReservation.map(finite) ?? NSNull(),
        "lastInstallation": lastInstallation.map(finite) ?? NSNull(),
        "highFrameCount": s.highFrameCount, "highFrameSeconds": s.highFrameSeconds,
        "highFrameStart": s.highFrameStart.map(finite) ?? NSNull(),
        "qualifiedWindows": windows, "sawHigh": sawHigh,
        "windowBitrate": windowBitrate.map(finite) ?? NSNull(),
        "windowRequests": windowRequests as Any? ?? NSNull(),
        "pendingDue": pending.map { finite($0.due) } ?? NSNull()]
    }
    if generation != s.generation || catalog != s.catalog {
      catalog = s.catalog
      target = catalog.max { $0.bandwidth < $1.bandwidth }
      generation = s.generation; sawHigh = false; anchor = nil; windows = 0
      pending = nil; inFlight = nil; last = nil
    }
    if intentRevision != s.intentRevision { intentRevision = s.intentRevision; invalidateIntent() }
    if credentialRevision != s.credentialRevision { credentialRevision = s.credentialRevision; invalidateIntent() }
    guard eligible(s), last.map({ s.time > $0.time && s.position >= $0.position }) ?? true else {
      if !s.allowed { reason = "playbackIneligible" }
      else if s.bufferAhead.isFinite && s.bufferAhead < 5 { reason = "insufficientBuffer" }
      else if s.remaining.isFinite && s.remaining < 20 { reason = "nearEnd" }
      else if eligible(s) { reason = "nonMonotonic" }
      anchor = nil; windows = 0; pending = nil; inFlight = nil; last = nil; return nil
    }
    let previous = last
    last = s
    if s.current == target {
      reason = "highOutput"; sawHigh = true; anchor = nil; windows = 0; pending = nil
      if attempts == 2, let installed = lastInstallation, let start = s.highFrameStart,
         start >= installed, s.highFrameCount >= 48, s.highFrameSeconds >= 2 {
        roundLimit = 4
      }
      return nil
    }
    guard sawHigh, let target, let current = s.current, current.bandwidth < target.bandwidth, s.overdue > 0 else { reason = !sawHigh ? "highNotObserved" : (s.overdue == 0 ? "noOverdue" : "notLowOutput"); anchor = nil; windows = 0; pending = nil; return nil }
    if let previous, s.bytes < previous.bytes || s.transfer < previous.transfer || s.requests < previous.requests {
      reason = "countersReset"
      invalidateIntent(); anchor = s; last = s
      return nil
    }
    if let pending {
      guard s.time >= pending.due else { reason = "backoff"; return nil }
      reason = "ticketReady"
      self.pending = nil; inFlight = pending; return pending
    }
    guard inFlight == nil, attempts < roundLimit else { reason = inFlight != nil ? "inFlight" : "budgetExhausted"; return nil }
    guard let start = anchor else { reason = "windowStarted"; anchor = s; return nil }
    guard s.bytes >= start.bytes, s.transfer >= start.transfer, s.requests >= start.requests else {
      reason = "countersReset"; anchor = s; windows = 0; return nil
    }
    if windows == 2, let reserved = lastReservation, s.time >= reserved + 30,
       s.time - start.time < 8 {
      reason = "reserved"; reserve(s); return nil
    }
    guard s.time - start.time >= 8 else { reason = windows == 2 ? "cooldown" : "windowPending"; return nil }
    anchor = s
    let duration = s.transfer - start.transfer
    let bitrate = duration > 0 ? Double(s.bytes - start.bytes) * 8 / duration : 0
    windowBitrate = bitrate; windowRequests = s.requests - start.requests
    guard s.position > start.position, s.requests - start.requests >= 3,
          bitrate.isFinite, bitrate >= target.bandwidth * 1.25 else {
      reason = s.position <= start.position ? "noProgress" : (s.requests - start.requests < 3 ? "insufficientRequests" : "insufficientBandwidth")
      windows = 0; return nil
    }
    windows = min(2, windows + 1)
    guard windows >= 2 else { reason = "firstQualifiedWindow"; return nil }
    if let reserved = lastReservation, s.time < reserved + 30 { reason = "cooldown"; return nil }
    reason = "reserved"
    reserve(s)
    return nil
  }
  private mutating func reserve(_ s: Sample) {
    attempts += 1; windows = 0; anchor = nil
    lastReservation = s.time
    pending = Ticket(id: UUID(), generation: s.generation, attempt: attempts,
      due: s.time + (attempts == 1 ? 0.5 : 1.0), intentRevision: s.intentRevision, credentialRevision: s.credentialRevision, catalog: s.catalog)
  }
  func authorizes(_ ticket: Ticket, _ s: Sample) -> Bool {
    eligible(s) && last.map {
      s.time >= $0.time && s.position >= $0.position && s.bytes >= $0.bytes &&
        s.transfer >= $0.transfer && s.requests >= $0.requests
    } == true && s.catalog == ticket.catalog && s.current.map { $0.bandwidth < (target?.bandwidth ?? 0) } == true && s.generation == ticket.generation && s.intentRevision == ticket.intentRevision && s.credentialRevision == ticket.credentialRevision &&
      inFlight?.id == ticket.id && s.time >= ticket.due && s.time <= ticket.due + 5
  }
  mutating func finish(_ ticket: Ticket, installedAt: Double? = nil) {
    guard inFlight?.id == ticket.id else { return }
    if let installedAt { lastInstallation = installedAt }
    inFlight = nil; anchor = nil; windows = 0
  }
}

/// Consecutive texture publications, not presentationSize or timer samples.
struct YlDashPublishedOutputWindow {
  private(set) var count = 0
  private(set) var start: Double?
  private var lastTime = 0.0, lastPosition = 0.0
  private var generation: UInt64 = 0
  private var width = 0, height = 0

  mutating func observe(time: Double, position: Double, generation: UInt64,
    width: Int, height: Int, playing: Bool) {
    guard playing, time.isFinite, position.isFinite else { self = .init(); return }
    if count == 0 || self.generation != generation || self.width != width || self.height != height ||
       time <= lastTime || time - lastTime > 0.5 || position <= lastPosition {
      count = 0; start = time
    }
    count += 1; lastTime = time; lastPosition = position
    self.generation = generation; self.width = width; self.height = height
  }

  func evidence(now: Double, generation: UInt64, width: Int, height: Int) -> (count: Int, seconds: Double, start: Double?) {
    guard let start, self.generation == generation, self.width == width, self.height == height,
      now >= lastTime, now - lastTime <= 0.5 else { return (0, 0, nil) }
    return (count, lastTime - start, start)
  }
}
