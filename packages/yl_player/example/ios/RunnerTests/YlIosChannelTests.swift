@testable import yl_player_apple
import XCTest

final class YlIosChannelTests: XCTestCase {






  func testDecoderPolicyDefaultsToHardwareOnlyAndAcceptsLegacyInput() {
    XCTAssertEqual(PlayerConfiguration(map: [:]).decoderPolicy, "hardwareOnly")
    XCTAssertEqual(
      PlayerConfiguration(map: ["decoderPolicy": "preferHardware"]).decoderPolicy,
      "preferHardware"
    )
  }






}
