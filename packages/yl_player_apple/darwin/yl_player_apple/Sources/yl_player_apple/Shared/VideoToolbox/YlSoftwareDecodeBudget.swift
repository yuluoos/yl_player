import yl_player_media_core
import Foundation

/// Cumulative process CPU includes decoder workers; nil thermal means unavailable.
/// All counters use nanoseconds. Call before allocation/decode and after each C call;
/// a single synchronous decode cannot be preempted by this between-call guard.
struct YlSoftwareDecodeObservation {
  let monotonicNs: UInt64; let cumulativeCpuNs: UInt64
  let decodeWallNs: UInt64; let thermalNominal: Bool?
}

/// One process-wide ownership ledger, shared by current/candidate/all player leases.
/// The strictest live lease bounds the aggregate. Retired leases remain live until
/// their final retained frame/token releases; no seek/generation operation resets it.
final class YlSoftwareDecodePool {
  static let shared = YlSoftwareDecodePool()
  fileprivate let lock = NSLock()
  fileprivate var leases = [UUID: YlSoftwareDecodeLimits]()
  fileprivate var bytes = 0
  fileprivate var frames = 0
  fileprivate var history = [YlSoftwareDecodeObservation]()
  fileprivate var longestWindow: UInt64 = 0
  fileprivate var mayRestartAfterIdle = false
  var ownedBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
}

/// A decoder lease. Compressed packets, reference surfaces, and retained output
/// images each own distinct tokens; sharing one surface shares its token lifetime.
/// Exhaustion/invalid observations permanently close this lease to new work.
final class YlSoftwareDecodeBudget {
  /// Thread-safe, idempotent release; deinit releases automatically. Keep the token
  /// alive through the final CVPixelBuffer/reference release, including old seeks.
  final class Token {
    private let lock = NSLock()
    private var owner: YlSoftwareDecodeBudget?
    private let bytes: Int
    private let frames: Int
    fileprivate init(owner: YlSoftwareDecodeBudget, bytes: Int, frames: Int) {
      self.owner = owner; self.bytes = bytes; self.frames = frames
    }
    func release() {
      lock.lock(); let retained = owner; owner = nil; lock.unlock()
      retained?.release(bytes: bytes, frames: frames)
    }
    deinit { release() }
  }

  private let id = UUID()
  private let limits: YlSoftwareDecodeLimits
  private let pool: YlSoftwareDecodePool
  // All mutable fields below are protected by the pool lock.
  private var closed = false
  private var ownedBytes = 0
  private var ownedFrames = 0

  init(limits: YlSoftwareDecodeLimits, pool: YlSoftwareDecodePool = .shared) throws {
    self.limits = limits; self.pool = pool
    guard limits.isValid else { throw Self.exhausted() }
    pool.lock.lock(); defer { pool.lock.unlock() }
    guard pool.bytes <= limits.maxOwnedBytes, pool.frames <= limits.maxFrames else {
      throw Self.exhausted()
    }
    if pool.leases.isEmpty { pool.mayRestartAfterIdle = true }
    pool.longestWindow = max(pool.longestWindow, limits.windowNs)
    pool.leases[id] = limits
  }

  /// Charge bytes before allocation; a frame charge must have nonzero owned bytes.
  /// Packet bytes use reservePacket to enforce the independent per-packet limit.
  func reserve(bytes: Int, frames: Int) throws -> Token {
    pool.lock.lock(); defer { pool.lock.unlock() }
    guard !closed, bytes > 0, frames >= 0 else { throw fail() }
    let total = pool.bytes.addingReportingOverflow(bytes)
    let frameTotal = pool.frames.addingReportingOverflow(frames)
    let byteCap = pool.leases.values.map(\.maxOwnedBytes).min() ?? 0
    let frameCap = pool.leases.values.map(\.maxFrames).min() ?? 0
    guard !total.overflow, !frameTotal.overflow,
      total.partialValue <= byteCap, frameTotal.partialValue <= frameCap
    else { throw fail() }
    // Local sums cannot overflow after the checked nonnegative aggregate sums.
    pool.bytes = total.partialValue; pool.frames = frameTotal.partialValue
    ownedBytes += bytes; ownedFrames += frames
    return Token(owner: self, bytes: bytes, frames: frames)
  }

