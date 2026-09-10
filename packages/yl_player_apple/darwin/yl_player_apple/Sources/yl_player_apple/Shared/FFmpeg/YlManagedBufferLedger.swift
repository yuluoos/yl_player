import Foundation

/// One Player's assigned media payload authority. Epoch invalidation is an
/// admission fence, never a receipt that a decoder or queued closure released data.
final class YlManagedBufferLedger {
  enum Category: CaseIterable, Hashable { case networkCache, compressedPackets, queuedVideoFrames, scheduledAudio }
  struct Snapshot {
    let currentBytes: Int
    let peakBytes: Int
    let maxBytes: Int
    let categories: [Category: Int]
  }
  private let lock = NSLock()
  private let initialLimit: Int
  private var limits: [UUID: Int] = [:]
  private var protectedWorkingSets: [UUID: [Category: Int]] = [:]
  private var bytes = 0
  private var peak = 0
  private var categories: [Category: Int] = [:]
  private var invalid = Set<UInt64>()
  private var opaqueRetentions = Set<UUID>()
  private var boundedScopes = Set<UUID>()
  private var listeners: [UUID: () -> Void] = [:]
  init(maxBytes: Int = .max) { precondition(maxBytes > 0); initialLimit = maxBytes }
  private var limit: Int { min(initialLimit, limits.values.min() ?? initialLimit) }
  var snapshot: Snapshot {
    lock.lock(); defer { lock.unlock() }
    return Snapshot(currentBytes: bytes, peakBytes: peak, maxBytes: limit, categories: categories)
  }
  func makeScope(maxBytes: Int?) throws -> YlManagedBufferScope {
    lock.lock(); defer { lock.unlock() }
    let proposed = maxBytes ?? initialLimit
    guard proposed > 0, bytes <= proposed, maxBytes == nil || opaqueRetentions.isEmpty else { throw Self.unsupported() }
    // Peak belongs to the current limit epoch; tightening keeps all retained bytes.
    if proposed < limit { peak = bytes }
    let id = UUID(); limits[id] = proposed
    if maxBytes != nil { boundedScopes.insert(id) }
    if maxBytes != nil && proposed > 2 * 1024 * 1024 {
      protectedWorkingSets[id] = [.compressedPackets: 1024 * 1024, .scheduledAudio: 256 * 1024,
        .queuedVideoFrames: 512 * 1024, .networkCache: 256 * 1024]
    }
    return YlManagedBufferScope(ledger: self, id: id)
  }
  /// R18: unmetered package HLS media cannot coexist with a bounded lease.
  /// This is metadata-only admission exclusion, not a second byte counter.
  func acquireOpaqueHlsRetention() throws -> OpaqueHlsRetention {
    lock.lock(); defer { lock.unlock() }
    guard boundedScopes.isEmpty && initialLimit == Int.max else { throw Self.unsupported() }
    let id = UUID(); opaqueRetentions.insert(id)
    return OpaqueHlsRetention(ledger: self, id: id)
  }
  final class OpaqueHlsRetention {
    private let ledger: YlManagedBufferLedger
    private let id: UUID
    fileprivate init(ledger: YlManagedBufferLedger, id: UUID) { self.ledger = ledger; self.id = id }
    deinit { ledger.lock.lock(); ledger.opaqueRetentions.remove(id); ledger.lock.unlock() }
  }
  func invalidate(generation: UInt64) { lock.lock(); invalid.insert(generation); lock.unlock() }
  func reserve(category: Category, bytes count: Int, generation: UInt64) -> Token? {
    reserve(category: category, bytes: count, generation: generation, scope: nil)
  }
  func availableBytes(category: Category) -> Int {
    lock.lock(); defer { lock.unlock() }; return availableLocked(category: category)
  }
  private func availableLocked(category: Category) -> Int {
    var protected = 0
    for other in Category.allCases where other != category {
      let required = protectedWorkingSets.values.compactMap { $0[other] }.max() ?? 0
      protected += max(0, required - categories[other, default: 0])
    }
    return max(0, limit - bytes - min(protected, limit - bytes))
  }
  fileprivate func reserve(category: Category, bytes count: Int, generation: UInt64?, scope: YlManagedBufferScope?) -> Token? {
    lock.lock(); defer { lock.unlock() }
    guard count >= 0, generation.map({ !invalid.contains($0) }) ?? true,
          count <= limit - bytes else { return nil }
    guard count <= availableLocked(category: category) else { return nil }
    bytes += count; peak = max(peak, bytes)
    categories[category, default: 0] += count
    return Token(ledger: self, scope: scope, category: category, bytes: count)
  }
  /// Nonblocking notification: callbacks run after releasing the ledger lock.
  /// Callers schedule work on their own executor; they must not wait here.
  func onRelease(_ callback: @escaping () -> Void) -> UUID {
    let id = UUID(); lock.lock(); listeners[id] = callback; lock.unlock(); return id
  }
  func removeObserver(_ id: UUID) { lock.lock(); listeners[id] = nil; lock.unlock() }
  fileprivate func release(category: Category, bytes count: Int) {
    lock.lock(); bytes -= count; categories[category, default: 0] -= count
    let callbacks = Array(listeners.values); lock.unlock()
    if count > 0 { callbacks.forEach { $0() } }
  }
  fileprivate func protectFrame(_ bytes: Int, scope: UUID) {
    lock.lock()
    if protectedWorkingSets[scope] != nil { protectedWorkingSets[scope]?[.queuedVideoFrames] = bytes }
    lock.unlock()
  }
  fileprivate func retire(_ id: UUID) {
    lock.lock(); limits[id] = nil; protectedWorkingSets[id] = nil; boundedScopes.remove(id); let callbacks = Array(listeners.values); lock.unlock()
    callbacks.forEach { $0() }
  }
  static func unsupported(_ diagnostic: String? = nil) -> NativePlayerError {
    NativePlayerError(category: "unsupported", code: "policy.unsupported",
      message: "The requested managed buffer cannot retain the required media working set.", diagnostic: diagnostic)
  }
  final class Token: NSObject {
    private let lock = NSLock()
    private let ledger: YlManagedBufferLedger
    private var scope: YlManagedBufferScope?
    let category: Category
    private var retainedBytes: Int
    private var queuedTiming: YlManagedMediaTiming?
    private var timingEpoch: UInt64?
    private var mediaDurationUs: Int64 = 0
    fileprivate init(ledger: YlManagedBufferLedger, scope: YlManagedBufferScope?, category: Category, bytes: Int) {
      self.ledger = ledger; self.scope = scope; self.category = category; retainedBytes = bytes
      super.init()
    }
    var mediaEpoch: UInt64? { lock.lock(); defer { lock.unlock() }; return timingEpoch }
    /// Media-time membership ends when consumed; byte ownership can outlive it.
    func endQueuedTiming() {
      lock.lock(); let timing = queuedTiming; queuedTiming = nil; lock.unlock()
      withExtendedLifetime(timing) {}
    }
    @discardableResult
    func carryTiming(ptsUs: Int64, durationUs: Int64, from original: Token? = nil) -> Bool {
      let inheritedEpoch = original?.mediaEpoch
      let inheritedDuration = original?.durationUs ?? 0
      lock.lock(); defer { lock.unlock() }
      guard let scope else { return true }
      let duration = durationUs > 0 ? durationUs : inheritedDuration
      guard let timing = scope.admitTiming(ptsUs: ptsUs, durationUs: duration, epoch: inheritedEpoch) else {
        return !scope.hasBoundedTimeline
      }
      queuedTiming = timing; timingEpoch = timing.epoch; mediaDurationUs = duration; return true
    }
    private var durationUs: Int64 { lock.lock(); defer { lock.unlock() }; return mediaDurationUs }
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return retainedBytes }
    /// Shrinking is safe only after those bytes have actually left this owner.
    func shrink(to count: Int) {
      lock.lock(); precondition(count >= 0 && count <= retainedBytes)
      let released = retainedBytes - count; retainedBytes = count; lock.unlock()
      ledger.release(category: category, bytes: released)
    }
    func release() {
      endQueuedTiming()
      lock.lock(); let count = retainedBytes; retainedBytes = 0
      let lease = scope; scope = nil; lock.unlock()
      ledger.release(category: category, bytes: count)
      withExtendedLifetime(lease) {}
    }
    deinit { release() }
  }
}

