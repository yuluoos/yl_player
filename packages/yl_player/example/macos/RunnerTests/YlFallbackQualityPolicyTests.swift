@testable import yl_player_apple
import XCTest

final class YlFallbackQualityPolicyTests: XCTestCase {
  func testAcceptsConstraintSatisfiedByFixedStream() throws {
    XCTAssertNoThrow(try YlFallbackQualityPolicy.validate(
      constraint: try YlFallbackQualityConstraint(
        validating: YlAppleVideoConstraints(maxWidth: 1_920, maxHeight: 1_080, maxBitrate: nil)
      ),
      stream: YlFallbackVideoDescriptor(width: 1_280, height: 720, bitrate: nil)
    ))
  }

  func testRejectsDimensionsExceededByFixedStream() throws {
    XCTAssertThrowsError(try YlFallbackQualityPolicy.validate(
      constraint: try YlFallbackQualityConstraint(validating: YlAppleVideoConstraints(maxWidth: nil, maxHeight: 480, maxBitrate: nil)),
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
        validating: YlAppleVideoConstraints(maxWidth: nil, maxHeight: nil, maxBitrate: 1_000_000)
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
        validating: YlAppleVideoConstraints(maxWidth: nil, maxHeight: nil, maxBitrate: 2_000_000)
      ),
      stream: stream
    ))
    XCTAssertThrowsError(try YlFallbackQualityPolicy.validate(
      constraint: try YlFallbackQualityConstraint(
        validating: YlAppleVideoConstraints(maxWidth: nil, maxHeight: nil, maxBitrate: 1_999_999)
      ),
      stream: stream
    ))
  }

  func testInvalidConstraintValuesReturnStableSourceError() {
    // String, fractional and Boolean payloads cannot enter this typed native
    // contract. Transport validation owns those malformed wire values.
    for constraints in [
      YlAppleVideoConstraints(maxWidth: 0, maxHeight: nil, maxBitrate: nil),
      YlAppleVideoConstraints(maxWidth: nil, maxHeight: -1, maxBitrate: nil),
      YlAppleVideoConstraints(maxWidth: nil, maxHeight: nil, maxBitrate: Int(Int32.max) + 1),
    ] {
      XCTAssertThrowsError(try YlFallbackQualityConstraint(validating: constraints)) { error in
        XCTAssertEqual((error as? NativePlayerError)?.category, "source")
        XCTAssertEqual(
          (error as? NativePlayerError)?.code,
          "source.quality_constraint_invalid"
        )
      }
    }
  }
}
