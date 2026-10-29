from pathlib import Path
import sys
p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/AvPlayer/YlDashAutoRecoveryController.swift');p.write_text('''import Foundation

final class YlDashAutoRecoveryController {
  typealias Sample = YlDashAutoRecoveryPolicy.Sample
  typealias Scheduler = (Double, @escaping () -> Void) -> Void
  private(set) var policy = YlDashAutoRecoveryPolicy()
  private(set) var events: [[String: Any]] = []
  init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
       schedule: @escaping Scheduler = { delay, action in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) }) {}
  func invalidate() {}
  func resetForSource() {}
  func tick(_ sample: Sample?, prepare: @escaping YlOpenCoordinator.Preparation,
            currentSample: @escaping () -> Sample?, commit: @escaping YlOpenCoordinator.Commit) {}
}
''')
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();i=s.index('  private func productionSample')
t='''  func testProductionRecoveryControllerCommitsWithinPreparationDeadline() async throws {
    var now = 0.0
    let controller = YlDashAutoRecoveryController(clock: { now }, schedule: { _, _ in })
    let committed = expectation(description: "current candidate committed")
    let source = YlAppleSourceDescriptor(uri: "https://owned.example/movie.mpd", kind: .network, formatHint: .dash)
    for t in [0.0, 1, 9, 17, 17.5] {
      now = t
      controller.tick(productionSample(t, high: t == 0), prepare: { _ in .avPlayer(source: source) },
        currentSample: { self.productionSample(now) }, commit: { _ in committed.fulfill() })
    }
    await fulfillment(of: [committed], timeout: 3)
    XCTAssertEqual(controller.events.count, 1)
    XCTAssertEqual(controller.events.first?["outcome"] as? String, "installed")
    XCTAssertEqual(controller.policy.attempts, 1)
  }

  func testProductionRecoveryControllerCancelsHeldCandidateAndPreservesBudget() async throws {
    for action in ["cancel", "deadline", "credential"] {
      var now = 0.0, credential: UInt64 = 0
      var deadline: (() -> Void)?
      let controller = YlDashAutoRecoveryController(clock: { now }, schedule: { _, callback in deadline = callback })
      let started = expectation(description: "held preparation " + action)
      let released = expectation(description: "cancelled preparation " + action)
      let barrier = DispatchSemaphore(value: 0)
      var installs = 0
      let source = YlAppleSourceDescriptor(uri: "https://owned.example/movie.mpd", kind: .network, formatHint: .dash)
      for t in [0.0, 1, 9, 17, 17.5] {
        now = t
        controller.tick(productionSample(t, high: t == 0), prepare: { token in
          token.onCancel { barrier.signal() }; started.fulfill()
          _ = barrier.wait(timeout: .now() + 3); released.fulfill()
          return .avPlayer(source: source)
        }, currentSample: { self.productionSample(now, credential: credential) }, commit: { _ in installs += 1 })
      }
      await fulfillment(of: [started], timeout: 2)
      if action == "cancel" { controller.invalidate() }
      else if action == "deadline" { now = 19.501; deadline?() }
      else { credential = 1; barrier.signal() }
      await fulfillment(of: [released], timeout: 2)
      // Drain both the preparation queue's main completion and a main turn.
      let drained = expectation(description: "completion drained")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { drained.fulfill() }
      await fulfillment(of: [drained], timeout: 1)
      XCTAssertEqual(installs, 0, action)
      XCTAssertEqual(controller.policy.attempts, 1, action)
      XCTAssertNotEqual(controller.events.first?["outcome"] as? String, "installed", action)
      controller.resetForSource()
      XCTAssertEqual(controller.policy.attempts, 0)
    }
  }

''';p.write_text(s[:i]+t+s[i:]);sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path('packages/yl_player/example')/platform/'RunnerTests'/p.name).write_bytes(native_test_source(p))
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');p.write_text(p.read_text().replace("'ios': 855, 'macos': 899", "'ios': 857, 'macos': 901"))