  /// A compressed packet counts against both its packet limit and total ownership;
  /// it does not consume a decoded frame slot.
  func reservePacket(bytes: Int) throws -> Token {
    if bytes <= 0 || bytes > limits.maxPacketBytes {
      pool.lock.lock(); defer { pool.lock.unlock() }; throw fail()
    }
    return try reserve(bytes: bytes, frames: 0)
  }

  /// Conservative rolling process-CPU accounting. A sample gap larger than the
  /// measurement window fails closed. The sample at/before the window boundary
  /// remains charged, so sparse sampling cannot discard a boundary CPU burst.
  func observe(_ observation: YlSoftwareDecodeObservation) throws {
    pool.lock.lock(); defer { pool.lock.unlock() }
    try observeLocked(observation)
  }

  /// Capture process counters under the shared lock so concurrent players cannot
  /// deliver stale samples out of timestamp order. The producer must not reenter.
  func observe(using producer: () -> YlSoftwareDecodeObservation) throws {
    pool.lock.lock(); defer { pool.lock.unlock() }
    try observeLocked(producer())
  }

  private func observeLocked(_ observation: YlSoftwareDecodeObservation) throws {
    guard !closed, observation.thermalNominal == true,
      observation.decodeWallNs <= limits.maxDecodeWallNs else { throw fail() }
    if let previous = pool.history.last {
      guard observation.monotonicNs > previous.monotonicNs,
        observation.cumulativeCpuNs >= previous.cumulativeCpuNs else { throw fail() }
      let gap = observation.monotonicNs - previous.monotonicNs
      if pool.mayRestartAfterIdle && gap > pool.longestWindow {
        pool.history.removeAll(keepingCapacity: true)
      } else {
        guard gap <= limits.windowNs else { throw fail() }
      }
    }
    pool.mayRestartAfterIdle = false
    // Keep the longest window ever requested so a replacement cannot shorten
    // history and then restore a larger window to hide process CPU consumption.
    let cutoff = observation.monotonicNs > pool.longestWindow
      ? observation.monotonicNs - pool.longestWindow : 0
    while pool.history.count > 1 && pool.history[1].monotonicNs <= cutoff {
      pool.history.removeFirst()
    }
    for live in pool.leases.values {
      let boundary = observation.monotonicNs > live.windowNs
        ? observation.monotonicNs - live.windowNs : 0
      let first = pool.history.last(where: { $0.monotonicNs <= boundary }) ?? pool.history.first
      if let first = first {
        guard observation.cumulativeCpuNs - first.cumulativeCpuNs <= live.maxCpuNs else {
          throw fail()
        }
      }
    }
    // Never discard in-window CPU to make room; close this lease instead.
    guard pool.history.count < 1024 else { throw fail() }
    pool.history.append(observation)
  }

  /// Stop new allocations without releasing resources still owned by decoder/output.
  func retire() {
    pool.lock.lock(); defer { pool.lock.unlock() }
    closed = true; removeEmptyRetiredLease()
  }

  private func removeEmptyRetiredLease() {
    if closed && ownedBytes == 0 && ownedFrames == 0 {
      pool.leases.removeValue(forKey: id)
    }
  }

  private func release(bytes: Int, frames: Int) {
    pool.lock.lock(); defer { pool.lock.unlock() }
    ownedBytes -= bytes; ownedFrames -= frames
    pool.bytes -= bytes; pool.frames -= frames
    removeEmptyRetiredLease()
  }
  private func fail() -> NativePlayerError {
    closed = true; removeEmptyRetiredLease(); return Self.exhausted()
  }
  private static func exhausted() -> NativePlayerError {
    NativePlayerError(category: "resource", code: "resource.exhausted",
      message: "Software decoding exceeded its measured resource budget.")
  }
  deinit {
    pool.lock.lock(); defer { pool.lock.unlock() }
    // Every token retains this lease, so no outstanding charge can reach deinit.
    assert(ownedBytes == 0 && ownedFrames == 0)
    pool.leases.removeValue(forKey: id)
  }
}
