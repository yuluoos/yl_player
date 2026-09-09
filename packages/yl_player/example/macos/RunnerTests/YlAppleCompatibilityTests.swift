@testable import yl_player_apple
import Foundation
import XCTest

final class YlAppleCompatibilityTests: XCTestCase {
  private func frame(_ pts: Int64) -> YlFrameEnvelope {
    .init(payload: NSObject(), ptsUs: pts, durationUs: 10_000, keyframe: false, generation: 1)
  }

  func testIosOverflowKeepsNewestThreeFrames() {
    let scheduler = YlFrameScheduler(compatibility: .init(platform: .ios))
    for pts in [10_000, 20_000, 30_000, 40_000] { XCTAssertTrue(scheduler.enqueue(frame(Int64(pts)))) }
    XCTAssertEqual(scheduler.pendingPTS, [20_000, 30_000, 40_000])
    XCTAssertEqual(scheduler.lateFrameDropCount, 1)
  }

  func testMacosOverflowRejectsNewestAndPreservesQueuedOrder() {
    let scheduler = YlFrameScheduler(compatibility: .init(platform: .macos), enqueueWaitTimeout: 0)
    for pts in [10_000, 20_000, 30_000] { XCTAssertTrue(scheduler.enqueue(frame(Int64(pts)))) }
    XCTAssertFalse(scheduler.enqueue(frame(40_000)))
    XCTAssertEqual(scheduler.pendingPTS, [10_000, 20_000, 30_000])
    XCTAssertEqual(scheduler.frame(at: 30_000, generation: 1)?.ptsUs, 30_000)
    XCTAssertFalse(scheduler.enqueue(frame(20_000)))
    XCTAssertEqual(scheduler.lateFrameDropCount, 4)
  }
}
