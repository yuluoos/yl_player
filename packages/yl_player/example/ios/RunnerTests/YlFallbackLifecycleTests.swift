@testable import yl_player_ios
import CoreMedia
import XCTest
import YlFFmpegBridge

final class YlFallbackLifecycleTests: XCTestCase {
  private struct ExpectedFailure: Error {}

  func testTeardownCancelsInputBeforeJoiningWorker() {
    var events = [String]()
    let transaction = YlFallbackTeardownTransaction(
      cancelInput: { events.append("cancelInput") },
      joinAndRelease: { events.append("joinAndRelease") }
    )

    transaction.run()

    XCTAssertEqual(events, ["cancelInput", "joinAndRelease"])
  }

  func testDisposedLiveReconnectCannotRunPendingRetry() {
    let controller = YlLiveReconnectController(configuration: .init(map: [
      "maxRetries": 2,
      "baseRetryDelayMs": 50,
    ]))
    XCTAssertEqual(controller.nextDelayMs(), 50)

    controller.cancel()

    XCTAssertNil(controller.nextDelayMs())
    XCTAssertFalse(controller.shouldInstall(
      reconnectGeneration: 8,
      currentGeneration: 8
    ))
  }

  func testLiveReconnectCannotInstallAfterLifecycleGenerationAdvances() {
    let controller = YlLiveReconnectController(configuration: .init(map: [:]))

    XCTAssertFalse(controller.shouldInstall(
      reconnectGeneration: 12,
      currentGeneration: 13
    ))
  }

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

  func testInitialKeyframeGateDropsEverythingUntilVideoKeyframeAndRearms() {
    var gate = YlInitialKeyframeGate()

    XCTAssertFalse(gate.accepts(isVideo: false, isKeyframe: false))
    XCTAssertFalse(gate.accepts(isVideo: true, isKeyframe: false))
    XCTAssertTrue(gate.accepts(isVideo: true, isKeyframe: true))
    XCTAssertTrue(gate.accepts(isVideo: false, isKeyframe: false))
    XCTAssertTrue(gate.accepts(isVideo: true, isKeyframe: false))

    gate.reset()
    XCTAssertFalse(gate.accepts(isVideo: false, isKeyframe: false))
    XCTAssertFalse(gate.accepts(isVideo: true, isKeyframe: false))
    XCTAssertTrue(gate.accepts(isVideo: true, isKeyframe: true))
  }

  func testSequentialSeekIsRejectedBeforeLifecycleMutation() {
    var mutationCount = 0
    let policy = YlFallbackSeekPolicy(
      isSeekable: false,
      perform: { _ in mutationCount += 1 }
    )

    XCTAssertThrowsError(try policy.seek(toUs: 900_000)) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "network.range_not_supported")
    }
    XCTAssertEqual(mutationCount, 0)
  }

  func testActiveNetworkBlockingCommandsRunOffMain() {
    XCTAssertTrue(YlFallbackCommandPolicy.requiresBackgroundExecution(
      isNetwork: true,
      isActive: true,
      name: "seekTo"
    ))
    XCTAssertTrue(YlFallbackCommandPolicy.requiresBackgroundExecution(
      isNetwork: true,
      isActive: true,
      name: "selectAudioTrack"
    ))
    XCTAssertFalse(YlFallbackCommandPolicy.requiresBackgroundExecution(
      isNetwork: false,
      isActive: true,
      name: "seekTo"
    ))
    XCTAssertFalse(YlFallbackCommandPolicy.requiresBackgroundExecution(
      isNetwork: true,
      isActive: false,
      name: "seekTo"
    ))
  }

  func testRetryEnvelopeContainsNoSourceOrHeaders() {
    let envelope = YlFallbackRetryEvent.envelope(
      playerId: 9,
      attempt: 2,
      delayMs: 400,
      error: NativePlayerError(
        category: "network",
        code: "network.read_timeout",
        message: "Read timed out",
        diagnostic: "NSURLErrorDomain -1001"
      )
    )

    XCTAssertEqual(envelope["playerId"] as? Int64, 9)
    XCTAssertEqual(envelope["type"] as? String, "retry")
    XCTAssertEqual(envelope["attempt"] as? Int, 2)
    XCTAssertEqual(envelope["delayMs"] as? Int64, 400)
    XCTAssertNil(envelope["uri"] ?? nil)
    XCTAssertNil(envelope["headers"] ?? nil)
    let error = envelope["error"] as? [String: Any?]
    XCTAssertEqual(error?["code"] as? String, "network.read_timeout")
  }

  func testRangeReactivationPreservesPositionTrackAndPlaybackIntent() {
    let state = YlFallbackReactivationPolicy.resolve(
      isSeekable: true,
      savedPositionUs: 1_250_000,
      selectedAudioStreamIndex: 3,
      shouldPlay: true
    )

    XCTAssertEqual(state.positionUs, 1_250_000)
    XCTAssertEqual(state.selectedAudioStreamIndex, 3)
    XCTAssertTrue(state.shouldPlay)
  }

  func testSequentialReactivationRestartsAtZeroPaused() {
    let state = YlFallbackReactivationPolicy.resolve(
      isSeekable: false,
      savedPositionUs: 1_250_000,
      selectedAudioStreamIndex: 3,
      shouldPlay: true
    )

    XCTAssertEqual(state.positionUs, 0)
    XCTAssertEqual(state.selectedAudioStreamIndex, 3)
    XCTAssertFalse(state.shouldPlay)
  }

  func testReplacementQuiesceKeepsAudioPacketsCompatibleWithRetainedRenderer() {
    let configuredAudioGeneration = UInt64(11)

    let transition = YlFallbackReplacementGenerationPolicy.quiesce(
      videoGeneration: 11,
      audioGeneration: configuredAudioGeneration
    )

    XCTAssertEqual(transition.videoGeneration, 12)
    XCTAssertEqual(transition.audioGeneration, configuredAudioGeneration)
    XCTAssertEqual(
      transition.audioGeneration,
      configuredAudioGeneration,
      "The next demuxed packet must match the retained renderer generation after rollback."
    )
  }

  func testPreparedReactivationPositionsSeekableMediaBeforeCommit() throws {
    let fixture = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mkv")
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
    let requested = YlFallbackResumeState(
      positionUs: 900_000,
      selectedAudioStreamIndex: prepared.audioStreams.first?.index,
      shouldPlay: true
    )

    try prepared.prepareForReactivation(requested)

    XCTAssertEqual(prepared.resumeState?.positionUs, 900_000)
    XCTAssertTrue(prepared.resumeState?.shouldPlay == true)
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
