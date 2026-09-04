@testable import yl_player_macos
import XCTest

final class YlMacosAvPlayerStateTests: XCTestCase {
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