/// The host owns a single ledger; every load/reopen carries this lease. Tokens
/// retain it through delayed release, so tighter overlap limits cannot disappear
/// merely because the host cancelled its candidate or changed generation.
final class YlManagedBufferScope {
  let ledger: YlManagedBufferLedger
  private let id: UUID
  private let timelineLock = NSLock()
  private var plan: YlBoundedBufferPlan?
  private var mediaEpoch: UInt64 = 0
  private var timings: [UUID: (epoch: UInt64, start: Int64, end: Int64)] = [:]
  private var maximumObservedPacketDuration: Int64 = 0
  private var maximumPacketPTS: Int64?
  fileprivate init(ledger: YlManagedBufferLedger, id: UUID) { self.ledger = ledger; self.id = id }
  var hasBoundedTimeline: Bool { timelineLock.lock(); defer { timelineLock.unlock() }; return plan != nil }
  func configureTimeline(_ plan: YlBoundedBufferPlan?) { timelineLock.lock(); self.plan = plan; timelineLock.unlock() }
  func beginMediaGeneration() {
    timelineLock.lock(); mediaEpoch &+= 1; maximumObservedPacketDuration = 0; maximumPacketPTS = nil; timelineLock.unlock()
  }
  private var durationLocked: Int64 {
    let current = timings.values.filter { $0.epoch == mediaEpoch }
    guard let start = current.map(\.start).min(), let end = current.map(\.end).max() else { return 0 }
    return end - start
  }
  var bufferedDurationUs: Int64 { timelineLock.lock(); defer { timelineLock.unlock() }; return durationLocked }
  var shouldPausePacketAdmission: Bool {
    timelineLock.lock(); defer { timelineLock.unlock() }
    guard let plan else { return false }
    let current = timings.values.filter { $0.epoch == mediaEpoch }
    guard let low = current.map(\.start).min() else { return false }
    let duration = durationLocked
    // A high-PTS frame can already be displayed while older audio is queued.
    // Forecast from demux's high-water timestamp too, not only retained span.
    if let maximumPacketPTS {
      let forecast = maximumPacketPTS.addingReportingOverflow(maximumObservedPacketDuration)
      if forecast.overflow || forecast.partialValue - low >= plan.maxDurationUs { return true }
    }
    return duration > 0 && duration >= max(0, plan.maxDurationUs - maximumObservedPacketDuration)
  }
  func observePacketDuration(_ duration: Int64, ptsUs: Int64? = nil) {
    timelineLock.lock(); defer { timelineLock.unlock() }
    maximumObservedPacketDuration = max(maximumObservedPacketDuration, max(0, duration))
    if let ptsUs, ptsUs != Int64.min {
      let pts = max(0, ptsUs)
      if let previous = maximumPacketPTS, pts > previous {
        let advance = (pts - previous).addingReportingOverflow(max(0, duration))
        maximumObservedPacketDuration = max(maximumObservedPacketDuration, advance.overflow ? Int64.max : advance.partialValue)
      }
      maximumPacketPTS = max(maximumPacketPTS ?? pts, pts)
    }
  }
  fileprivate func admitTiming(ptsUs: Int64, durationUs: Int64, epoch requestedEpoch: UInt64?) -> YlManagedMediaTiming? {
    timelineLock.lock(); defer { timelineLock.unlock() }
    guard let plan, ptsUs != Int64.min, durationUs > 0 else { return nil }
    let start = max(0, ptsUs), duration = max(0, durationUs)
    let end = start.addingReportingOverflow(duration)
    guard !end.overflow, duration <= plan.maxDurationUs else { return nil }
    let epoch = requestedEpoch ?? mediaEpoch
    if epoch == mediaEpoch {
      let current = timings.values.filter { $0.epoch == epoch }
      let low = min(start, current.map(\.start).min() ?? start)
      let high = max(end.partialValue, current.map(\.end).max() ?? end.partialValue)
      guard high - low <= plan.maxDurationUs else { return nil }
    }
    let id = UUID(); timings[id] = (epoch, start, end.partialValue)
    return YlManagedMediaTiming(scope: self, id: id, epoch: epoch)
  }
  var timingDiagnostic: String {
    timelineLock.lock(); defer { timelineLock.unlock() }
    let current = timings.values.filter { $0.epoch == mediaEpoch }
    return "epoch=\(mediaEpoch) min=\(current.map(\.start).min() ?? 0) max=\(current.map(\.end).max() ?? 0) intervals=\(current.count) packetAdvance=\(maximumObservedPacketDuration)"
  }
  fileprivate func releaseTiming(_ id: UUID) { timelineLock.lock(); timings[id] = nil; timelineLock.unlock() }
  func reserve(category: YlManagedBufferLedger.Category, bytes: Int) -> YlManagedBufferLedger.Token? {
    ledger.reserve(category: category, bytes: bytes, generation: nil, scope: self)
  }
  func require(category: YlManagedBufferLedger.Category, bytes: Int) throws -> YlManagedBufferLedger.Token {
    guard let token = reserve(category: category, bytes: bytes) else { throw YlManagedBufferLedger.unsupported() }
    return token
  }
  func protectFrame(bytes: Int) { ledger.protectFrame(bytes, scope: id) }
  deinit { ledger.retire(id) }
}

fileprivate final class YlManagedMediaTiming {
  private let scope: YlManagedBufferScope
  private let id: UUID
  let epoch: UInt64
  init(scope: YlManagedBufferScope, id: UUID, epoch: UInt64) { self.scope = scope; self.id = id; self.epoch = epoch }
  deinit { scope.releaseTiming(id) }
}
