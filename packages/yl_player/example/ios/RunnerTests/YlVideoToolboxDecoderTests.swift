@testable import yl_player_apple
import CoreMedia
import CoreVideo
import XCTest
import YlFFmpegBridge

final class YlVideoToolboxDecoderTests: XCTestCase {
  private final class FakeSession: YlVTSession {
    let usesHardwareDecoder = true
    let output: (YlVTDecodedImage) -> Void
    private(set) var invalidateCount = 0
    private(set) var flushCount = 0
    var decodeStatus: OSStatus = noErr

    init(output: @escaping (YlVTDecodedImage) -> Void) {
      self.output = output
    }

    func decode(_ sample: CMSampleBuffer, generation: UInt64, reservation: YlVideoDecodeReservation?) -> OSStatus {
      decodeStatus
    }

    func flush() {
      flushCount += 1
    }

    func invalidate() {
      invalidateCount += 1
    }
  }

  private final class FakeFactory: YlVTSessionFactory {
    private(set) var session: FakeSession?

    func makeSession(
      formatDescription: CMVideoFormatDescription,
      output: @escaping (YlVTDecodedImage) -> Void
    ) throws -> YlVTSession {
      let session = FakeSession(output: output)
      self.session = session
      return session
    }
  }

  private final class LifetimeCounter {
    private(set) var released = 0

    func increment() {
      released += 1
    }
  }

  private final class Token {
    let counter: LifetimeCounter

    init(_ counter: LifetimeCounter) {
      self.counter = counter
    }

    deinit {
      counter.increment()
    }
  }

