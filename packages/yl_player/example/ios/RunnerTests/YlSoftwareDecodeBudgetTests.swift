@testable import yl_player_media_core
@testable import yl_player_apple
import XCTest

final class YlSoftwareDecodeBudgetTests: XCTestCase {
  private let limits = YlSoftwareDecodeLimits(maxOwnedBytes: 100, maxFrames: 2,
    maxPacketBytes: 20, windowNs: 100, maxCpuNs: 40, maxDecodeWallNs: 30)
  private func key(model: String = "test", os: String = "os", build: String = "build",
    width: Int = 2, fps: Int = 24) -> YlSoftwareDecodeKey {
    .init(model: model, osBuild: os, decoderBuild: build, codec: 12, profile: 0,
      bitDepth: 8, chroma: 420, width: width, height: 2, fpsNumerator: fps,
      fpsDenominator: 1, threads: 1, outputPixelFormat: 1)
  }
  private func observation(_ time: UInt64, _ cpu: UInt64, wall: UInt64 = 1,
    thermal: Bool? = true) -> YlSoftwareDecodeObservation {
    .init(monotonicNs: time, cumulativeCpuNs: cpu, decodeWallNs: wall, thermalNominal: thermal)
  }
  func testExactAdmissionAndEmptyProductionTable() {
    let admission = YlSoftwareDecodeAdmission(entries: [key(): limits])
    XCTAssertEqual(admission.limits(for: key()), limits)
    XCTAssertNil(YlSoftwareDecodeAdmission().limits(for: key()))
    for changed in [key(model: "unknown"), key(os: "new"), key(build: "new"), key(fps: 0)] {
      XCTAssertNil(admission.limits(for: changed))
    }
    for invalid in [key(width: Int.max), key(width: -1), key(fps: 0)] {
      XCTAssertNil(YlSoftwareDecodeAdmission(entries: [invalid: limits]).limits(for: invalid))
    }
  }
  func testSharedCurrentCandidateAndIdempotentOldRelease() throws {
    let pool = YlSoftwareDecodePool()
    var current: YlSoftwareDecodeBudget? = try .init(limits: limits, pool: pool)
    let candidate = try YlSoftwareDecodeBudget(limits: limits, pool: pool)
    let oldFrame = try XCTUnwrap(current).reserve(bytes: 60, frames: 1)
    current?.retire(); current = nil
    XCTAssertEqual(pool.ownedBytes, 60)
    XCTAssertThrowsError(try candidate.reserve(bytes: 60, frames: 1))
    oldFrame.release(); oldFrame.release()
    XCTAssertEqual(pool.ownedBytes, 0)
    let replacement = try YlSoftwareDecodeBudget(limits: limits, pool: pool)
    var frame: YlSoftwareDecodeBudget.Token? = try replacement.reserve(bytes: 60, frames: 1)
    XCTAssertNotNil(frame); XCTAssertEqual(pool.ownedBytes, 60)
    frame = nil; XCTAssertEqual(pool.ownedBytes, 0)
  }
  func testCheckedReservationsAndSeparatePacketCharge() throws {
    let pool = YlSoftwareDecodePool()
    let budget = try YlSoftwareDecodeBudget(limits: limits, pool: pool)
    let frame = try budget.reserve(bytes: 80, frames: 2)
    let packet = try budget.reservePacket(bytes: 20)
    XCTAssertEqual(pool.ownedBytes, 100)
    XCTAssertThrowsError(try budget.reserve(bytes: Int.max, frames: 1))
    packet.release(); frame.release(); XCTAssertEqual(pool.ownedBytes, 0)
    for (bytes,frames) in [(-1,0),(0,-1),(1,3),(0,1)] {
      let b = try YlSoftwareDecodeBudget(limits: limits, pool: pool)
      XCTAssertThrowsError(try b.reserve(bytes: bytes, frames: frames))
    }
    let b = try YlSoftwareDecodeBudget(limits: limits, pool: pool)
    XCTAssertThrowsError(try b.reservePacket(bytes: 21))
  }
  func testObservationFailuresLatchAndDoNotFreeOutstandingFrames() throws {
    for bad in [observation(0,1), observation(10,0), observation(10,51),
      observation(10,11,wall:31), observation(10,11,thermal:nil),
      observation(10,11,thermal:false), observation(101,11)] {
      let pool = YlSoftwareDecodePool()
      let budget = try YlSoftwareDecodeBudget(limits: limits, pool: pool)
      let frame = try budget.reserve(bytes: 10, frames: 1)
      try budget.observe(observation(0,10))
      XCTAssertThrowsError(try budget.observe(bad))
      XCTAssertThrowsError(try budget.reserve(bytes: 1, frames: 0))
      XCTAssertEqual(pool.ownedBytes,10)
      frame.release(); XCTAssertEqual(pool.ownedBytes,0)
    }
  }
  func testCpuUsesRollingWindowAcrossBoundary() throws {
    let budget = try YlSoftwareDecodeBudget(limits: limits, pool: .init())
    try budget.observe(observation(0,0))
    try budget.observe(observation(50,20))
    try budget.observe(observation(100,40))
    XCTAssertThrowsError(try budget.observe(observation(101,41)))
  }
  func testRetiredLeaseCannotAllocateButRetainedFramesStayCharged() throws {
    let pool = YlSoftwareDecodePool()
    let budget = try YlSoftwareDecodeBudget(limits: limits, pool: pool)
    let token = try budget.reserve(bytes: 20, frames: 1)
    budget.retire()
    XCTAssertThrowsError(try budget.reservePacket(bytes: 1))
    XCTAssertThrowsError(try budget.observe(observation(1,1)))
    XCTAssertEqual(pool.ownedBytes,20)
    token.release(); XCTAssertEqual(pool.ownedBytes,0)
  }
  func testConcurrentReleaseIsExactlyOnce() throws {
    let pool = YlSoftwareDecodePool()
    let budget = try YlSoftwareDecodeBudget(limits: limits, pool: pool)
    let token = try budget.reserve(bytes: 99, frames: 2)
    DispatchQueue.concurrentPerform(iterations: 100) { _ in token.release() }
    XCTAssertEqual(pool.ownedBytes, 0)
    let next = try budget.reserve(bytes: 100, frames: 2)
    next.release()
  }
  func testNewStricterLeaseCannotEraseExistingCharge() throws {
    let pool = YlSoftwareDecodePool()
    let budget = try YlSoftwareDecodeBudget(limits: limits, pool: pool)
    let token = try budget.reserve(bytes: 80, frames: 1)
    let small = YlSoftwareDecodeLimits(maxOwnedBytes: 50, maxFrames: 1,
      maxPacketBytes: 10, windowNs: 100, maxCpuNs: 40, maxDecodeWallNs: 30)
    XCTAssertThrowsError(try YlSoftwareDecodeBudget(limits: small, pool: pool))
    XCTAssertEqual(pool.ownedBytes, 80)
    token.release()
    let candidate = try YlSoftwareDecodeBudget(limits: small, pool: pool)
    let output = try candidate.reserve(bytes: 50, frames: 1)
    XCTAssertThrowsError(try budget.reserve(bytes: 1, frames: 0))
    output.release()
  }
  func testObservationHistoryCannotGrowWithoutBound() throws {
    let largeWindow = YlSoftwareDecodeLimits(maxOwnedBytes: 100, maxFrames: 2,
      maxPacketBytes: 20, windowNs: 10_000, maxCpuNs: 10_000, maxDecodeWallNs: 30)
    let budget = try YlSoftwareDecodeBudget(limits: largeWindow, pool: .init())
    for index in 0..<1024 { try budget.observe(observation(UInt64(index), 0)) }
    XCTAssertThrowsError(try budget.observe(observation(1024, 0)))
  }

