@testable import yl_player_macos
import AppKit
import AVFAudio
import Foundation
import VideoToolbox
import XCTest
import YlFFmpegBridge

final class YlMacosFallbackTests: XCTestCase {
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
    private var completions: [() -> Void] = []

    func configure(sampleRate: Double, channelCount: Int) throws {}
    func schedule(_ buffer: YlScheduledAudioBuffer, completion: @escaping () -> Void) {
      completions.append(completion)
    }
    func play() throws { playCount += 1 }
    func pause() {}
    func reset() {}
    func dispose() {}

    func completeNextBuffer() {
      guard !completions.isEmpty else { return }
      completions.removeFirst()()
    }
  }

  func testDisplayTimerFollowsTheActiveScreenRefreshRate() throws {
    guard let screen = NSScreen.main, screen.maximumFramesPerSecond > 30 else {
      throw XCTSkip("An active display faster than 30 Hz is required.")
    }
    let probe = YlDisplayTickProbe()
    let timer = YlDisplayTimer { probe.tick() }
    defer { timer.invalidate() }

    timer.isPaused = false
    let sampleDuration = 0.5
    RunLoop.main.run(until: Date(timeIntervalSinceNow: sampleDuration))

    let minimumTicks = Int(
      Double(screen.maximumFramesPerSecond) * sampleDuration * 0.75
    )
    XCTAssertGreaterThanOrEqual(probe.tickCount, minimumTicks)
  }

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

  func testVideoToolboxRequestsDisplayOrderForAsynchronousFrames() {
    XCTAssertTrue(
      YlVideoToolboxDecodePolicy.frameFlags.contains(._EnableTemporalProcessing)
    )
  }

  func testVideoToolboxDoesNotRestrictDecodeThroughputToOneTimesRealtime() {
    XCTAssertFalse(
      YlVideoToolboxDecodePolicy.frameFlags.contains(._1xRealTimePlayback)
    )
  }

  func testVideoToolboxOutputsFlutterNativeBiPlanarPixelBuffers() throws {
    let exampleRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fixture = exampleRoot.appendingPathComponent(
      "assets/test_media/h264_aac.mkv"
    )
    var context: YLFMediaContextRef?
    var mediaInfo = YLFMediaInfo()
    let openResult = fixture.withUnsafeFileSystemRepresentation { path in
      ylf_open_local(path, &context, &mediaInfo)
    }
    XCTAssertEqual(openResult, Int32(YLFResultOK))
    guard let context else {
      XCTFail("The Matroska fixture did not open.")
      return
    }
    var ownedContext: YLFMediaContextRef? = context
    defer { ylf_close(&ownedContext) }

    var videoStreamIndex: Int32?
    for index in 0..<mediaInfo.stream_count {
      var stream = YLFStreamInfo()
      if ylf_copy_stream_info(context, index, &stream) == 0,
         Int(stream.kind) == YLFStreamVideo {
        videoStreamIndex = stream.index
        break
      }
    }
    let streamIndex = try XCTUnwrap(videoStreamIndex)
    let format = try YlVideoToolboxDecoder.makeFormatDescription(
      context: context,
      streamIndex: streamIndex
    )
    let frameExpectation = expectation(
      description: "VideoToolbox outputs a Flutter-compatible YUV frame"
    )
    frameExpectation.assertForOverFulfill = false
    let outputLock = NSLock()
    var outputPixelFormat: OSType?
    let decoder: YlVideoToolboxDecoder
    do {
      decoder = try YlVideoToolboxDecoder(
        formatDescription: format,
        onFrame: { frame in
          outputLock.withLock {
            outputPixelFormat = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
          }
          frameExpectation.fulfill()
        },
        onError: { error in
          XCTFail("Unexpected decoder error: \(error)")
        }
      )
    } catch let error as NativePlayerError
      where error.code == "decoder.video_hardware_unavailable" {
      throw XCTSkip("VideoToolbox hardware decoding is unavailable on this host.")
    }
    defer { decoder.dispose() }

    for _ in 0..<120 {
      var packet: YLFPacketRef?
      let readResult = ylf_read_packet(context, &packet)
      if readResult == Int32(YLFResultEOF) { break }
      XCTAssertEqual(readResult, Int32(YLFResultOK))
      guard let ownedPacket = packet else { continue }
      guard ylf_packet_stream_index(ownedPacket) == streamIndex else {
        ylf_packet_release(&packet)
        continue
      }
      let reservation = try XCTUnwrap(decoder.reserve(
        byteCount: ylf_packet_size(ownedPacket),
        shouldCancel: { false }
      ))
      var unmanagedSample: Unmanaged<CMSampleBuffer>?
      let sampleResult = ylf_create_video_sample_buffer(
        &packet,
        format,
        &unmanagedSample
      )
      guard sampleResult == Int32(YLFResultOK), let unmanagedSample else {
        reservation.release()
        ylf_packet_release(&packet)
        XCTFail("The fixture packet could not become a video sample.")
        break
      }
      decoder.decode(
        sample: unmanagedSample.takeRetainedValue(),
        generation: 1,
        reservation: reservation
      )
    }
    decoder.drain()
    wait(for: [frameExpectation], timeout: 2)

    XCTAssertEqual(
      outputLock.withLock { outputPixelFormat },
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    )
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

  func testMediaClockDoesNotReuseStaleAudioAnchorAcrossRateChanges() {
    var rendered: YlRenderedAudioTime? = YlRenderedAudioTime(
      sampleTime: 48_000,
      sampleRate: 48_000
    )
    let clock = YlMediaClock(audioTime: { rendered })
    clock.anchorAudio(ptsUs: 5_000_000, sampleTime: 48_000)
    clock.play(atHostTimeUs: 0)

    rendered = YlRenderedAudioTime(sampleTime: 96_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 1_000_000), 6_000_000)

    rendered = nil
    clock.setRate(2, atHostTimeUs: 1_000_000)
    rendered = YlRenderedAudioTime(sampleTime: 144_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 1_500_000), 7_000_000)

    rendered = YlRenderedAudioTime(sampleTime: 192_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 2_000_000), 8_000_000)

    rendered = nil
    clock.setRate(1, atHostTimeUs: 2_000_000)
    rendered = YlRenderedAudioTime(sampleTime: 216_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 2_500_000), 8_500_000)
  }

  func testMediaClockDoesNotScaleTheTimePitchPlayerTimelineTwice() {
    var rendered = YlRenderedAudioTime(sampleTime: 0, sampleRate: 48_000)
    let clock = YlMediaClock(audioTime: { rendered })
    clock.anchorAudio(ptsUs: 0, sampleTime: 0)
    clock.play(atHostTimeUs: 0)

    clock.setRate(3, atHostTimeUs: 0)
    rendered = YlRenderedAudioTime(sampleTime: 144_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 1_000_000), 3_000_000)

    clock.setRate(1, atHostTimeUs: 1_000_000)
    rendered = YlRenderedAudioTime(sampleTime: 192_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 2_000_000), 4_000_000)
  }

  func testMediaClockDoesNotReuseStaleAudioAnchorAcrossPauseAndResume() {
    var rendered: YlRenderedAudioTime? = YlRenderedAudioTime(
      sampleTime: 48_000,
      sampleRate: 48_000
    )
    let clock = YlMediaClock(audioTime: { rendered })
    clock.anchorAudio(ptsUs: 5_000_000, sampleTime: 48_000)
    clock.play(atHostTimeUs: 0)

    rendered = YlRenderedAudioTime(sampleTime: 96_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 1_000_000), 6_000_000)

    rendered = nil
    clock.pause(atHostTimeUs: 1_000_000)
    clock.play(atHostTimeUs: 2_000_000)
    rendered = YlRenderedAudioTime(sampleTime: 120_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 2_500_000), 6_500_000)
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

  func testFrameSchedulerPresentsOverdueFramesInOrderAndRejectsOldGeneration() {
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

    XCTAssertEqual(scheduler.frame(at: 15_000, generation: 1)?.ptsUs, 10_000)
    XCTAssertEqual(scheduler.frame(at: 25_000, generation: 1)?.ptsUs, 20_000)
    XCTAssertEqual(scheduler.lateFrameDropCount, 0)
    scheduler.flush(generation: 2)
    XCTAssertNil(scheduler.frame(at: 30_000, generation: 1))
  }

  func testFrameSchedulerPresentsTheNewestFrameDueOnEachDisplayTick() {
    let scheduler = YlFrameScheduler()
    for ptsUs in [10_000, 20_000, 30_000] {
      XCTAssertTrue(scheduler.enqueue(YlFrameEnvelope(
        payload: NSObject(),
        ptsUs: Int64(ptsUs),
        durationUs: 10_000,
        keyframe: false,
        generation: 1
      )))
    }

    XCTAssertEqual(scheduler.frame(at: 35_000, generation: 1)?.ptsUs, 30_000)
    XCTAssertEqual(scheduler.pendingPTS, [])
    XCTAssertEqual(scheduler.lateFrameDropCount, 2)
  }

  func testFrameSchedulerRejectsAFrameOlderThanTheLastPresentedPTS() {
    let scheduler = YlFrameScheduler()
    XCTAssertTrue(scheduler.enqueue(YlFrameEnvelope(
      payload: NSObject(),
      ptsUs: 20_000,
      durationUs: 10_000,
      keyframe: false,
      generation: 1
    )))
    XCTAssertEqual(scheduler.frame(at: 20_000, generation: 1)?.ptsUs, 20_000)

    XCTAssertFalse(scheduler.enqueue(YlFrameEnvelope(
      payload: NSObject(),
      ptsUs: 10_000,
      durationUs: 10_000,
      keyframe: false,
      generation: 1
    )))
    XCTAssertNil(scheduler.frame(at: 30_000, generation: 1))
    XCTAssertEqual(scheduler.lateFrameDropCount, 1)
  }

  func testFrameSchedulerBackpressuresUntilPresentationFreesCapacity() {
    let scheduler = YlFrameScheduler()
    for ptsUs in [10_000, 20_000, 30_000] {
      XCTAssertTrue(scheduler.enqueue(YlFrameEnvelope(
        payload: NSObject(),
        ptsUs: Int64(ptsUs),
        durationUs: 10_000,
        keyframe: false,
        generation: 1
      )))
    }
    let started = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      started.signal()
      _ = scheduler.enqueue(YlFrameEnvelope(
        payload: NSObject(),
        ptsUs: 40_000,
        durationUs: 10_000,
        keyframe: false,
        generation: 1
      ))
      completed.signal()
    }

    XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(completed.wait(timeout: .now() + 0.05), .timedOut)
    XCTAssertEqual(scheduler.pendingPTS, [10_000, 20_000, 30_000])
    XCTAssertEqual(scheduler.frame(at: 10_000, generation: 1)?.ptsUs, 10_000)
    XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(scheduler.pendingPTS, [20_000, 30_000, 40_000])
  }

  func testPacketCallbackFailurePreservesTheNetworkCause() {
    let networkError = NativePlayerError(
      category: "network",
      code: "network.retry_exhausted",
      message: "Network media retries were exhausted.",
      diagnostic: "networkConnectionLost"
    )

    let error = ylFallbackPacketReadError(
      result: Int32(YLFResultCallbackFailed),
      inputError: networkError,
      container: .matroska
    )

    XCTAssertEqual(error.category, "network")
    XCTAssertEqual(error.code, "network.retry_exhausted")
    XCTAssertEqual(error.diagnostic, "networkConnectionLost")
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

private final class YlDisplayTickProbe {
  private let lock = NSLock()
  private var count = 0

  var tickCount: Int {
    lock.withLock { count }
  }

  func tick() {
    lock.withLock { count += 1 }
  }
}
