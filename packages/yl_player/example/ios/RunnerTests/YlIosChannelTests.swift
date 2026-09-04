@testable import yl_player_ios
import XCTest

final class YlIosChannelTests: XCTestCase {
  func testCapabilitiesDescribeCompletePlayerWithCanonicalMimeCodecs() {
    let capabilities = YlIosChannel.capabilities(
      hardwareH264: true,
      hardwareHevc: true
    )

    XCTAssertEqual(
      capabilities["hardwareVideoCodecs"] as? [String],
      ["video/avc", "video/hevc"]
    )
    XCTAssertEqual(
      Set(capabilities["supportedFormats"] as? [String] ?? []),
      Set(["automatic", "hls", "httpFlv", "mp4", "mov", "matroska", "flv"])
    )
    XCTAssertEqual(capabilities["maxConcurrentVideoDecoders"] as? Int, 1)
  }

  func testCapabilitiesOmitUnsupportedHardwareCodecs() {
    let capabilities = YlIosChannel.capabilities(
      hardwareH264: true,
      hardwareHevc: false
    )

    XCTAssertEqual(capabilities["hardwareVideoCodecs"] as? [String], ["video/avc"])
  }

  func testFallbackMetricsUseDartContractDroppedFrameKey() {
    let metrics = YlIosChannel.fallbackMetrics(
      openDurationMs: 20,
      firstFrameDurationMs: 40,
      bufferedDurationMs: 100,
      bufferedBytes: 4_096,
      droppedVideoFrames: 7,
      audioUnderruns: 1,
      reconnectCount: 2
    )

    XCTAssertEqual(metrics["droppedVideoFrames"] as? Int, 7)
    XCTAssertNil(metrics["droppedFrames"] ?? nil)
  }

  func testDecoderPolicyDefaultsToHardwareOnlyAndAcceptsLegacyInput() {
    XCTAssertEqual(PlayerConfiguration(map: [:]).decoderPolicy, "hardwareOnly")
    XCTAssertEqual(
      PlayerConfiguration(map: ["decoderPolicy": "preferHardware"]).decoderPolicy,
      "preferHardware"
    )
  }

  func testChannelGenerationsAreStrictlyIncreasing() {
    let first = YlIosChannelGeneration.next()
    let second = YlIosChannelGeneration.next()

    XCTAssertGreaterThan(second, first)
  }

  func testFullStateEnvelopeUsesVersionedGeneration() {
    let envelope = YlIosChannel.fullState(
      playerId: 7,
      generation: 9,
      state: ["status": "ready"]
    )

    XCTAssertEqual(envelope["playerId"] as? Int64, 7)
    XCTAssertEqual(envelope["protocolVersion"] as? Int, 1)
    XCTAssertEqual(envelope["generation"] as? UInt64, 9)
    XCTAssertEqual(envelope["type"] as? String, "state")
    XCTAssertEqual(
      (envelope["state"] as? [String: Any?])?["status"] as? String,
      "ready"
    )
  }

  func testDeltaEnvelopeContainsOnlyDynamicPayload() {
    let envelope = YlIosChannel.stateDelta(
      playerId: 7,
      generation: 9,
      delta: [
        "positionMs": 1_000,
        "bufferedPositionMs": 3_000,
        "isAtLiveEdge": false,
        "liveOffsetMs": 2_000,
        "metrics": ["droppedVideoFrames": 2],
      ]
    )

    XCTAssertEqual(envelope["protocolVersion"] as? Int, 1)
    XCTAssertEqual(envelope["generation"] as? UInt64, 9)
    XCTAssertEqual(envelope["type"] as? String, "stateDelta")
    XCTAssertNil((envelope["delta"] as? [String: Any?])?["capabilities"] ?? nil)
  }
}
