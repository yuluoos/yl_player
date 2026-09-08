@testable import yl_player_apple
import AppKit
import AVFAudio
import Foundation
import VideoToolbox
import XCTest
import YlFFmpegBridge

final class YlMacosAudioTests: XCTestCase {
  private final class TestAudioConverter: YlAudioPacketConverting {
    func configure(stream: YlAudioStreamConfiguration) throws {}

    func estimateOutput(
      for packet: YlCompressedAudioPacket
    ) -> YlAudioBufferEstimate {
      YlAudioBufferEstimate(durationUs: 250_000, byteCount: 1_000)
    }

    func convert(
      packet: YlCompressedAudioPacket
    ) throws -> YlScheduledAudioBuffer? {
      YlScheduledAudioBuffer(
        payload: NSObject(),
        ptsUs: packet.ptsUs,
        durationUs: 250_000,
        byteCount: 1_000,
        generation: packet.generation
      )
    }
  }


  private final class TestAudioOutput: YlAudioOutputDriving {
    var volume: Float = 1
    var rate: Float = 1
    let renderedAudioTime: YlRenderedAudioTime? = nil
    private(set) var playCount = 0
    private(set) var isPlaying = false
    var onSchedule: (() -> Void)?
    private var completions: [() -> Void] = []

    func configure(sampleRate: Double, channelCount: Int) throws {}
    func schedule(_ buffer: YlScheduledAudioBuffer, completion: @escaping () -> Void) {
      completions.append(completion)
      onSchedule?()
    }
    func play() throws { playCount += 1; isPlaying = true }
    func pause() { isPlaying = false }
    func reset() {}
    func dispose() {}

    func completeNextBuffer() {
      guard !completions.isEmpty else { return }
      completions.removeFirst()()
    }
  }


  func testSystemAudioKeepsNeutralPitchAndRealtimeSmoothnessAcrossRateChanges() throws {
    let output = YlSystemAudioOutput()
    defer { output.dispose() }

    output.rate = 3

    let timePitch = try XCTUnwrap(
      Mirror(reflecting: output).children.first {
        $0.label == "timePitch"
      }?.value as? AVAudioUnitTimePitch
    )
    XCTAssertEqual(timePitch.rate, 3)
    XCTAssertEqual(timePitch.pitch, 0)
    XCTAssertEqual(timePitch.overlap, 8)

    output.rate = 1
    XCTAssertEqual(timePitch.rate, 1)
    XCTAssertEqual(timePitch.pitch, 0)
    XCTAssertEqual(timePitch.overlap, 8)
  }


  func testPauseDuringAudioSchedulingCancelsPendingAutomaticRestart() throws {
    let output = TestAudioOutput()
    let renderer = YlAudioRenderer(converter: TestAudioConverter(), output: output)
    try renderer.configure(stream: YlAudioStreamConfiguration(
      codec: .aac, sampleRate: 48_000, channelCount: 2,
      magicCookie: Data(), generation: 1
    ))
    try renderer.play()
    output.onSchedule = { renderer.pause() }

    XCTAssertEqual(try renderer.enqueue(packet: YlCompressedAudioPacket(
      data: Data([1]), ptsUs: 0, durationUs: 250_000, generation: 1
    )), .scheduled)

    XCTAssertFalse(output.isPlaying, "A completed pause must cancel the automatic restart.")
  }