  private func formatDescription(
    codec: CMVideoCodecType = kCMVideoCodecType_H264
  ) throws -> CMVideoFormatDescription {
    var description: CMVideoFormatDescription?
    XCTAssertEqual(
      CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: codec,
        width: 16,
        height: 16,
        extensions: nil,
        formatDescriptionOut: &description
      ),
      noErr
    )
    return try XCTUnwrap(description)
  }

  private func sampleBuffer() throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        16,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
      ),
      kCVReturnSuccess
    )
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 24),
      presentationTimeStamp: .zero,
      decodeTimeStamp: .invalid
    )
    var imageFormat: CMVideoFormatDescription?
    XCTAssertEqual(
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: try XCTUnwrap(pixelBuffer),
        formatDescriptionOut: &imageFormat
      ),
      noErr
    )
    var sample: CMSampleBuffer?
    XCTAssertEqual(
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: try XCTUnwrap(pixelBuffer),
        formatDescription: try XCTUnwrap(imageFormat),
        sampleTiming: &timing,
        sampleBufferOut: &sample
      ),
      noErr
    )
    return try XCTUnwrap(sample)
  }

  func testInvalidBridgeConfigurationMapsToStableError() {
    XCTAssertThrowsError(
      try YlVideoToolboxDecoder.makeFormatDescription(context: nil, streamIndex: 0)
    ) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "decoder.video_configuration_invalid")
      XCTAssertEqual((error as? NativePlayerError)?.category, "decoderFailure")
    }
  }

  func testMalformedH264ExtradataMapsToStableError() {
    let malformedConfiguration: [UInt8] = [1, 0x64, 0, 0x1f, 0xff, 0xe1, 0]
    XCTAssertThrowsError(
      try YlVideoToolboxDecoder.makeFormatDescription(
        codec: Int32(exactly: YLFCodecH264)!,
        configuration: malformedConfiguration
      )
    ) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "decoder.video_configuration_invalid")
      XCTAssertEqual((error as? NativePlayerError)?.category, "decoderFailure")
    }
  }

  func testUnsupportedCodecMapsToHardwareUnavailable() throws {
    let factory = YlHardwareVTSessionFactory()
    XCTAssertThrowsError(
      try factory.makeSession(formatDescription: formatDescription(codec: kCMVideoCodecType_JPEG)) { _ in }
    ) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "decoder.video_hardware_unavailable")
      XCTAssertEqual((error as? NativePlayerError)?.category, "decoderUnsupported")
    }
  }

  func testOldGenerationOutputIsDroppedAndReleased() throws {
    let factory = FakeFactory()
    var receivedPTS = [Int64]()
    let decoder = try YlVideoToolboxDecoder(
      formatDescription: formatDescription(),
      factory: factory,
      onFrame: { receivedPTS.append($0.ptsUs) },
      onError: { XCTFail("Unexpected decoder error: \($0)") }
    )
    decoder.decode(sample: try sampleBuffer(), generation: 2)

    let counter = LifetimeCounter()
    factory.session?.output(YlVTDecodedImage(
      status: noErr,
      pixelBuffer: try pixelBuffer(),
      pts: CMTime(value: 1, timescale: 10),
      duration: CMTime(value: 1, timescale: 24),
      keyframe: true,
      generation: 1,
      ownershipToken: Token(counter)
    ))
    XCTAssertEqual(receivedPTS, [])
    XCTAssertEqual(counter.released, 1)

    factory.session?.output(YlVTDecodedImage(
      status: noErr,
      pixelBuffer: try pixelBuffer(),
      pts: CMTime(value: 2, timescale: 10),
      duration: CMTime(value: 1, timescale: 24),
      keyframe: false,
      generation: 2,
      ownershipToken: nil
    ))
    XCTAssertEqual(receivedPTS, [200_000])
  }

  func testDisposeIsIdempotent() throws {
    let factory = FakeFactory()
    let decoder = try YlVideoToolboxDecoder(
      formatDescription: formatDescription(),
      factory: factory,
      onFrame: { _ in },
      onError: { _ in }
    )
    decoder.dispose()
    decoder.dispose()
    XCTAssertEqual(factory.session?.invalidateCount, 1)
  }

  func testOldGenerationDecoderFailureIsSuppressed() throws {
    let factory = FakeFactory()
    var errors: [NativePlayerError] = []
    let decoder = try YlVideoToolboxDecoder(
      formatDescription: formatDescription(),
      factory: factory,
      onFrame: { _ in XCTFail("Unexpected stale frame") },
      onError: { errors.append($0) }
    )
    decoder.decode(sample: try sampleBuffer(), generation: 2)

    factory.session?.output(YlVTDecodedImage(
      status: -1,
      pixelBuffer: nil,
      pts: .zero,
      duration: .invalid,
      keyframe: false,
      generation: 1,
      ownershipToken: nil
    ))

    XCTAssertTrue(errors.isEmpty)
    decoder.dispose()
  }

  func testSuccessfulDroppedFrameDoesNotFailDecoder() throws {
    let factory = FakeFactory()
    var errors: [NativePlayerError] = []
    let decoder = try YlVideoToolboxDecoder(
      formatDescription: formatDescription(),
      factory: factory,
      onFrame: { _ in XCTFail("Unexpected decoded frame") },
      onError: { errors.append($0) }
    )
    decoder.decode(sample: try sampleBuffer(), generation: 1)

    factory.session?.output(YlVTDecodedImage(
      status: noErr,
      pixelBuffer: nil,
      pts: CMTime(value: 1, timescale: 24),
      duration: CMTime(value: 1, timescale: 24),
      keyframe: false,
      generation: 1,
      ownershipToken: nil
    ))

    XCTAssertTrue(errors.isEmpty)
    decoder.dispose()
  }

  func testFixtureDecodesFirstFrameOrReportsHardwareUnavailable() throws {
    let fixture = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mkv")
    )
    var context: YLFMediaContextRef?
    var mediaInfo = YLFMediaInfo()
    XCTAssertEqual(
      fixture.path.withCString { ylf_open_local($0, &context, &mediaInfo) },
      0
    )
    defer {
      ylf_close(&context)
      XCTAssertEqual(ylf_debug_outstanding_packet_count(), 0)
    }

    var videoIndex: Int32?
    for index in 0..<mediaInfo.stream_count {
      var stream = YLFStreamInfo()
      XCTAssertEqual(ylf_copy_stream_info(context, index, &stream), 0)
      if Int(stream.kind) == YLFStreamVideo {
        videoIndex = stream.index
      }
    }
    let streamIndex = try XCTUnwrap(videoIndex)
    let format = try YlVideoToolboxDecoder.makeFormatDescription(
      context: context,
      streamIndex: streamIndex
    )

    var decoderErrors = [NativePlayerError]()
    var decodedFrameHandler: ((YlVideoFrame) -> Void)?
    let decoder: YlVideoToolboxDecoder
    do {
      decoder = try YlVideoToolboxDecoder(
        formatDescription: format,
        onFrame: { frame in decodedFrameHandler?(frame) },
        onError: { decoderErrors.append($0) }
      )
    } catch {
      XCTAssertEqual(
        (error as? NativePlayerError)?.code,
        "decoder.video_hardware_unavailable"
      )
      XCTAssertEqual(
        (error as? NativePlayerError)?.category,
        "decoderUnsupported"
      )
      return
    }
    let frameExpectation = expectation(description: "first decoded H.264 frame")
    frameExpectation.assertForOverFulfill = false
    decodedFrameHandler = { _ in frameExpectation.fulfill() }

    for _ in 0..<120 {
      var packet: YLFPacketRef?
      let readResult = ylf_read_packet(context, &packet)
      if readResult == 1 { break }
      XCTAssertEqual(readResult, 0)
      guard let ownedPacket = packet else { continue }
      guard ylf_packet_stream_index(ownedPacket) == streamIndex else {
        ylf_packet_release(&packet)
        continue
      }
      var unmanagedSample: Unmanaged<CMSampleBuffer>?
      XCTAssertEqual(
        ylf_create_video_sample_buffer(&packet, format, &unmanagedSample),
        0
      )
      decoder.decode(
        sample: try XCTUnwrap(unmanagedSample).takeRetainedValue(),
        generation: 1
      )
    }
    decoder.flush()
    wait(for: [frameExpectation], timeout: 2)
    decoder.dispose()
    XCTAssertTrue(decoderErrors.isEmpty, "Unexpected errors: \(decoderErrors)")
  }

  private func pixelBuffer() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        16,
        kCVPixelFormatType_32BGRA,
        nil,
        &buffer
      ),
      kCVReturnSuccess
    )
    return try XCTUnwrap(buffer)
  }
}
