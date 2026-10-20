@testable import yl_player_media_core
@testable import yl_player_apple
import CoreMedia
import CoreVideo
import XCTest
import YlFFmpegBridge

final class YlVideoToolboxDecoderTests: XCTestCase {
  private final class FakeSession: YlVTSession {
    // Controlled decoder lifetime evidence; this is not a physical decode probe.
    let hardwareEvidence = YlHardwareDecoderEvidence(mode: .hardware)
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
      let diagnostic = (error as? NativePlayerError)?.diagnostic ?? ""
      XCTAssertTrue(diagnostic.contains("codec=unknown"))
      XCTAssertTrue(diagnostic.contains("configBytes=0"))
      XCTAssertTrue(diagnostic.contains("streamIndex=0"))
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
      let diagnostic = (error as? NativePlayerError)?.diagnostic ?? ""
      XCTAssertTrue(diagnostic.contains("codec=h264"))
      XCTAssertTrue(diagnostic.contains("configBytes=7"))
      XCTAssertTrue(diagnostic.contains("bridgeResult=-8"))
      XCTAssertEqual(String(describing: error), "Playback operation failed.")
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

extension YlVideoToolboxDecoderTests {
  // Build a tiny Matroska from the repository's synthetic HEVC fixture, with
  // parameter sets in its first packet and an empty-array hvcC in CodecPrivate.
  private func withInBandHEVC(transform: ([UInt8]) -> [UInt8] = { $0 }, _ body: (YLFMediaContextRef, [UInt8], URL) throws -> Void) throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "hevc_aac", withExtension: "mkv"))
    var original: YLFMediaContextRef?
    var info = YLFMediaInfo()
    XCTAssertEqual(url.path.withCString { ylf_open_local($0, &original, &info) }, 0)
    defer { ylf_close(&original) }
    let size = ylf_stream_codec_config_size(original, 0)
    var config = [UInt8](repeating: 0, count: size)
    XCTAssertEqual(ylf_copy_stream_codec_config(original, 0, &config, size), 0)
    var packet: YLFPacketRef?
    repeat {
      ylf_packet_release(&packet)
      XCTAssertEqual(ylf_read_packet(original, &packet), 0)
    } while ylf_packet_stream_index(packet) != 0
    defer { ylf_packet_release(&packet) }
    var payload: [UInt8] = []
    var offset = 23
    for _ in 0..<Int(config[22]) {
      let type = config[offset] & 63
      let count = Int(config[offset + 1]) * 256 + Int(config[offset + 2]); offset += 3
      for _ in 0..<count {
        let length = Int(config[offset]) * 256 + Int(config[offset + 1]); offset += 2
        if [32, 33, 34].contains(type) {
          payload += [0, 0, UInt8(length >> 8), UInt8(length & 255)]
          payload += config[offset..<(offset + length)]
        }
        offset += length
      }
    }
    let frame = try XCTUnwrap(ylf_packet_data(packet))
    payload += Array(UnsafeBufferPointer(start: frame, count: ylf_packet_size(packet)))
    var header = Array(config.prefix(23)); header[22] = 0
    func element(_ id: [UInt8], _ bytes: [UInt8]) -> [UInt8] {
      // Fixed 4-byte EBML sizes keep this synthetic test writer small.
      id + [0x10 | UInt8(bytes.count >> 24), UInt8((bytes.count >> 16) & 255),
            UInt8((bytes.count >> 8) & 255), UInt8(bytes.count & 255)] + bytes
    }
    let ebml = element([0x1a, 0x45, 0xdf, 0xa3],
      element([0x42, 0x86], [1]) + element([0x42, 0xf7], [1])
      + element([0x42, 0x82], Array("matroska".utf8))
      + element([0x42, 0x87], [4]) + element([0x42, 0x85], [2]))
    let track = element([0xae], element([0xd7], [1]) + element([0x73, 0xc5], [1])
      + element([0x83], [1]) + element([0x86], Array("V_MPEGH/ISO/HEVC".utf8))
      + element([0x63, 0xa2], header)
      + element([0xe0], element([0xb0], [1, 64]) + element([0xba], [0, 180])))
    let cluster = element([0x1f, 0x43, 0xb6, 0x75], element([0xe7], [0])
      + element([0xa3], [0x81, 0, 0, 0x80] + transform(payload)))
    let file = ebml + element([0x18, 0x53, 0x80, 0x67],
      element([0x15, 0x49, 0xa9, 0x66], element([0x2a, 0xd7, 0xb1], [0x0f, 0x42, 0x40]))
      + element([0x16, 0x54, 0xae, 0x6b], track) + cluster)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mkv")
    try Data(file).write(to: temporary)
    defer { try? FileManager.default.removeItem(at: temporary) }
    var context: YLFMediaContextRef?
    XCTAssertEqual(temporary.path.withCString { ylf_open_local($0, &context, &info) }, 0)
    defer { ylf_close(&context) }
    try body(XCTUnwrap(context), payload, temporary)
  }

  func testInBandHEVCFormatPreservesFirstPacketAndSeek() throws {
    try withInBandHEVC { context, payload, _ in
      XCTAssertEqual(ylf_stream_codec_config_size(context, 0), 23)
      let format = try XCTUnwrap(YlHEVCInBandConfiguration.makeFormatDescription(
        context: context, streamIndex: 0, maxPacketBytes: 1024 * 1024,
        rewind: { XCTAssertEqual(ylf_seek(context, 0), 0) }))
      XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC)
      for _ in 0..<2 {
        var packet: YLFPacketRef?
        XCTAssertEqual(ylf_read_packet(context, &packet), 0)
        XCTAssertEqual(ylf_packet_pts_us(packet), 0)
        XCTAssertTrue(ylf_packet_is_keyframe(packet))
        let data = try XCTUnwrap(ylf_packet_data(packet))
        XCTAssertEqual(Array(UnsafeBufferPointer(start: data, count: ylf_packet_size(packet))), payload)
        var sample: Unmanaged<CMSampleBuffer>?
        XCTAssertEqual(ylf_create_video_sample_buffer(&packet, format, &sample), 0)
        let retainedSample = try XCTUnwrap(sample).takeRetainedValue()
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(retainedSample).seconds, 0)
        XCTAssertNil(packet, "Sample creation transfers packet ownership")
        XCTAssertEqual(ylf_seek(context, 0), 0)
      }
    }
  }

  func testInBandHEVCRespectsCancellationAndPacketBudget() throws {
    enum Stop: Error { case cancelled }
    try withInBandHEVC { context, _, _ in
      XCTAssertThrowsError(try YlHEVCInBandConfiguration.makeFormatDescription(
        context: context, streamIndex: 0, maxPacketBytes: 1024 * 1024,
        checkCancellation: { throw Stop.cancelled }, rewind: {})) {
          XCTAssertTrue($0 is Stop)
        }
      XCTAssertNil(try YlHEVCInBandConfiguration.makeFormatDescription(
        context: context, streamIndex: 0, maxPacketBytes: 1, rewind: {}))
    }
  }

  func testInBandHEVCDoesNotProbeCompleteConfiguration() throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "hevc_aac", withExtension: "mkv"))
    var context: YLFMediaContextRef?
    var info = YLFMediaInfo()
    XCTAssertEqual(url.path.withCString { ylf_open_local($0, &context, &info) }, 0)
    defer { ylf_close(&context) }
    XCTAssertNil(try YlHEVCInBandConfiguration.makeFormatDescription(
      context: XCTUnwrap(context), streamIndex: 0, maxPacketBytes: 1024 * 1024,
      checkCancellation: { XCTFail("Complete configuration must not be probed") },
      rewind: { XCTFail("Complete configuration must not move the cursor") }))
  }
}

