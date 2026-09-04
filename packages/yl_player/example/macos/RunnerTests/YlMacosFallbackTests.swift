@testable import yl_player_macos
import Foundation
import XCTest
import YlFFmpegBridge

final class YlMacosFallbackTests: XCTestCase {
  func testTerminalFailureTransitionIsOneShotAndInvalidatesWork() {
    let first = YlFallbackTerminalFailurePolicy.begin(
      disposed: false,
      active: true,
      hasError: false,
      videoGeneration: 7,
      audioGeneration: 11
    )

    XCTAssertEqual(first?.videoGeneration, 8)
    XCTAssertEqual(first?.audioGeneration, 12)
    XCTAssertNil(YlFallbackTerminalFailurePolicy.begin(
      disposed: false,
      active: false,
      hasError: true,
      videoGeneration: 8,
      audioGeneration: 12
    ))
  }

  func testActivationPolicyRejectsTerminalAndDisposedBackends() throws {
    XCTAssertFalse(try YlFallbackActivationPolicy.shouldActivate(
      disposed: false,
      active: true,
      hasTerminalError: false
    ))
    XCTAssertThrowsError(try YlFallbackActivationPolicy.shouldActivate(
      disposed: false,
      active: false,
      hasTerminalError: true
    )) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "resource.player_failed")
    }
    XCTAssertThrowsError(try YlFallbackActivationPolicy.shouldActivate(
      disposed: true,
      active: false,
      hasTerminalError: false
    )) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "macos.player_disposed")
    }
  }

  func testVideoDecodeBudgetReservationsBoundBytesAndFrameCount() throws {
    let budget = YlVideoDecodeBudget(maxBytes: 100, maxFrames: 2)

    var first = try XCTUnwrap(budget.reserve(byteCount: 60, timeout: 0))
    XCTAssertThrowsError(try budget.reserve(byteCount: 50, timeout: 0)) {
      XCTAssertEqual(
        ($0 as? NativePlayerError)?.code,
        "resource.video_decoder_backpressure_timeout"
      )
    }
    let second = try XCTUnwrap(budget.reserve(byteCount: 40, timeout: 0))
    XCTAssertThrowsError(try budget.reserve(byteCount: 1, timeout: 0))

    first.release()
    first = try XCTUnwrap(budget.reserve(byteCount: 50, timeout: 0))
    budget.reset()
    XCTAssertEqual(budget.inFlightBytes, 0)
    XCTAssertEqual(budget.inFlightFrames, 0)
    let replacement = try XCTUnwrap(budget.reserve(byteCount: 100, timeout: 0))
    first.release()
    second.release()
    XCTAssertEqual(budget.inFlightBytes, 100)
    XCTAssertEqual(budget.inFlightFrames, 1)
    replacement.release()
  }

  func testLiveReactivationPreservesPlaybackIntentAndResetsPosition() {
    XCTAssertEqual(
      YlFallbackReactivationPolicy.resolve(
        isSeekable: false,
        savedPositionUs: 8_000_000,
        selectedAudioStreamIndex: 3,
        shouldPlay: true
      ),
      YlFallbackResumeState(
        positionUs: 0,
        selectedAudioStreamIndex: 3,
        shouldPlay: true
      )
    )
  }

  func testRestorationCancellationIsNotReportedAsTerminalFailure() {
    let cancelled = YlOpenCancellationToken.cancellationError()
    XCTAssertFalse(YlFallbackRestorationPolicy.shouldReport(
      error: cancelled,
      isCurrentBackend: true
    ))
    XCTAssertFalse(YlFallbackRestorationPolicy.shouldReport(
      error: NativePlayerError(
        category: "network",
        code: "network.http_status",
        message: "failed"
      ),
      isCurrentBackend: false
    ))
    XCTAssertTrue(YlFallbackRestorationPolicy.shouldReport(
      error: NativePlayerError(
        category: "network",
        code: "network.http_status",
        message: "failed"
      ),
      isCurrentBackend: true
    ))
  }

  func testOnlyStateReplacingCommandsCancelRestoration() {
    for name in ["play", "pause"] {
      XCTAssertTrue(YlRestorationCommandPolicy.supersedesRestoration(name))
    }
    for name in [
      "seekTo", "seekToLiveEdge", "selectAudioTrack",
      "setVolume", "setPlaybackSpeed", "setQualityConstraint",
    ] {
      XCTAssertFalse(YlRestorationCommandPolicy.supersedesRestoration(name))
    }
    for name in ["seekTo", "seekToLiveEdge", "selectAudioTrack"] {
      XCTAssertTrue(YlRestorationCommandPolicy.defersUntilRestored(name))
    }
  }

  func testVideoDecodeBudgetWaiterUnblocksWhenReservationReleases() throws {
    let budget = YlVideoDecodeBudget(maxBytes: 100, maxFrames: 1)
    let first = try XCTUnwrap(budget.reserve(byteCount: 100, timeout: 0))
    let started = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    let resultLock = NSLock()
    var didReserve = false

    DispatchQueue.global().async {
      started.signal()
      let second = try? budget.reserve(byteCount: 1, timeout: 1)
      resultLock.withLock { didReserve = second != nil }
      second?.release()
      completed.signal()
    }

    XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(completed.wait(timeout: .now() + 0.05), .timedOut)
    first.release()
    XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
    XCTAssertTrue(resultLock.withLock { didReserve })
    XCTAssertNil(try budget.reserve(
      byteCount: 1,
      timeout: 1,
      shouldCancel: { true }
    ))
  }

  func testHardwareDecoderLeaseEnforcesAdvertisedConcurrency() throws {
    let pool = YlHardwareDecoderLeasePool(maxConcurrentLeases: 1)
    var first: YlHardwareDecoderLease? = try pool.acquire()
    XCTAssertNotNil(first)

    XCTAssertThrowsError(try pool.acquire()) {
      XCTAssertEqual(
        ($0 as? NativePlayerError)?.code,
        "resource.video_decoder_limit"
      )
    }
    first = nil
    XCTAssertNoThrow(try pool.acquire())
  }

  func testMediaClockQueriesExternalAudioTimeWithoutHoldingItsLock() {
    let completed = expectation(description: "media clock play completed")
    var clock: YlMediaClock!
    clock = YlMediaClock(audioTime: {
      clock.anchorAudio(ptsUs: 0, sampleTime: 0)
      return YlRenderedAudioTime(sampleTime: 0, sampleRate: 48_000)
    })

    DispatchQueue.global().async {
      clock.play(atHostTimeUs: 0)
      completed.fulfill()
    }

    wait(for: [completed], timeout: 1)
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

  func testBufferBudgetsStayWithinDocumentedCeilings() throws {
    let lowLatency = try YlFallbackBufferBudget.make(
      configuration: PlayerConfiguration(map: ["bufferMode": "lowLatency"])
    )
    XCTAssertEqual(lowLatency.networkBytes, 4 * 1024 * 1024)
    XCTAssertEqual(lowLatency.scheduledAudioBytes, 1 * 1024 * 1024)
    XCTAssertEqual(lowLatency.inFlightPacketBytes, 2 * 1024 * 1024)
  }

  func testQualityConstraintRejectsOversizedFixedVideo() throws {
    let constraint = try YlFallbackQualityConstraint(validating: [
      "maxWidth": 1_920,
      "maxHeight": 1_080,
      "maxBitrate": 8_000_000,
    ])

    XCTAssertThrowsError(try YlFallbackQualityPolicy.validate(
      constraint: constraint,
      stream: YlFallbackVideoDescriptor(
        width: 3_840,
        height: 2_160,
        bitrate: 12_000_000
      )
    )) {
      XCTAssertEqual(
        ($0 as? NativePlayerError)?.code,
        "decoder.quality_constraint_unsupported"
      )
    }
  }

  func testFrameSchedulerDropsLateFramesAndRejectsOldGeneration() {
    let scheduler = YlFrameScheduler()
    scheduler.enqueue(YlFrameEnvelope(
      payload: NSObject(),
      ptsUs: 10_000,
      durationUs: 40_000,
      keyframe: false,
      generation: 1
    ))
    scheduler.enqueue(YlFrameEnvelope(
      payload: NSObject(),
      ptsUs: 20_000,
      durationUs: 40_000,
      keyframe: false,
      generation: 1
    ))

    XCTAssertEqual(scheduler.frame(at: 25_000, generation: 1)?.ptsUs, 20_000)
    XCTAssertEqual(scheduler.lateFrameDropCount, 1)
    scheduler.flush(generation: 2)
    XCTAssertNil(scheduler.frame(at: 30_000, generation: 1))
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

  func testFallbackStateDeltaRetainsGenerationEnvelope() {
    let envelope = YlMacosChannel.stateDelta(
      playerId: 9,
      generation: 42,
      delta: ["positionMs": Int64(250)]
    )

    XCTAssertEqual(envelope["protocolVersion"] as? Int, 1)
    XCTAssertEqual(envelope["generation"] as? UInt64, 42)
    XCTAssertEqual(envelope["type"] as? String, "stateDelta")
  }
}