  func testConcurrentPauseFinishesAfterAnInProgressAudioEnqueue() throws {
    let output = TestAudioOutput()
    let renderer = YlAudioRenderer(converter: TestAudioConverter(), output: output)
    try renderer.configure(stream: YlAudioStreamConfiguration(
      codec: .aac, sampleRate: 48_000, channelCount: 2,
      magicCookie: Data(), generation: 1
    ))
    try renderer.play()
    let entered = DispatchSemaphore(value: 0)
    let releaseSchedule = DispatchSemaphore(value: 0)
    let enqueued = DispatchSemaphore(value: 0)
    let paused = DispatchSemaphore(value: 0)
    output.onSchedule = {
      entered.signal()
      _ = releaseSchedule.wait(timeout: .now() + 2)
    }
    DispatchQueue.global().async {
      defer { enqueued.signal() }
      do {
        _ = try renderer.enqueue(packet: YlCompressedAudioPacket(
          data: Data([1]), ptsUs: 0, durationUs: 250_000, generation: 1
        ))
      } catch { XCTFail("Unexpected enqueue error: \(error)") }
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    DispatchQueue.global().async { renderer.pause(); paused.signal() }
    // A concurrent pause cannot be overtaken by the pending restart.
    XCTAssertEqual(paused.wait(timeout: .now() + 0.05), .timedOut)
    releaseSchedule.signal()
    XCTAssertEqual(enqueued.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(paused.wait(timeout: .now() + 1), .success)
    XCTAssertFalse(output.isPlaying)
  }


  func testAACPacketFromFallbackFixtureConvertsToPCM() throws {
    let exampleRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fixture = exampleRoot.appendingPathComponent(
      "assets/test_media/h264_aac.flv"
    )
    var context: YLFMediaContextRef?
    var mediaInfo = YLFMediaInfo()
    let openResult = fixture.withUnsafeFileSystemRepresentation { path in
      ylf_open_local(path, &context, &mediaInfo)
    }
    XCTAssertEqual(openResult, Int32(YLFResultOK))
    guard let context else {
      XCTFail("The FLV fixture did not open.")
      return
    }
    var ownedContext: YLFMediaContextRef? = context
    defer { ylf_close(&ownedContext) }

    var audioStream: YLFStreamInfo?
    for index in 0..<mediaInfo.stream_count {
      var stream = YLFStreamInfo()
      if ylf_copy_stream_info(context, index, &stream) == 0,
         Int(stream.kind) == YLFStreamAudio,
         Int(stream.codec) == YLFCodecAAC {
        audioStream = stream
        break
      }
    }
    guard let audioStream else {
      XCTFail("The FLV fixture has no AAC stream.")
      return
    }

    let cookieSize = ylf_stream_codec_config_size(context, audioStream.index)
    var cookie = [UInt8](repeating: 0, count: cookieSize)
    XCTAssertEqual(
      ylf_copy_stream_codec_config(
        context,
        audioStream.index,
        &cookie,
        cookie.count
      ),
      0
    )
    let converter = YlAppleCompressedAudioConverter()
    try converter.configure(stream: YlAudioStreamConfiguration(
      codec: .aac,
      sampleRate: Double(audioStream.sample_rate),
      channelCount: Int(audioStream.channel_count),
      magicCookie: Data(cookie),
      generation: 1
    ))

    for _ in 0..<256 {
      var packetRef: YLFPacketRef?
      let readResult = ylf_read_packet(context, &packetRef)
      guard readResult == Int32(YLFResultOK), let packet = packetRef else { break }
      let streamIndex = ylf_packet_stream_index(packet)
      guard streamIndex == audioStream.index,
            let bytes = ylf_packet_data(packet) else {
        ylf_packet_release(&packetRef)
        continue
      }
      let compressed = YlCompressedAudioPacket(
        data: Data(bytes: bytes, count: ylf_packet_size(packet)),
        ptsUs: ylf_packet_pts_us(packet),
        durationUs: ylf_packet_duration_us(packet),
        generation: 1
      )
      ylf_packet_release(&packetRef)

      if let decoded = try converter.convert(packet: compressed) {
        XCTAssertGreaterThan(decoded.durationUs, 0)
        XCTAssertGreaterThan(decoded.byteCount, 0)
        XCTAssertEqual(decoded.ptsUs, 62_000)
        return
      }
    }

    XCTFail("The FLV fixture produced no AAC packet.")
  }


  func testAACConverterDoesNotConsumeCompressedPacketsWithoutPCMOutput() throws {
    let exampleRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fixture = exampleRoot.appendingPathComponent(
      "assets/test_media/h264_aac.flv"
    )
    var context: YLFMediaContextRef?
    var mediaInfo = YLFMediaInfo()
    XCTAssertEqual(
      fixture.withUnsafeFileSystemRepresentation { path in
        ylf_open_local(path, &context, &mediaInfo)
      },
      Int32(YLFResultOK)
    )
    let openedContext = try XCTUnwrap(context)
    var ownedContext: YLFMediaContextRef? = openedContext
    defer { ylf_close(&ownedContext) }

    var audioStream: YLFStreamInfo?
    for index in 0..<mediaInfo.stream_count {
      var stream = YLFStreamInfo()
      if ylf_copy_stream_info(openedContext, index, &stream) == 0,
         Int(stream.kind) == YLFStreamAudio,
         Int(stream.codec) == YLFCodecAAC {
        audioStream = stream
        break
      }
    }
    let stream = try XCTUnwrap(audioStream)
    let cookieSize = ylf_stream_codec_config_size(openedContext, stream.index)
    var cookie = [UInt8](repeating: 0, count: cookieSize)
    XCTAssertEqual(
      ylf_copy_stream_codec_config(
        openedContext,
        stream.index,
        &cookie,
        cookie.count
      ),
      0
    )
    let converter = YlAppleCompressedAudioConverter()
    try converter.configure(stream: YlAudioStreamConfiguration(
      codec: .aac,
      sampleRate: Double(stream.sample_rate),
      channelCount: Int(stream.channel_count),
      magicCookie: Data(cookie),
      generation: 1
    ))

    var compressedPacketCount = 0
    var pcmBufferCount = 0
    while compressedPacketCount < 120 {
      var packetRef: YLFPacketRef?
      guard ylf_read_packet(openedContext, &packetRef) == Int32(YLFResultOK),
            let packet = packetRef else { break }
      guard ylf_packet_stream_index(packet) == stream.index,
            let bytes = ylf_packet_data(packet) else {
        ylf_packet_release(&packetRef)
        continue
      }
      let compressed = YlCompressedAudioPacket(
        data: Data(bytes: bytes, count: ylf_packet_size(packet)),
        ptsUs: ylf_packet_pts_us(packet),
        durationUs: ylf_packet_duration_us(packet),
        generation: 1
      )
      ylf_packet_release(&packetRef)
      compressedPacketCount += 1
      if try converter.convert(packet: compressed) != nil {
        pcmBufferCount += 1
      }
    }

    XCTAssertGreaterThan(compressedPacketCount, 50)
    XCTAssertGreaterThanOrEqual(
      pcmBufferCount,
      compressedPacketCount - 1,
      "compressed=\(compressedPacketCount), pcm=\(pcmBufferCount)"
    )
  }


  func testMacOSAudioUsesNonInterleavedPCMAndCountsEveryChannel() {
    XCTAssertFalse(YlAudioFormatPolicy.usesInterleavedPCM)
    XCTAssertEqual(
      YlAudioFormatPolicy.byteCount(
        frameCount: 100,
        bytesPerFrame: 4,
        channelCount: 2
      ),
      800
    )
  }


  func testAudioRendererPreservesWallClockBufferAtThreeTimesSpeed() throws {
    let renderer = YlAudioRenderer(
      maxScheduledDurationUs: 500_000,
      maxScheduledBytes: 10_000,
      converter: TestAudioConverter(),
      output: TestAudioOutput()
    )
    try renderer.configure(stream: YlAudioStreamConfiguration(
      codec: .aac,
      sampleRate: 48_000,
      channelCount: 2,
      magicCookie: Data([0x12, 0x10]),
      generation: 1
    ))
    renderer.setRate(3)
    let packet = YlCompressedAudioPacket(
      data: Data([1]),
      ptsUs: 0,
      durationUs: 250_000,
      generation: 1
    )

    for _ in 0..<6 {
      XCTAssertEqual(try renderer.enqueue(packet: packet), .scheduled)
    }
    XCTAssertEqual(renderer.scheduledDurationUs, 1_500_000)
    XCTAssertEqual(
      try renderer.enqueue(packet: packet),
      .wouldExceedDuration
    )
  }


  func testFallbackAudioBufferKeepsOneSecondOfHeadroomAtThreeTimesSpeed() throws {
    let renderer = YlAudioRenderer(
      bufferBudget: YlFallbackBufferBudget(
        networkBytes: 1_000,
        scheduledAudioBytes: 100_000,
        inFlightPacketBytes: 1_000
      ),
      converter: TestAudioConverter(),
      output: TestAudioOutput()
    )
    try renderer.configure(stream: YlAudioStreamConfiguration(
      codec: .aac,
      sampleRate: 48_000,
      channelCount: 2,
      magicCookie: Data([0x12, 0x10]),
      generation: 1
    ))
    renderer.setRate(3)
    let packet = YlCompressedAudioPacket(
      data: Data([1]),
      ptsUs: 0,
      durationUs: 250_000,
      generation: 1
    )

    for _ in 0..<12 {
      XCTAssertEqual(try renderer.enqueue(packet: packet), .scheduled)
    }
    XCTAssertEqual(renderer.scheduledDurationUs, 3_000_000)
    XCTAssertEqual(
      try renderer.enqueue(packet: packet),
      .wouldExceedDuration
    )
  }


  func testAudioRendererRestartsOutputAfterTheRunningQueueDrains() throws {
    let output = TestAudioOutput()
    let renderer = YlAudioRenderer(
      maxScheduledDurationUs: 500_000,
      maxScheduledBytes: 10_000,
      converter: TestAudioConverter(),
      output: output
    )
    try renderer.configure(stream: YlAudioStreamConfiguration(
      codec: .aac,
      sampleRate: 48_000,
      channelCount: 2,
      magicCookie: Data([0x12, 0x10]),
      generation: 1
    ))
    let packet = YlCompressedAudioPacket(
      data: Data([1]),
      ptsUs: 0,
      durationUs: 250_000,
      generation: 1
    )

    XCTAssertEqual(try renderer.enqueue(packet: packet), .scheduled)
    try renderer.play()
    XCTAssertEqual(output.playCount, 1)

    output.completeNextBuffer()
    XCTAssertEqual(renderer.underrunCount, 1)
    XCTAssertEqual(try renderer.enqueue(packet: packet), .scheduled)
    XCTAssertEqual(output.playCount, 2)
  }


  func testAudioCatalogExposesAACAndMP3Selection() {
    var aac = YLFStreamInfo()
    aac.index = 3
    aac.kind = Int32(YLFStreamAudio)
    aac.codec = Int32(YLFCodecAAC)
    var mp3 = YLFStreamInfo()
    mp3.index = 4
    mp3.kind = Int32(YLFStreamAudio)
    mp3.codec = Int32(YLFCodecMP3)

    let tracks = YlFallbackTrackCatalog.audioTracks(
      streams: [aac, mp3],
      selectedIndex: mp3.index,
      codecName: { Int($0.codec) == YLFCodecMP3 ? "MP3" : "AAC" }
    )

    XCTAssertEqual(tracks[0]["codec"] as? String, "AAC")
    XCTAssertEqual(tracks[1]["codec"] as? String, "MP3")
    XCTAssertEqual(tracks[1]["isSelected"] as? Bool, true)
  }

}
