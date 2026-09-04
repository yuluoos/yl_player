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
}
