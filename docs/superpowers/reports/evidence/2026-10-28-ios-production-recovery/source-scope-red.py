from pathlib import Path
import sys
root=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple')
p=root/'Engines/AvPlayer/YlDashAutoRecoveryController.swift';s=p.read_text().replace('  private var activeTicket:', '  private var sourceIdentity: YlAppleSessionIdentity?\n  private var activeTicket:');i=s.index('  func invalidate()');s=s[:i]+'''  func useSource(_ identity: YlAppleSessionIdentity) {
    if sourceIdentity?.loadRequestId != identity.loadRequestId { resetForSource(); sourceIdentity = identity }
  }

'''+s[i:];p.write_text(s)
p=root/'Shared/Session/YlAppleSessionCoordinator.swift';s=p.read_text().replace('  private var dashRecoveryScope: String?\n','');s=s.replace('    if dashRecoveryScope != identity.loadRequestId {\n      dashRecovery.resetForSource(); dashRecoveryScope = identity.loadRequestId\n    }','    dashRecovery.useSource(identity)');p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();i=s.index('  private func productionSample');s=s[:i]+'''  func testProductionRecoveryBudgetUsesCommittedSessionNotReusedRequestLabel() {
    let controller = YlDashAutoRecoveryController()
    let first = YlAppleSessionIdentity(sessionId: "first", loadRequestId: "reused")
    controller.useSource(first)
    for t in [0.0, 1, 9, 17] {
      controller.tick(productionSample(t, high: t == 0), prepare: { _ in XCTFail("No ticket before backoff"); throw YlOpenCancellationToken.cancellationError() },
        currentSample: { nil }, commit: { _ in XCTFail("No installation"); return [:] })
    }
    XCTAssertEqual(controller.policy.attempts, 1)
    controller.invalidate(); controller.useSource(first)
    XCTAssertEqual(controller.policy.attempts, 1)
    controller.useSource(.init(sessionId: "second", loadRequestId: "reused"))
    XCTAssertEqual(controller.policy.attempts, 0, "A new committed Load owns a fresh budget even if its public label is reused")
  }

'''+s[i:];p.write_text(s);sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path('packages/yl_player/example')/platform/'RunnerTests'/p.name).write_bytes(native_test_source(p))
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');p.write_text(p.read_text().replace("'ios': 857, 'macos': 901", "'ios': 858, 'macos': 902"))
