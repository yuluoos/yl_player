@testable import yl_player_apple
import XCTest

final class YlFallbackBufferBudgetTests: XCTestCase {
  func testLowLatencyBudgetUsesSpecifiedCeilings() throws {
    let configuration = PlayerConfiguration(map: ["bufferMode": "lowLatency"])

    let budget = try YlFallbackBufferBudget.make(configuration: configuration)

    XCTAssertEqual(budget.networkBytes, 4 * 1024 * 1024)
    XCTAssertEqual(budget.scheduledAudioBytes, 1 * 1024 * 1024)
    XCTAssertEqual(budget.inFlightPacketBytes, 2 * 1024 * 1024)
  }

  func testBalancedBudgetUsesSpecifiedCeilings() throws {
    let configuration = PlayerConfiguration(map: ["bufferMode": "balanced"])

    let budget = try YlFallbackBufferBudget.make(configuration: configuration)

    XCTAssertEqual(budget.networkBytes, 8 * 1024 * 1024)
    XCTAssertEqual(budget.scheduledAudioBytes, 2 * 1024 * 1024)
    XCTAssertEqual(budget.inFlightPacketBytes, 4 * 1024 * 1024)
  }

  func testAutomaticBudgetMatchesBalanced() throws {
    let automatic = try YlFallbackBufferBudget.make(
      configuration: PlayerConfiguration(map: ["bufferMode": "automatic"])
    )
    let balanced = try YlFallbackBufferBudget.make(
      configuration: PlayerConfiguration(map: ["bufferMode": "balanced"])
    )

    XCTAssertEqual(automatic, balanced)
  }

  func testStableBudgetUsesSpecifiedCeilings() throws {
    let configuration = PlayerConfiguration(map: ["bufferMode": "stable"])

    let budget = try YlFallbackBufferBudget.make(configuration: configuration)

    XCTAssertEqual(budget.networkBytes, 16 * 1024 * 1024)
    XCTAssertEqual(budget.scheduledAudioBytes, 4 * 1024 * 1024)
    XCTAssertEqual(budget.inFlightPacketBytes, 8 * 1024 * 1024)
  }

  func testCustomBudgetSumsExactlyToConfiguredLimit() throws {
    let total = 13 * 1024 * 1024 + 7
    let configuration = PlayerConfiguration(map: [
      "bufferMode": "custom",
      "maxBufferBytes": total,
    ])

    let budget = try YlFallbackBufferBudget.make(configuration: configuration)

    XCTAssertEqual(
      budget.networkBytes + budget.scheduledAudioBytes + budget.inFlightPacketBytes,
      total
    )
    XCTAssertGreaterThanOrEqual(budget.networkBytes, 1024 * 1024)
    XCTAssertGreaterThanOrEqual(budget.scheduledAudioBytes, 1024 * 1024)
    XCTAssertGreaterThanOrEqual(budget.inFlightPacketBytes, 1024 * 1024)
  }

  func testCustomBudgetBelowThreeMiBFails() {
    let configuration = PlayerConfiguration(map: [
      "bufferMode": "custom",
      "maxBufferBytes": 3 * 1024 * 1024 - 1,
    ])

    XCTAssertThrowsError(
      try YlFallbackBufferBudget.make(configuration: configuration)
    ) { error in
      XCTAssertEqual(
        (error as? NativePlayerError)?.code,
        "resource.network_buffer_limit"
      )
    }
  }

  func testParsesAndClampsNetworkConfiguration() {
    let configuration = PlayerConfiguration(map: [
      "decoderPolicy": "hardwareOnly",
      "network": [
        "connectTimeoutMs": -1,
        "readTimeoutMs": 90_000,
        "maxRetries": 99,
        "baseRetryDelayMs": -5,
        "maxRetryDelayMs": 90_000,
        "maxRedirects": 99,
      ],
    ])

    XCTAssertEqual(configuration.decoderPolicy, "hardwareOnly")
    XCTAssertEqual(configuration.network.connectTimeoutMs, 0)
    XCTAssertEqual(configuration.network.readTimeoutMs, 60_000)
    XCTAssertEqual(configuration.network.maxRetries, 20)
    XCTAssertEqual(configuration.network.baseRetryDelayMs, 0)
    XCTAssertEqual(configuration.network.maxRetryDelayMs, 60_000)
    XCTAssertEqual(configuration.network.maxRedirects, 20)
  }
}
