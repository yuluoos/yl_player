import CoreMedia
import CoreVideo
import XCTest
@testable import yl_player_apple

final class YlFELVideoPipelineTests: XCTestCase {
  private final class Session: YlVTSession {
    let usesHardwareDecoder = true
    let hardwareEvidence = YlHardwareDecoderEvidence(mode: .hardware)
    var invalidated = false
    func decode(_ sample: CMSampleBuffer, generation: UInt64,
                reservation: YlVideoDecodeReservation?) -> OSStatus { noErr }
    func flush() {}
    func invalidate() { invalidated = true }
  }

  private final class Factory: YlVTSessionFactory {
    var sessions: [Session] = []
    var dimensions: [CMVideoDimensions] = []
    func makeSession(formatDescription: CMVideoFormatDescription,
                     output: @escaping (YlVTDecodedImage) -> Void) throws -> YlVTSession {
      let session = Session()
      sessions.append(session)
      dimensions.append(CMVideoFormatDescriptionGetDimensions(formatDescription))
      return session
    }
  }

  func testEnhancementWithoutHDRTagStillRequestsTenBitPrecision() throws {
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
      codecType: kCMVideoCodecType_HEVC, width: 16, height: 16,
      extensions: nil, formatDescriptionOut: &format), noErr)
    let residual = try XCTUnwrap(format)
    XCTAssertEqual(YlHDRVideoPolicy.pixelFormat(for: residual), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    XCTAssertEqual(YlFELVideoDecoder.pixelFormat(for: residual), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
  }

  func testUnsupportedMetadataHasSpecificPublicFailure() {
    XCTAssertThrowsError(try YlFELFailure.metadata(["schemaVersion": 2])) { error in
      let failure = YlAppleSafeDiagnostics.failure(error, scope: .command)
      XCTAssertEqual(failure.code, "decoder.dolby_vision_fel_metadata_unsupported")
      XCTAssertEqual(failure.category, .unsupported)
    }
  }

  func testOrdinaryVideoStillCreatesOneDecoderAfterResourceReplacement() throws {
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
      codecType: kCMVideoCodecType_H264, width: 16, height: 16,
      extensions: nil, formatDescriptionOut: &format), noErr)
    let factory = Factory()
    let pipeline = YlVideoPipeline(format: try XCTUnwrap(format),
      bufferBudget: try .make(configuration: PlayerConfiguration(map: [:])), factory: factory)
    try pipeline.initializeDecoder()
    XCTAssertEqual(factory.sessions.count, 1)
    let previous = pipeline.detach()
    previous?.dispose()
    pipeline.install(try pipeline.prepareCurrent())
    XCTAssertEqual(factory.sessions.count, 2)
    XCTAssertTrue(factory.sessions[0].invalidated)
    XCTAssertFalse(factory.sessions[1].invalidated)
    pipeline.discardDecoder()
    XCTAssertFalse(pipeline.hasDecoder)
    XCTAssertTrue(factory.sessions[1].invalidated)
  }
}