extension YlVideoToolboxDecoderTests {
  func testInBandHEVCRejectsTruncatedNALAndReleasesPackets() throws {
    let before = ylf_debug_outstanding_packet_count()
    try withInBandHEVC(transform: { Array($0.dropLast()) }) { context, _, _ in
      XCTAssertNil(try YlHEVCInBandConfiguration.makeFormatDescription(
        context: context, streamIndex: 0, maxPacketBytes: 1024 * 1024,
        rewind: { XCTFail("Malformed packet must not produce a format") }))
    }
    XCTAssertEqual(ylf_debug_outstanding_packet_count(), before)
  }

  func testInBandHEVCPropagatesRewindFailureAndReleasesReservations() throws {
    enum Stop: Error { case seekFailed }
    final class Reservation {}
    weak var outstanding: Reservation?
    let before = ylf_debug_outstanding_packet_count()
    try withInBandHEVC { context, _, _ in
      XCTAssertThrowsError(try YlHEVCInBandConfiguration.makeFormatDescription(
        context: context, streamIndex: 0, maxPacketBytes: 1024 * 1024,
        reserveBytes: { _ in let token = Reservation(); outstanding = token; return token },
        rewind: { throw Stop.seekFailed })) { XCTAssertTrue($0 is Stop) }
    }
    XCTAssertNil(outstanding)
    XCTAssertEqual(ylf_debug_outstanding_packet_count(), before)
  }
}

extension YlVideoToolboxDecoderTests {
  @MainActor
  func testInBandHEVCLocalReactivationKeepsRecoveredFormat() throws {
    final class Output: YlTextureOutput {
      let textureId: Int64 = 876
      func publish(_ pixelBuffer: CVPixelBuffer?) {}
      func resize(width: Int, height: Int) {}
      func clear() {}
      func dispose() {}
    }
    final class Display: YlDisplayDriving {
      var isPaused = true
      func invalidate() {}
    }
    try withInBandHEVC { _, _, url in
      let prepared = try YlPreparedFallback(source: YlAppleSourceDescriptor(
        uri: url.absoluteString, kind: .file, formatHint: .matroska), requireHardwareProbe: false)
      let factory = FakeFactory()
      var failures: [String] = []
      let backend = try YlFallbackBackend(playerId: 876,
        services: .init(platform: .current, textureOutput: Output(), makeDisplayDriver: { _ in Display() }),
        configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: prepared,
        generation: 1, videoSessionFactory: factory,
        emit: { if case let .failure(error) = $0.event { failures.append(error.code) } })
      defer { backend.dispose() }
      try backend.activate()
      let first = try XCTUnwrap(factory.session)
      backend.deactivate()
      XCTAssertEqual(first.invalidateCount, 1)
      try backend.activate()
      let restored = try XCTUnwrap(factory.session)
      XCTAssertFalse(first === restored)
      XCTAssertTrue(backend.isActive)
      XCTAssertTrue(failures.isEmpty)
    }
  }
}
