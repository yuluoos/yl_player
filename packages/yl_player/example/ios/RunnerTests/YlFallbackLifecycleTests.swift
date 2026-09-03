@testable import yl_player_ios
import CoreMedia
import XCTest
import YlFFmpegBridge

final class YlFallbackLifecycleTests: XCTestCase {
  private struct ExpectedFailure: Error {}

  func testSeekRunsTheOrderedPipelineTransaction() throws {
    var events: [String] = []
    var generation = UInt64(7)
    let transaction = YlFallbackLifecycleTransaction(
      pauseClock: { events.append("pauseClock") },
      advanceGeneration: {
        generation += 1
        events.append("generation:\(generation)")
        return generation
      },
      stopDemux: { events.append("stopDemux") },
      clearBuffers: { events.append("clearBuffers:\($0)") },
      seekDemux: { events.append("seek:\($0)") },
      resetAudio: { events.append("resetAudio:\($0)") },
      recreateVideo: { events.append("recreateVideo:\($0)") },
      suppressFramesBefore: { events.append("suppressBefore:\($0)") },
      restartDemux: { events.append("restartDemux") }
    )

    try transaction.seek(toUs: 1_250_000)

    XCTAssertEqual(events, [
      "pauseClock",
      "generation:8",
      "stopDemux",
      "clearBuffers:8",
      "seek:1250000",
      "resetAudio:8",
      "recreateVideo:8",
      "suppressBefore:1250000",
      "restartDemux",
    ])
  }

  func testFailedSeekDoesNotRestartDemux() {
    var events: [String] = []
    let transaction = YlFallbackLifecycleTransaction(
      pauseClock: { events.append("pauseClock") },
      advanceGeneration: { events.append("generation"); return 2 },
      stopDemux: { events.append("stopDemux") },
      clearBuffers: { _ in events.append("clearBuffers") },
      seekDemux: { _ in events.append("seek"); throw ExpectedFailure() },
      resetAudio: { _ in events.append("resetAudio") },
      recreateVideo: { _ in events.append("recreateVideo") },
      suppressFramesBefore: { _ in events.append("suppressBefore") },
      restartDemux: { events.append("restartDemux") }
    )

    XCTAssertThrowsError(try transaction.seek(toUs: 500_000))
    XCTAssertEqual(events, [
      "pauseClock", "generation", "stopDemux", "clearBuffers", "seek",
    ])
  }

  func testPostSeekVideoAndAudioGatesAdvanceIndependently() {
    let gate = YlPostSeekGate()
    gate.reset(targetUs: 1_000)

    XCTAssertTrue(gate.acceptsVideo(ptsUs: 1_100))
    XCTAssertFalse(gate.acceptsAudio(ptsUs: 900))
    XCTAssertTrue(gate.acceptsAudio(ptsUs: 1_000))
    XCTAssertTrue(gate.acceptsVideo(ptsUs: 500))
    XCTAssertTrue(gate.acceptsAudio(ptsUs: 500))
  }

  func testHEVCFixtureBuildsFormatAndRequiresHardware() throws {
    let fixture = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "hevc_aac", withExtension: "mkv")
    )
    var context: YLFMediaContextRef?
    defer {
      ylf_close(&context)
      XCTAssertEqual(ylf_debug_outstanding_packet_count(), 0)
    }
    var mediaInfo = YLFMediaInfo()
    XCTAssertEqual(ylf_open_local(fixture.path, &context, &mediaInfo), Int32(YLFResultOK))

    var video: YLFStreamInfo?
    for index in 0..<mediaInfo.stream_count {
      var stream = YLFStreamInfo()
      XCTAssertEqual(
        ylf_copy_stream_info(context, index, &stream),
        Int32(YLFResultOK)
      )
      if Int(stream.kind) == YLFStreamVideo { video = stream }
    }
    let stream = try XCTUnwrap(video)
    XCTAssertEqual(Int(stream.codec), YLFCodecHEVC)
    let format = try YlVideoToolboxDecoder.makeFormatDescription(
      context: context,
      streamIndex: stream.index
    )
    XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC)

    var decodedFrameHandler: ((YlVideoFrame) -> Void)?
    let decoder: YlVideoToolboxDecoder
    do {
      decoder = try YlVideoToolboxDecoder(
        formatDescription: format,
        onFrame: { frame in decodedFrameHandler?(frame) },
        onError: { error in XCTFail("Unexpected HEVC decoder error: \(error)") }
      )
    } catch {
      XCTAssertEqual(
        (error as? NativePlayerError)?.code,
        "decoder.video_hardware_unavailable"
      )
      return
    }

    let frameExpectation = expectation(description: "first decoded HEVC frame")
    frameExpectation.assertForOverFulfill = false
    decodedFrameHandler = { _ in frameExpectation.fulfill() }
    for _ in 0..<120 {
      var packet: YLFPacketRef?
      let result = ylf_read_packet(context, &packet)
      if result == Int32(YLFResultEOF) { break }
      XCTAssertEqual(result, Int32(YLFResultOK))
      guard let ownedPacket = packet else { continue }
      guard ylf_packet_stream_index(ownedPacket) == stream.index else {
        ylf_packet_release(&packet)
        continue
      }
      var sample: Unmanaged<CMSampleBuffer>?
      XCTAssertEqual(
        ylf_create_video_sample_buffer(&packet, format, &sample),
        Int32(YLFResultOK)
      )
      decoder.decode(
        sample: try XCTUnwrap(sample).takeRetainedValue(),
        generation: 1
      )
    }
    decoder.flush()
    wait(for: [frameExpectation], timeout: 2)
    decoder.dispose()
  }

  func testPreparedFallbackRetainsEveryAACTrackForSwitching() throws {
    let fixture = try XCTUnwrap(
      Bundle(for: Self.self).url(
        forResource: "two_audio_tracks",
        withExtension: "mkv"
      )
    )
    let prepared = try YlPreparedFallback(
      source: [
        "uri": fixture.absoluteString,
        "kind": "file",
        "formatHint": "matroska",
        "isLive": false,
      ],
      requireHardwareProbe: false
    )

    XCTAssertEqual(prepared.audioStreams.count, 2)
    XCTAssertEqual(
      Set(prepared.audioStreams.map(\.index)),
      Set(prepared.audioCookies.keys)
    )
    XCTAssertTrue(prepared.audioCookies.values.allSatisfy { !$0.isEmpty })
  }
}
