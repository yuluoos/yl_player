import Cocoa
import FlutterMacOS
import XCTest
@testable import yl_player_macos

class RunnerTests: XCTestCase {

  func testConfigurationDefaultsToHardwareOnly() {
    let configuration = PlayerConfiguration(map: [:])

    XCTAssertEqual(configuration.decoderPolicy, "hardwareOnly")
    XCTAssertEqual(configuration.bufferMode, "automatic")
  }

  func testLifecycleTerminationDisposesAllPlayers() {
    XCTAssertEqual(
      YlMacosLifecyclePolicy.action(for: .willTerminate),
      .disposeAll
    )
  }

  func testLifecycleResignActivePreservesPlayback() {
    XCTAssertEqual(
      YlMacosLifecyclePolicy.action(for: .didResignActive),
      .preserve
    )
  }

  func testCapabilitiesUseCanonicalCodecIdentifiers() {
    let capabilities = YlMacosChannel.capabilities(
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

  func testChannelGenerationsAreStrictlyIncreasing() {
    let first = YlMacosChannelGeneration.next()
    let second = YlMacosChannelGeneration.next()

    XCTAssertGreaterThan(second, first)
  }

  func testStateEnvelopeUsesVersionedGeneration() {
    let envelope = YlMacosChannel.fullState(
      playerId: 7,
      generation: 9,
      state: ["status": "ready"]
    )

    XCTAssertEqual(envelope["playerId"] as? Int64, 7)
    XCTAssertEqual(envelope["protocolVersion"] as? Int, 1)
    XCTAssertEqual(envelope["generation"] as? UInt64, 9)
    XCTAssertEqual(envelope["type"] as? String, "state")
  }

  func testPluginChannelNamesMatchTheDartAdapter() {
    XCTAssertEqual(
      YlPlayerMacosPlugin.methodChannelName,
      "dev.ylplayer.yl_player_macos/methods"
    )
    XCTAssertEqual(
      YlPlayerMacosPlugin.eventChannelName,
      "dev.ylplayer.yl_player_macos/events"
    )
  }
}
