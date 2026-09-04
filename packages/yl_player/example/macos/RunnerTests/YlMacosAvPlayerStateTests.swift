@testable import yl_player_macos
import XCTest

final class YlMacosAvPlayerStateTests: XCTestCase {
  func testFailureGateCoalescesCallbacksForOneItem() {
    let gate = YlAvPlayerFailureGate()

    XCTAssertTrue(gate.begin(generation: 4))
    XCTAssertFalse(gate.begin(generation: 4))
    XCTAssertTrue(gate.finish(generation: 4, currentGeneration: 4))
    gate.markTerminal(generation: 4)
    XCTAssertFalse(gate.begin(generation: 4))
    gate.reset()
    XCTAssertTrue(gate.begin(generation: 4))
  }

  func testFailureDiagnosticDoesNotExposeNSErrorUserInfo() {
    let error = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorTimedOut,
      userInfo: [
        NSLocalizedDescriptionKey: "secret token https://u:p@test/x?key=secret",
      ]
    )

    let diagnostic = YlAvPlayerFailurePolicy.diagnostic(error)

    XCTAssertEqual(
      diagnostic,
      "NSError(domain=NSURLErrorDomain, code=\(NSURLErrorTimedOut))"
    )
    XCTAssertFalse(diagnostic.contains("secret"))
  }

  func testPlayIntentReportsBufferingUntilRateStarts() {
    XCTAssertEqual(
      YlAvPlayerStatePolicy.status(
        wantsToPlay: true,
        itemReady: true,
        rate: 0,
        waiting: true
      ),
      "buffering"
    )
  }

  func testStartedRateReportsPlaying() {
    XCTAssertEqual(
      YlAvPlayerStatePolicy.status(
        wantsToPlay: true,
        itemReady: true,
        rate: 1,
        waiting: false
      ),
      "playing"
    )
  }

  func testReadyWithoutPlayIntentReportsPaused() {
    XCTAssertEqual(
      YlAvPlayerStatePolicy.status(
        wantsToPlay: false,
        itemReady: true,
        rate: 0,
        waiting: false
      ),
      "paused"
    )
  }
}
