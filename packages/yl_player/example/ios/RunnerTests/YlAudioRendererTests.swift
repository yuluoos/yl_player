@testable import yl_player_ios
import AVFAudio
import XCTest
import YlFFmpegBridge

final class YlAudioRendererTests: XCTestCase {
  private final class Token {}

  private final class FakeConverter: YlAudioPacketConverting {
    var configurationError: Error?
    var outputDurationUs: Int64 = 250_000
    var outputBytes = 1_000

    func configure(stream: YlAudioStreamConfiguration) throws {
      if let configurationError { throw configurationError }
    }

    func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate {
      YlAudioBufferEstimate(durationUs: outputDurationUs, byteCount: outputBytes)
    }

    func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer {
      YlScheduledAudioBuffer(
        payload: Token(),
        ptsUs: packet.ptsUs,
        durationUs: outputDurationUs,
        byteCount: outputBytes,
        generation: packet.generation
      )
    }
  }

  private final class FakeOutput: YlAudioOutputDriving {
    var volume: Float = 1
    var rate: Float = 1
    let renderedAudioTime: YlRenderedAudioTime? = nil
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var resetCount = 0
    private(set) var disposeCount = 0
    private(set) var completions = [() -> Void]()

    func configure(sampleRate: Double, channelCount: Int) throws {}
    func schedule(_ buffer: YlScheduledAudioBuffer, completion: @escaping () -> Void) {
      completions.append(completion)
    }
    func play() throws { playCount += 1 }
    func pause() { pauseCount += 1 }
    func reset() { resetCount += 1 }
    func dispose() { disposeCount += 1 }
  }

  private func stream() -> YlAudioStreamConfiguration {
    YlAudioStreamConfiguration(
      codec: .aac,
      sampleRate: 48_000,
      channelCount: 1,
      magicCookie: Data([0x11, 0x88, 0x56, 0xe5, 0x00]),
      generation: 1
    )
  }

  private func packet(generation: UInt64 = 1) -> YlCompressedAudioPacket {
    YlCompressedAudioPacket(
      data: Data(repeating: 1, count: 32),
      ptsUs: 0,
      durationUs: 21_333,
      generation: generation
    )
  }

  func testConfigurationFailureMapsToStableAACError() {
    let converter = FakeConverter()
    converter.configurationError = NSError(domain: "test", code: 1)
    let renderer = YlAudioRenderer(converter: converter, output: FakeOutput())

    XCTAssertThrowsError(try renderer.configure(stream: stream())) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "decoder.audio_aac_unsupported")
    }
  }

  func testBalancedDurationAndByteCapsAreHardLimits() throws {
    let converter = FakeConverter()
    let output = FakeOutput()
    let renderer = YlAudioRenderer(
      maxScheduledDurationUs: 500_000,
      maxScheduledBytes: 3_000,
      converter: converter,
      output: output
    )
    try renderer.configure(stream: stream())

    XCTAssertEqual(try renderer.enqueue(packet: packet()), .scheduled)
    XCTAssertEqual(try renderer.enqueue(packet: packet()), .scheduled)
    XCTAssertEqual(try renderer.enqueue(packet: packet()), .wouldExceedDuration)
    XCTAssertEqual(renderer.scheduledDurationUs, 500_000)
    XCTAssertEqual(renderer.scheduledBytes, 2_000)

    output.completions[0]()
    XCTAssertEqual(renderer.scheduledDurationUs, 250_000)
    XCTAssertEqual(try renderer.enqueue(packet: packet()), .scheduled)
  }

  func testByteLimitWinsBeforeConversion() throws {
    let converter = FakeConverter()
    converter.outputDurationUs = 10_000
    converter.outputBytes = 1_001
    let renderer = YlAudioRenderer(
      maxScheduledDurationUs: 500_000,
      maxScheduledBytes: 1_000,
      converter: converter,
      output: FakeOutput()
    )
    try renderer.configure(stream: stream())
    XCTAssertEqual(try renderer.enqueue(packet: packet()), .wouldExceedBytes)
    XCTAssertEqual(renderer.scheduledBytes, 0)
  }

  func testUnderrunClampAndStaleCompletionSuppression() throws {
    let converter = FakeConverter()
    let output = FakeOutput()
    let renderer = YlAudioRenderer(converter: converter, output: output)
    try renderer.configure(stream: stream())

    try renderer.play()
    XCTAssertEqual(renderer.underrunCount, 1)
    renderer.setVolume(-1)
    renderer.setRate(9)
    XCTAssertEqual(output.volume, 0)
    XCTAssertEqual(output.rate, 4)

    XCTAssertEqual(try renderer.enqueue(packet: packet()), .scheduled)
    let staleCompletion = output.completions[0]
    renderer.flush()
    XCTAssertEqual(renderer.scheduledBytes, 0)
    staleCompletion()
    XCTAssertEqual(renderer.scheduledBytes, 0)
    XCTAssertEqual(renderer.scheduledDurationUs, 0)

    renderer.dispose()
    renderer.dispose()
    XCTAssertEqual(output.disposeCount, 1)
  }

  func testAppleConverterDecodesFixtureAACPacket() throws {
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

    var audioIndex: Int32?
    for index in 0..<mediaInfo.stream_count {
      var streamInfo = YLFStreamInfo()
      XCTAssertEqual(ylf_copy_stream_info(context, index, &streamInfo), 0)
      if Int(streamInfo.kind) == YLFStreamAudio {
        audioIndex = streamInfo.index
      }
    }
    let selectedAudioIndex = try XCTUnwrap(audioIndex)
    var compressedPacket: YlCompressedAudioPacket?
    while compressedPacket == nil {
      var packet: YLFPacketRef?
      XCTAssertEqual(ylf_read_packet(context, &packet), 0)
      guard let ownedPacket = packet else { continue }
      if ylf_packet_stream_index(ownedPacket) == selectedAudioIndex {
        let bytes = try XCTUnwrap(ylf_packet_data(ownedPacket))
        compressedPacket = YlCompressedAudioPacket(
          data: Data(bytes: bytes, count: ylf_packet_size(ownedPacket)),
          ptsUs: ylf_packet_pts_us(ownedPacket),
          durationUs: ylf_packet_duration_us(ownedPacket),
          generation: 1
        )
      }
      ylf_packet_release(&packet)
    }

    let converter = YlAppleAACConverter()
    try converter.configure(stream: stream())
    let converted = try converter.convert(packet: try XCTUnwrap(compressedPacket))
    let pcm = try XCTUnwrap(converted.payload as? AVAudioPCMBuffer)
    XCTAssertGreaterThan(pcm.frameLength, 0)
    XCTAssertLessThanOrEqual(converted.durationUs, 30_000)
    XCTAssertGreaterThan(converted.byteCount, 0)
  }
}
