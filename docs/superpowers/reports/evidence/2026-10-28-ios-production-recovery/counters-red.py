from pathlib import Path
import sys
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();s=s.replace('buffer: Double = 10, remaining: Double = 90, requests: Int? = nil)', 'buffer: Double = 10, remaining: Double = 90, requests: Int? = nil,\n    bytes: Int64? = nil, transfer: Double? = nil)');s=s.replace('bytes: Int64(time * 250_000), transfer: time,\n      requests: requests ?? Int(time)', 'bytes: bytes ?? Int64(time * 250_000), transfer: transfer ?? time,\n      requests: requests ?? Int(time)')
i=s.index('  private func productionSample');s=s[:i]+'''  func testProductionRecoveryRejectsCounterRegressionInWindowBackoffAndCommit() throws {
    for counter in ["bytes", "transfer", "requests"] {
      func regressed(_ time: Double, to value: Double) -> YlDashAutoRecoveryPolicy.Sample {
        productionSample(time, requests: counter == "requests" ? Int(value) : nil,
          bytes: counter == "bytes" ? Int64(value * 250_000) : nil, transfer: counter == "transfer" ? value : nil)
      }
      var pending = YlDashAutoRecoveryPolicy()
      for t in [0.0, 1, 9, 17] { _ = pending.observe(productionSample(t, high: t == 0)) }
      XCTAssertNil(pending.observe(regressed(17.5, to: 0)), counter)
      XCTAssertEqual(pending.attempts, 1)
      XCTAssertEqual(pending.decision["reason"] as? String, "countersReset")
      var inflight = YlDashAutoRecoveryPolicy()
      for t in [0.0, 1, 9, 17] { _ = inflight.observe(productionSample(t, high: t == 0)) }
      let ticket = try XCTUnwrap(inflight.observe(productionSample(17.5)))
      XCTAssertFalse(inflight.authorizes(ticket, regressed(18, to: 0)), counter)
      var window = YlDashAutoRecoveryPolicy()
      for t in [0.0, 1, 5] { _ = window.observe(productionSample(t, high: t == 0)) }
      _ = window.observe(regressed(6, to: 4)) // Above the window anchor, below the immediately preceding sample.
      XCTAssertEqual(window.decision["reason"] as? String, "countersReset")
      _ = window.observe(productionSample(9))
      XCTAssertEqual(window.decision["qualifiedWindows"] as? Int, 0)
    }
  }

'''+s[i:];p.write_text(s);sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path('packages/yl_player/example')/platform/'RunnerTests'/p.name).write_bytes(native_test_source(p))
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');p.write_text(p.read_text().replace("'ios': 858, 'macos': 902", "'ios': 859, 'macos': 903"))
