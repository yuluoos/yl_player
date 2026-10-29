from pathlib import Path
import sys
p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/AvPlayer/YlDashAutoRecoveryPolicy.swift')
p.write_text('''import Foundation

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
  }
  struct Ticket {
    let id: UUID, generation: UInt64, attempt: Int, due: Double
    let intentRevision: UInt64, credentialRevision: UInt64
    let catalog: [Variant]
  }
  private(set) var attempts = 0
  private(set) var decision: [String: Any] = [:]
  mutating func invalidateIntent() {}
  mutating func observe(_ s: Sample) -> Ticket? { nil }
  func authorizes(_ ticket: Ticket, _ s: Sample) -> Bool { false }
  mutating func finish(_ ticket: Ticket) {}
}
''')
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();i=s.index('  func test',s.index('class YlDashResourceLoaderTests'))
tests='''  private func productionSample(_ time: Double, high: Bool = false, bandwidth: Double = 1_500_000,
    allowed: Bool = true, generation: UInt64 = 0, intent: UInt64 = 0, credential: UInt64 = 0,
    buffer: Double = 10, remaining: Double = 90, requests: Int? = nil) -> YlDashAutoRecoveryPolicy.Sample {
    let low = YlDashAutoRecoveryPolicy.Variant(id: "low", width: 426, height: 240, bandwidth: 400_000)
    let upper = YlDashAutoRecoveryPolicy.Variant(id: "upper", width: 960, height: 540, bandwidth: bandwidth)
    return .init(time: time, generation: generation, allowed: allowed, catalog: [low, upper], current: high ? upper : low,
      position: time, remaining: remaining, bufferAhead: buffer, bytes: Int64(time * 250_000), transfer: time,
      requests: requests ?? Int(time), overdue: 1, intentRevision: intent, credentialRevision: credential)
  }

  func testProductionRecoveryUsesDynamicBandwidthAndTwoWindows() throws {
    var p = YlDashAutoRecoveryPolicy()
    XCTAssertNil(p.observe(productionSample(0, high: true)))
    XCTAssertNil(p.observe(productionSample(1)))
    XCTAssertNil(p.observe(productionSample(9)))
    XCTAssertEqual(p.attempts, 0)
    XCTAssertNil(p.observe(productionSample(17)))
    XCTAssertEqual(p.attempts, 1)
    XCTAssertNil(p.observe(productionSample(17.49)))
    let ticket = try XCTUnwrap(p.observe(productionSample(17.5)))
    XCTAssertEqual(ticket.due, 17.5)
    XCTAssertTrue(p.authorizes(ticket, productionSample(18)))
    // 2 Mbps cannot qualify a 2 Mbps target with the unchanged 1.25 headroom.
    var insufficient = YlDashAutoRecoveryPolicy()
    for t in [0.0, 1, 9, 17, 25, 33] {
      XCTAssertNil(insufficient.observe(productionSample(t, high: t == 0, bandwidth: 2_000_000)))
    }
    XCTAssertEqual(insufficient.attempts, 0)
  }

  func testProductionRecoveryCancellationKeepsBackoffAndSourceBudget() throws {
    var p = YlDashAutoRecoveryPolicy()
    for t in [0.0, 1, 9, 17] { _ = p.observe(productionSample(t, high: t == 0)) }
    let first = try XCTUnwrap(p.observe(productionSample(17.5)))
    p.invalidateIntent()
    XCTAssertFalse(p.authorizes(first, productionSample(18)))
    for t in [18.0, 26, 34] { XCTAssertNil(p.observe(productionSample(t, intent: 1))) }
    XCTAssertEqual(p.attempts, 2)
    XCTAssertNil(p.observe(productionSample(34.99, intent: 1)))
    let second = try XCTUnwrap(p.observe(productionSample(35, intent: 1)))
    XCTAssertEqual(second.due, 35)
    p.finish(second)
    for t in [36.0, 44, 52, 60] { XCTAssertNil(p.observe(productionSample(t, intent: 1))) }
    XCTAssertEqual(p.attempts, 2)
    p = YlDashAutoRecoveryPolicy()
    XCTAssertEqual(p.attempts, 0)
  }

  func testProductionRecoveryRejectsStaleUnsafeAndExpiredCommit() throws {
    var p = YlDashAutoRecoveryPolicy()
    for t in [0.0, 1, 9, 17] { _ = p.observe(productionSample(t, high: t == 0)) }
    let ticket = try XCTUnwrap(p.observe(productionSample(17.5)))
    for s in [productionSample(18, high: true), productionSample(18, allowed: false),
      productionSample(18, generation: 1), productionSample(18, intent: 1), productionSample(18, credential: 1),
      productionSample(18, buffer: 4.999), productionSample(18, remaining: 19.999),
      productionSample(22.501), productionSample(18, bandwidth: 1_600_000)] {
      XCTAssertFalse(p.authorizes(ticket, s))
    }
    XCTAssertTrue(p.authorizes(ticket, productionSample(22.5)))
  }

  func testProductionRecoveryNeedsHighHistoryProgressRequestsAndNaturalHighCancels() throws {
    var p = YlDashAutoRecoveryPolicy()
    for t in [0.0, 1, 9, 17, 25] { XCTAssertNil(p.observe(productionSample(t))) }
    XCTAssertEqual(p.attempts, 0)
    p = YlDashAutoRecoveryPolicy()
    for t in [0.0, 1, 9, 17, 25] { _ = p.observe(productionSample(t, high: t == 0, requests: 1)) }
    XCTAssertEqual(p.attempts, 0)
    p = YlDashAutoRecoveryPolicy()
    for t in [0.0, 1, 9, 17] { _ = p.observe(productionSample(t, high: t == 0)) }
    XCTAssertEqual(p.attempts, 1)
    XCTAssertNil(p.observe(productionSample(17.4, high: true)))
    XCTAssertNil(p.observe(productionSample(17.6)))
    XCTAssertEqual(p.attempts, 1)
  }

'''
p.write_text(s[:i]+tests+s[i:]);sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path('packages/yl_player/example')/platform/'RunnerTests'/p.name).write_bytes(native_test_source(p))
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');p.write_text(p.read_text().replace("'ios': 851, 'macos': 895", "'ios': 855, 'macos': 899"))
