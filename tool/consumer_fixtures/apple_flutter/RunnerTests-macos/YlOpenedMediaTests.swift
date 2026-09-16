@testable import yl_player_apple
import AVFoundation
import Darwin
import Foundation
import XCTest
import YlFFmpegBridge

final class YlOpenedMediaTests: XCTestCase {
  private final class CancellationProbe {
    var count = 0
  }

  private final class MemoryByteSource: YlByteSource {
    let bytes: Data
    let probe: CancellationProbe
    private var offset = 0
    private var cancelled = false
    private(set) var seekCount = 0

    init(bytes: Data, probe: CancellationProbe = CancellationProbe()) {
      self.bytes = bytes
      self.probe = probe
    }

    var length: Int64? { Int64(bytes.count) }
    var supportsRandomAccess: Bool { true }
    var currentOffset: Int64 { Int64(offset) }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
      guard offset < bytes.count else { return 0 }
      let count = min(buffer.count, bytes.count - offset)
      bytes.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: offset..<(offset + count))
      offset += count
      return count
    }

    func seek(to offset: Int64) throws -> Int64 {
      seekCount += 1
      guard offset >= 0, offset <= Int64(bytes.count) else {
        throw YlByteSourceError.invalidOffset(
          expected: Int64(self.offset),
          actual: offset
        )
      }
      self.offset = Int(offset)
      return offset
    }

    func cancel() {
      guard !cancelled else { return }
      cancelled = true
      probe.count += 1
    }
    func handleMemoryWarning() {}
  }

  private func fixture() throws -> URL {
    try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mkv")
    )
  }

  func testNetworkOpenMatchesLocalStreamMetadata() throws {
    let url = try fixture()
    let bytes = try Data(contentsOf: url)
    let local = try YlOpenedMedia(recipe: .local(path: url.path, container: .matroska))
    let network = try YlOpenedMedia(byteSource: MemoryByteSource(bytes: bytes))
    defer {
      local.close()
      network.close()
    }

    XCTAssertEqual(network.info.stream_count, local.info.stream_count)
    XCTAssertEqual(network.info.duration_us, local.info.duration_us)
    for index in 0..<local.info.stream_count {
      var localStream = YLFStreamInfo()
      var networkStream = YLFStreamInfo()
      XCTAssertEqual(ylf_copy_stream_info(local.context, index, &localStream), 0)
      XCTAssertEqual(ylf_copy_stream_info(network.context, index, &networkStream), 0)
      XCTAssertEqual(networkStream.kind, localStream.kind)
      XCTAssertEqual(networkStream.codec, localStream.codec)
      XCTAssertEqual(networkStream.width, localStream.width)
      XCTAssertEqual(networkStream.height, localStream.height)
      XCTAssertEqual(networkStream.sample_rate, localStream.sample_rate)
    }
  }

  func testCallbackSourceOutlivesContextAndCloseCancelsExactlyOnce() throws {
    let probe = CancellationProbe()
    var source: MemoryByteSource? = MemoryByteSource(
      bytes: try Data(contentsOf: fixture()),
      probe: probe
    )
    weak var weakSource = source
    var media: YlOpenedMedia? = try YlOpenedMedia(byteSource: source!)
    source = nil

    XCTAssertNotNil(weakSource)
    media?.close()
    media?.close()
    media = nil

    XCTAssertEqual(probe.count, 1)
    XCTAssertNil(weakSource)
  }

  func testCancelInputWakesSourceBeforeContextIsClosed() throws {
    let probe = CancellationProbe()
    let source = MemoryByteSource(
      bytes: try Data(contentsOf: fixture()),
      probe: probe
    )
    let media = try YlOpenedMedia(byteSource: source)

    media.cancelInput()
    XCTAssertEqual(probe.count, 1)
    XCTAssertNotNil(media.context)

    media.close()
    XCTAssertEqual(probe.count, 1)
    XCTAssertNil(media.context)
  }

  func testCancelledControlOperationCannotReachFFmpegOrByteSourceSeek() throws {
    let source = MemoryByteSource(bytes: try Data(contentsOf: fixture()))
    let media = try YlOpenedMedia(byteSource: source)
    defer { media.close() }
    let seekCountBeforeCommand = source.seekCount
    let token = YlOpenCancellationToken()
    token.cancel()
    media.beginControlOperation(token)
    defer { media.endControlOperation() }

    XCTAssertThrowsError(try media.seek(toMediaTimeUs: 500_000)) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "network.cancelled")
    }
    XCTAssertEqual(source.seekCount, seekCountBeforeCommand)
  }

  func testHundredOpenReadCloseCyclesReleaseEveryPacket() throws {
    let bytes = try Data(contentsOf: fixture())
    for _ in 0..<100 {
      let media = try YlOpenedMedia(byteSource: MemoryByteSource(bytes: bytes))
      var packet: YLFPacketRef?
      XCTAssertEqual(ylf_read_packet(media.context, &packet), 0)
      XCTAssertNotNil(packet)
      media.close()
      XCTAssertEqual(ylf_debug_outstanding_packet_count(), 0)
    }
  }

  func testMediaSeekUsesByteSourceAndFFmpegTimeline() throws {
    let media = try YlOpenedMedia(
      byteSource: MemoryByteSource(bytes: try Data(contentsOf: fixture()))
    )
    defer { media.close() }

    XCTAssertEqual(try media.seek(toMediaTimeUs: 900_000), 900_000)
    var packet: YLFPacketRef?
    XCTAssertEqual(ylf_read_packet(media.context, &packet), 0)
    XCTAssertNotNil(packet)
    ylf_packet_release(&packet)
  }

  func testFlvOpenFailureUsesFormatSpecificError() {
    XCTAssertThrowsError(try YlOpenedMedia(
      recipe: .local(path: "/dev/null", container: .flv)
    )) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "container.flv_open_failed")
    }
  }
}


