@testable import yl_player_apple
import XCTest

final class YlFallbackQualityPolicyTests: XCTestCase {
  func testAcceptsConstraintSatisfiedByFixedStream() throws {
    XCTAssertNoThrow(try YlFallbackQualityPolicy.validate(
      constraint: try YlFallbackQualityConstraint(
        validating: ["maxWidth": 1_920, "maxHeight": 1_080]
      ),
      stream: YlFallbackVideoDescriptor(width: 1_280, height: 720, bitrate: nil)
    ))
  }

  func testRejectsDimensionsExceededByFixedStream() throws {
    XCTAssertThrowsError(try YlFallbackQualityPolicy.validate(
      constraint: try YlFallbackQualityConstraint(validating: ["maxHeight": 480]),
      stream: YlFallbackVideoDescriptor(
        width: 1_280,
        height: 720,
        bitrate: 2_000_000
      )
    )) { error in
      XCTAssertEqual(
        (error as? NativePlayerError)?.code,
        "decoder.quality_constraint_unsupported"
      )
    }
  }

  func testRejectsBitrateCeilingWhenBitrateMetadataIsUnavailable() throws {
    XCTAssertThrowsError(try YlFallbackQualityPolicy.validate(
      constraint: try YlFallbackQualityConstraint(
        validating: ["maxBitrate": 1_000_000]
      ),
      stream: YlFallbackVideoDescriptor(width: 1_280, height: 720, bitrate: nil)
    )) { error in
      XCTAssertEqual(
        (error as? NativePlayerError)?.code,
        "decoder.quality_constraint_unsupported"
      )
    }
  }

  func testKnownBitrateAcceptsCeilingAndRejectsExceededCeiling() throws {
    let stream = YlFallbackVideoDescriptor(
      width: 1_280,
      height: 720,
      bitrate: 2_000_000
    )

    XCTAssertNoThrow(try YlFallbackQualityPolicy.validate(
      constraint: try YlFallbackQualityConstraint(
        validating: ["maxBitrate": 2_000_000]
      ),
      stream: stream
    ))
    XCTAssertThrowsError(try YlFallbackQualityPolicy.validate(
      constraint: try YlFallbackQualityConstraint(
        validating: ["maxBitrate": 1_999_999]
      ),
      stream: stream
    ))
  }

  func testInvalidConstraintValuesReturnStableSourceError() {
    for map: [String: Any?] in [
      ["maxWidth": 0],
      ["maxHeight": -1],
      ["maxBitrate": Int64(Int32.max) + 1],
      ["maxWidth": "1280"],
      ["maxWidth": 1.5],
      ["maxWidth": true],
    ] {
      XCTAssertThrowsError(try YlFallbackQualityConstraint(validating: map)) { error in
        XCTAssertEqual((error as? NativePlayerError)?.category, "source")
        XCTAssertEqual(
          (error as? NativePlayerError)?.code,
          "source.quality_constraint_invalid"
        )
      }
    }
  }
}
