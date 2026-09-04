@testable import yl_player_ios
import XCTest

final class YlLiveReconnectControllerTests: XCTestCase {
  func testRetriesAreBoundedAndExponentiallyCapped() {
    let controller = YlLiveReconnectController(configuration: .init(map: [
      "maxRetries": 2,
      "baseRetryDelayMs": 10,
      "maxRetryDelayMs": 15,
    ]))

    XCTAssertEqual(controller.nextDelayMs(), 10)
    XCTAssertEqual(controller.nextDelayMs(), 15)
    XCTAssertNil(controller.nextDelayMs())
    XCTAssertEqual(controller.attempt, 2)
  }

  func testFirstFrameResetsRetryBudget() {
    let controller = YlLiveReconnectController(configuration: .init(map: [
      "maxRetries": 1,
      "baseRetryDelayMs": 7,
    ]))

    XCTAssertEqual(controller.nextDelayMs(), 7)
    controller.markFirstFrame()

    XCTAssertEqual(controller.attempt, 0)
    XCTAssertEqual(controller.nextDelayMs(), 7)
  }

  func testCancellationPreventsFutureRetriesAndInstallation() {
    let controller = YlLiveReconnectController(configuration: .init(map: [
      "maxRetries": 3,
    ]))

    controller.cancel()

    XCTAssertNil(controller.nextDelayMs())
    XCTAssertFalse(controller.shouldInstall(
      reconnectGeneration: 4,
      currentGeneration: 4
    ))
  }

  func testStaleGenerationCannotInstallReconnectedPipeline() {
    let controller = YlLiveReconnectController(configuration: .init(map: [:]))

    XCTAssertFalse(controller.shouldInstall(
      reconnectGeneration: 4,
      currentGeneration: 5
    ))
    XCTAssertTrue(controller.shouldInstall(
      reconnectGeneration: 5,
      currentGeneration: 5
    ))
  }
}