extension YlOpenedMediaTests {
  func testMp4CompatibilityInspectionPreservesNativeAacAndRoutesHev1Dts() throws {
    for (name, expected) in [("h264_aac", false), ("hevc_dts", true)] {
      let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mp4"))
      let source = YlAppleSourceDescriptor(uri: url.absoluteString, kind: .file, formatHint: .mp4)
      XCTAssertEqual(YlSourceRouter.route(source), .avPlayer)
      XCTAssertEqual(try YlMp4CompatibilityInspector.requiresFallback(source,
        configuration: .init(map: [:]), token: .init()), expected)
    }
  }

  func testDtsMp4CenterChannelReachesBothStereoChannelsAndResetIsReusable() throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "hevc_dts", withExtension: "mp4"))
    let media = try YlOpenedMedia(recipe: .local(path: url.path, container: .mp4))
    defer { media.close() }
    let context = try XCTUnwrap(media.context)
    var audio: YLFStreamInfo?
    for index in 0..<media.info.stream_count {
      var stream = YLFStreamInfo()
      XCTAssertEqual(ylf_copy_stream_info(context, index, &stream), 0)
      if Int(stream.codec) == YLFCodecDTS { audio = stream }
    }
    let stream = try XCTUnwrap(audio)
    XCTAssertEqual(stream.channel_count, 6)
    let converter = YlAppleCompressedAudioConverter()
    try converter.configure(stream: .init(codec: .dts, sampleRate: 48_000,
      channelCount: 6, magicCookie: Data(), generation: 3))
    var totalFrames = 0
    var energy = 0.0
    var firstPacket: YlCompressedAudioPacket?
    while true {
      var packet: YLFPacketRef?
      let result = ylf_read_packet(context, &packet)
      if Int(result) == YLFResultEOF { break }
      XCTAssertEqual(result, 0)
      let value = try XCTUnwrap(packet)
      defer { ylf_packet_release(&packet) }
      if ylf_packet_stream_index(value) != stream.index { continue }
      let bytes = try XCTUnwrap(ylf_packet_data(value))
      let input = YlCompressedAudioPacket(data: Data(bytes: bytes, count: ylf_packet_size(value)),
        ptsUs: ylf_packet_pts_us(value), durationUs: ylf_packet_duration_us(value), generation: 3)
      if firstPacket == nil {
        firstPacket = input
        let plan = try YlBoundedBufferPlan(minDurationMs: 0, maxDurationMs: 100, maxBytes: 4 * 1024 * 1024)
        let renderer = YlAudioRenderer(maxScheduledDurationUs: 100_000,
          boundedPlan: plan, output: Mp4TestAudioOutput())
        defer { renderer.dispose() }
        try renderer.configure(stream: .init(codec: .dts, sampleRate: 48_000,
          channelCount: 6, magicCookie: Data(), generation: 3))
        XCTAssertEqual(try renderer.enqueue(packet: input), .scheduled,
          "An actual 512-sample DTS frame fits a 100ms window despite larger decode scratch")
      }
      let output = try XCTUnwrap(converter.convert(packet: input))
      let pcm = try XCTUnwrap(output.payload as? AVAudioPCMBuffer)
      XCTAssertEqual(pcm.format.channelCount, 2)
      XCTAssertEqual(output.ptsUs, input.ptsUs)
      XCTAssertEqual(output.generation, 3)
      let channels = try XCTUnwrap(pcm.floatChannelData)
      for frame in 0..<Int(pcm.frameLength) {
        let left = channels[0][frame * Int(pcm.stride)]
        let right = pcm.format.isInterleaved ? channels[0][frame * 2 + 1] : channels[1][frame]
        XCTAssertEqual(left, right, accuracy: 0.000_001, "Center must reach both channels equally")
        energy += Double(left * left)
      }
      totalFrames += Int(pcm.frameLength)
    }
    XCTAssertGreaterThan(totalFrames, 47_000)
    XCTAssertLessThan(totalFrames, 49_000)
    XCTAssertGreaterThan(energy, 1, "A center-only DTS track must not become silent stereo")
    converter.reset()
    let replay = try XCTUnwrap(converter.convert(packet: XCTUnwrap(firstPacket)))
    XCTAssertEqual(replay.generation, 3)
    XCTAssertGreaterThan(replay.durationUs, 0)
  }

  func testDtsMalformedPacketFailsWithoutPublishingPcm() throws {
    let converter = YlAppleCompressedAudioConverter()
    try converter.configure(stream: .init(codec: .dts, sampleRate: 48_000,
      channelCount: 6, magicCookie: Data(), generation: 1))
    XCTAssertThrowsError(try converter.convert(packet: .init(data: Data([1, 2, 3, 4]),
      ptsUs: 0, durationUs: 10_666, generation: 1)))
  }
}

private final class Mp4TestAudioOutput: YlAudioOutputDriving {
  var volume: Float = 1
  var rate: Float = 1
  var renderedAudioTime: YlRenderedAudioTime? { nil }
  func configure(sampleRate: Double, channelCount: Int) throws {}
  func schedule(_ buffer: YlScheduledAudioBuffer, completion: @escaping () -> Void) {}
  func play() throws {}
  func pause() {}
  func reset() {}
  func dispose() {}
}