  func testCpuWindowIsSharedAcrossReplacementLeases() throws {
    let pool = YlSoftwareDecodePool()
    var first: YlSoftwareDecodeBudget? = try .init(limits: limits, pool: pool)
    try first?.observe(observation(0, 0))
    try first?.observe(observation(50, 30))
    first?.retire(); first = nil
    let next = try YlSoftwareDecodeBudget(limits: limits, pool: pool)
    XCTAssertThrowsError(try next.observe(observation(60, 45)))
  }
  func testRetiredEmptyLeaseDoesNotHoldAnUnusedMemoryCeiling() throws {
    let pool = YlSoftwareDecodePool()
    let small = YlSoftwareDecodeLimits(maxOwnedBytes: 50, maxFrames: 1,
      maxPacketBytes: 10, windowNs: 100, maxCpuNs: 40, maxDecodeWallNs: 30)
    let old = try YlSoftwareDecodeBudget(limits: small, pool: pool)
    old.retire()
    let next = try YlSoftwareDecodeBudget(limits: limits, pool: pool)
    let frame = try next.reserve(bytes: 80, frames: 2)
    XCTAssertEqual(pool.ownedBytes, 80)
    frame.release(); withExtendedLifetime(old) {}
  }

  func testConcurrentProcessSamplesAreCapturedInsideSharedLock() throws {
    let limits = YlSoftwareDecodeLimits(maxOwnedBytes: 100, maxFrames: 2,
      maxPacketBytes: 20, windowNs: 1000, maxCpuNs: 1000, maxDecodeWallNs: 30)
    let pool = YlSoftwareDecodePool()
    let a = try YlSoftwareDecodeBudget(limits: limits, pool: pool)
    let b = try YlSoftwareDecodeBudget(limits: limits, pool: pool)
    var time: UInt64 = 0; let errorLock = NSLock(); var errors = 0
    DispatchQueue.concurrentPerform(iterations: 100) { index in
      do {
        try (index % 2 == 0 ? a : b).observe(using: {
          time += 1
          return .init(monotonicNs: time, cumulativeCpuNs: time, decodeWallNs: 1, thermalNominal: true)
        })
      } catch { errorLock.withLock { errors += 1 } }
    }
    XCTAssertEqual(errors, 0); XCTAssertEqual(time, 100)
  }

}
