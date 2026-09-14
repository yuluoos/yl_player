@testable import yl_player_apple
import AVFAudio
import XCTest
import YlFFmpegBridge

final class YlAudioRendererTests: XCTestCase {
  func testStereoConverterKeepsOnePacketOfPCMHeadroom() throws {
    let converter = YlAppleCompressedAudioConverter()
    try converter.configure(stream: YlAudioStreamConfiguration(
      codec: .aac, sampleRate: 48_000, channelCount: 2,
      magicCookie: Data([0x11, 0x90]), generation: 1
    ))
    // One AAC-LC silence packet, 48 kHz stereo, without an ADTS header.
    let packet = YlCompressedAudioPacket(
      data: Data([0x21, 0x10, 0x04, 0x60, 0x8c, 0x1c]),
      ptsUs: 0, durationUs: 21_333, generation: 1
    )
    let converted = try XCTUnwrap(converter.convert(packet: packet))
    let pcm = try XCTUnwrap(converted.payload as? AVAudioPCMBuffer)
    XCTAssertEqual(pcm.frameLength, 1024)
    XCTAssertEqual(pcm.frameCapacity, 2048)
    XCTAssertEqual(converted.byteCount, 1024 * 2 * MemoryLayout<Float>.size)
  }

  func testSystemOutputConfiguresMonoAndStereoPCMWithoutAudioUnitException() throws {
    let output = YlSystemAudioOutput()
    defer { output.dispose() }
    for channels in [1, 2] {
      try output.configure(sampleRate: 48_000, channelCount: channels)
      try output.configure(sampleRate: 44_100, channelCount: channels)
    }
  }

  func testPlayedBufferClockFreezesDuringStarvationAndIgnoresOldCompletions() throws {
    let output = FakeOutput()
    let renderer = YlAudioRenderer(converter: FakeConverter(), output: output)
    try renderer.configure(stream: stream())
    try renderer.play()
    func enqueue(_ pts: Int64, generation: UInt64 = 1) throws {
      XCTAssertEqual(try renderer.enqueue(packet: YlCompressedAudioPacket(
        data: Data([1]), ptsUs: pts, durationUs: 250_000, generation: generation
      )), .scheduled)
    }
    try enqueue(1_000_000)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 1_000_000)
    output.completions[0]()
    XCTAssertEqual(renderer.renderedAudioTime, YlRenderedAudioTime(sampleTime: 1_250_000, sampleRate: 1_000_000))
    renderer.setRate(3)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 1_250_000)
    try enqueue(1_250_000)
    output.completions[1]()
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 1_500_000)
    renderer.reset(generation: 2)
    XCTAssertNil(renderer.renderedAudioTime)
    try enqueue(5_000_000, generation: 2)
    output.completions[0]()
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 5_000_000)
    output.completions[2]()
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 5_250_000)
    renderer.finishInput()
    XCTAssertNil(renderer.renderedAudioTime)
  }

  func testPausedBufferCompletionDoesNotLosePositionAfterResume() throws {
    let output = FakeOutput()
    let renderer = YlAudioRenderer(converter: FakeConverter(), output: output)
    try renderer.configure(stream: stream())
    try renderer.play()
    for pts in [Int64(0), 250_000] {
      XCTAssertEqual(try renderer.enqueue(packet: YlCompressedAudioPacket(
        data: Data([1]), ptsUs: pts, durationUs: 250_000, generation: 1
      )), .scheduled)
    }
    output.completions[0]()
    renderer.pause()
    output.completions[1]()
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 250_000)
    try renderer.play()
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 250_000)
    XCTAssertEqual(try renderer.enqueue(packet: YlCompressedAudioPacket(
      data: Data([1]), ptsUs: 500_000, durationUs: 250_000, generation: 1
    )), .scheduled)
    output.completions[2]()
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 750_000)
  }

  func testSilentVideoTailAdvancesOnlyThroughDecodedVideoAndAudioResumesOnce() throws {
    let output = FakeOutput()
    let renderer = YlAudioRenderer(converter: FakeConverter(), output: output)
    try renderer.configure(stream: stream())
    try renderer.play()
    XCTAssertEqual(try renderer.enqueue(packet: packet()), .scheduled)
    output.completions[0]()
    renderer.advanceSilence(through: nil, atHostTimeUs: 0)
    renderer.advanceSilence(through: nil, atHostTimeUs: 10_000_000)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 250_000)
    renderer.advanceSilence(through: 750_000, atHostTimeUs: 11_000_000)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 750_000)
    renderer.advanceSilence(through: 750_000, atHostTimeUs: 20_000_000)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 750_000)
    renderer.setRate(3)
    renderer.advanceSilence(through: 2_000_000, atHostTimeUs: 20_250_000)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 1_500_000)
    XCTAssertEqual(try renderer.enqueue(packet: YlCompressedAudioPacket(
      data: Data([1]), ptsUs: 1_500_000, durationUs: 250_000, generation: 1
    )), .scheduled)
    renderer.advanceSilence(through: 3_000_000, atHostTimeUs: 21_000_000)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 1_500_000)
    output.completions[1]()
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 1_750_000)
    renderer.advanceSilence(through: 3_000_000, atHostTimeUs: 21_010_000)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 1_750_000, "Completion must not double-count the previous audible tick")
    renderer.pause()
    renderer.advanceSilence(through: 3_000_000, atHostTimeUs: 30_000_000)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 1_750_000)
  }

  func testVideoClockAdvancesWhilePlayedBackCallbacksAreDelayed() throws {
    let output = FakeOutput()
    output.renderedAudioTime = YlRenderedAudioTime(sampleTime: 0, sampleRate: 48_000)
    let renderer = YlAudioRenderer(converter: FakeConverter(), output: output)
    try renderer.configure(stream: stream())
    XCTAssertEqual(try renderer.enqueue(packet: packet()), .scheduled)
    try renderer.play()
    let clock = YlMediaClock(audioTime: { renderer.renderedAudioTime })
    clock.play(atHostTimeUs: 0)
    let scheduler = YlFrameScheduler()
    defer { scheduler.dispose() }
    for pts in [Int64(40_000), 80_000, 120_000] {
      XCTAssertTrue(scheduler.enqueue(YlFrameEnvelope(payload: Token(), ptsUs: pts,
        durationUs: 40_000, keyframe: false, generation: 1)))
    }
    // Audio renders normally, but no dataPlayedBack completion has arrived.
    for (sample, pts) in [(Int64(1_920), Int64(40_000)), (3_840, 80_000), (5_760, 120_000)] {
      output.renderedAudioTime = YlRenderedAudioTime(sampleTime: sample, sampleRate: 48_000)
      let position = clock.position(atHostTimeUs: pts)
      XCTAssertEqual(position, pts)
      XCTAssertEqual(scheduler.frame(at: position, generation: 1)?.ptsUs, pts)
    }
    XCTAssertEqual(scheduler.lateFrameDropCount, 0)
    output.completions[0]()
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 250_000)
  }

  func testRenderClockCapsAtScheduledAudioAndExcludesStarvationOnRefill() throws {
    let output = FakeOutput()
    output.renderedAudioTime = YlRenderedAudioTime(sampleTime: 0, sampleRate: 48_000)
    let renderer = YlAudioRenderer(converter: FakeConverter(), output: output)
    try renderer.configure(stream: stream())
    XCTAssertEqual(try renderer.enqueue(packet: packet()), .scheduled)
    try renderer.play()
    output.renderedAudioTime = YlRenderedAudioTime(sampleTime: 48_000, sampleRate: 48_000)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 250_000)
    output.completions[0]()
    output.renderedAudioTime = YlRenderedAudioTime(sampleTime: 96_000, sampleRate: 48_000)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 250_000)
    XCTAssertEqual(try renderer.enqueue(packet: YlCompressedAudioPacket(
      data: Data([1]), ptsUs: 250_000, durationUs: 250_000, generation: 1)), .scheduled)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 250_000)
    output.renderedAudioTime = YlRenderedAudioTime(sampleTime: 100_800, sampleRate: 48_000)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 350_000)
    renderer.setRate(3)
    output.renderedAudioTime = YlRenderedAudioTime(sampleTime: 103_200, sampleRate: 48_000)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 400_000, "Player samples already include playback rate")
  }

  func testRenderClockPreservesPauseAndResetsItsAnchorAfterSeek() throws {
    let output = FakeOutput()
    output.renderedAudioTime = YlRenderedAudioTime(sampleTime: 0, sampleRate: 48_000)
    let renderer = YlAudioRenderer(converter: FakeConverter(), output: output)
    try renderer.configure(stream: stream())
    XCTAssertEqual(try renderer.enqueue(packet: packet()), .scheduled)
    try renderer.play()
    output.renderedAudioTime = YlRenderedAudioTime(sampleTime: 4_800, sampleRate: 48_000)
    renderer.pause()
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 100_000)
    try renderer.play()
    output.renderedAudioTime = YlRenderedAudioTime(sampleTime: 7_200, sampleRate: 48_000)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 150_000)
    renderer.pause()
    output.completions[0]()
    XCTAssertEqual(try renderer.enqueue(packet: YlCompressedAudioPacket(
      data: Data([1]), ptsUs: 250_000, durationUs: 250_000, generation: 1)), .scheduled)
    try renderer.play()
    output.renderedAudioTime = YlRenderedAudioTime(sampleTime: 9_600, sampleRate: 48_000)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 300_000, "Refill while paused retains the player sample offset")
    renderer.reset(generation: 2)
    output.renderedAudioTime = nil
    XCTAssertEqual(try renderer.enqueue(packet: YlCompressedAudioPacket(
      data: Data([1]), ptsUs: 5_000_000, durationUs: 250_000, generation: 2)), .scheduled)
    output.completions[0]()
    output.renderedAudioTime = YlRenderedAudioTime(sampleTime: 2_400, sampleRate: 48_000)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 5_050_000)
    renderer.finishInput()
    output.completions[2]()
    XCTAssertNil(renderer.renderedAudioTime)
  }

  func testRefillBeforeDelayedCompletionDoesNotCountSilentNodeTime() throws {
    for paused in [false, true] {
      let output = FakeOutput()
      output.renderedAudioTime = YlRenderedAudioTime(sampleTime: 0, sampleRate: 48_000)
      let renderer = YlAudioRenderer(converter: FakeConverter(), output: output)
      try renderer.configure(stream: stream())
      XCTAssertEqual(try renderer.enqueue(packet: packet()), .scheduled)
      try renderer.play()
      output.renderedAudioTime = YlRenderedAudioTime(sampleTime: 48_000, sampleRate: 48_000)
      XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 250_000)
      if paused { renderer.pause() }
      // PCM ended 750 ms ago, but its completion is still pending when input resumes.
      XCTAssertEqual(try renderer.enqueue(packet: YlCompressedAudioPacket(
        data: Data([1]), ptsUs: 250_000, durationUs: 250_000, generation: 1)), .scheduled)
      if paused { try renderer.play() }
      output.renderedAudioTime = YlRenderedAudioTime(sampleTime: 48_000, sampleRate: 48_000)
      XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 250_000)
      output.completions[0]()
      output.renderedAudioTime = YlRenderedAudioTime(sampleTime: 52_800, sampleRate: 48_000)
      XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 350_000)
    }
  }

  private final class Token {}

  private final class FakeConverter: YlAudioPacketConverting {
    var configurationError: Error?
    var conversionError: Error?
    var outputDurationUs: Int64 = 250_000
    var outputBytes = 1_000
    private(set) var convertCount = 0

    func configure(stream: YlAudioStreamConfiguration) throws {
      if let configurationError { throw configurationError }
    }

    func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate {
      YlAudioBufferEstimate(durationUs: outputDurationUs, byteCount: outputBytes)
    }

    func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer? {
      if let conversionError { throw conversionError }
      convertCount += 1
      return YlScheduledAudioBuffer(
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
    var renderedAudioTime: YlRenderedAudioTime? = nil
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
    func pause() {
      pauseCount += 1
      // AVAudioPlayerNode.playerTime(forNodeTime:) is nil when not playing.
      renderedAudioTime = nil
    }
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
      XCTAssertEqual((error as? NativePlayerError)?.category, "decoderUnsupported")
    }
  }

  func testConfigurationFailureMapsToStableMP3Error() {
    let converter = FakeConverter()
    converter.configurationError = NSError(domain: "test", code: 1)
    let renderer = YlAudioRenderer(converter: converter, output: FakeOutput())
    let mp3Stream = YlAudioStreamConfiguration(
      codec: .mp3,
      sampleRate: 48_000,
      channelCount: 1,
      magicCookie: Data(),
      generation: 1
    )

    XCTAssertThrowsError(try renderer.configure(stream: mp3Stream)) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "decoder.audio_mp3_unsupported")
      XCTAssertTrue((error as? NativePlayerError)?.message.contains("MP3") ?? false)
    }
  }

  func testConversionFailureUsesCodecSpecificMessage() throws {
    let converter = FakeConverter()
    converter.conversionError = NSError(domain: "test", code: 2)
    let renderer = YlAudioRenderer(converter: converter, output: FakeOutput())
    try renderer.configure(stream: YlAudioStreamConfiguration(
      codec: .mp3,
      sampleRate: 48_000,
      channelCount: 1,
      magicCookie: Data(),
      generation: 1
    ))

    XCTAssertThrowsError(try renderer.enqueue(packet: packet())) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "decoder.audio_failed")
      XCTAssertTrue((error as? NativePlayerError)?.message.contains("MP3") ?? false)
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

  func testRateScalesAudioCapacityAndReturningToNormalDrainsQueuedAudio() throws {
    let converter = FakeConverter()
    let output = FakeOutput()
    let renderer = YlAudioRenderer(
      maxScheduledDurationUs: 500_000,
      maxScheduledBytes: 10_000,
      converter: converter,
      output: output
    )
    defer { renderer.dispose() }
    try renderer.configure(stream: stream())
    renderer.setRate(3)
    for _ in 0..<6 {
      XCTAssertEqual(try renderer.enqueue(packet: packet()), .scheduled)
    }
    XCTAssertEqual(renderer.scheduledDurationUs, 1_500_000)
    XCTAssertEqual(renderer.scheduledBytes, 6_000)
    XCTAssertEqual(try renderer.enqueue(packet: packet()), .wouldExceedDuration)

    renderer.setRate(1)
    XCTAssertEqual(renderer.scheduledDurationUs, 1_500_000)
    XCTAssertEqual(renderer.scheduledBytes, 6_000)
    XCTAssertEqual(try renderer.enqueue(packet: packet()), .wouldExceedDuration)
    for index in 0..<4 { output.completions[index]() }
    XCTAssertEqual(renderer.scheduledDurationUs, 500_000)
    XCTAssertEqual(try renderer.enqueue(packet: packet()), .wouldExceedDuration)
    XCTAssertEqual(converter.convertCount, 6)

    output.completions[4]()
    XCTAssertEqual(renderer.scheduledDurationUs, 250_000)
    XCTAssertEqual(try renderer.enqueue(packet: packet()), .scheduled)
    XCTAssertEqual(renderer.scheduledDurationUs, 500_000)
    XCTAssertEqual(renderer.scheduledBytes, 2_000)
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
    XCTAssertEqual(converter.convertCount, 0)
  }

  func testScheduledPCMByteLimitComesFromFallbackBudget() throws {
    let budget = try YlFallbackBufferBudget.make(configuration: PlayerConfiguration(map: [
      "bufferMode": "lowLatency",
    ]))
    let converter = FakeConverter()
    let output = FakeOutput()
    converter.outputBytes = budget.scheduledAudioBytes + 1
    let renderer = YlAudioRenderer(
      bufferBudget: budget,
      converter: converter,
      output: output
    )
    try renderer.configure(stream: stream())

    XCTAssertEqual(try renderer.enqueue(packet: packet()), .wouldExceedBytes)
    XCTAssertEqual(converter.convertCount, 0)
    XCTAssertTrue(output.completions.isEmpty)
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

    let converter = YlAppleCompressedAudioConverter()
    try converter.configure(stream: stream())
    let converted = try XCTUnwrap(converter.convert(packet: try XCTUnwrap(compressedPacket)))
    let pcm = try XCTUnwrap(converted.payload as? AVAudioPCMBuffer)
    XCTAssertGreaterThan(pcm.frameLength, 0)
    XCTAssertLessThanOrEqual(converted.durationUs, 30_000)
    XCTAssertGreaterThan(converted.byteCount, 0)
  }

  func testAppleConverterDecodesFixtureMP3Packet() throws {
    let fixture = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "h264_mp3", withExtension: "flv")
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

    var audioInfo: YLFStreamInfo?
    for index in 0..<mediaInfo.stream_count {
      var streamInfo = YLFStreamInfo()
      XCTAssertEqual(ylf_copy_stream_info(context, index, &streamInfo), 0)
      if Int(streamInfo.kind) == YLFStreamAudio {
        audioInfo = streamInfo
      }
    }
    let selectedAudio = try XCTUnwrap(audioInfo)
    XCTAssertEqual(selectedAudio.codec, Int32(YLFCodecMP3))
    var compressedPacket: YlCompressedAudioPacket?
    while compressedPacket == nil {
      var packet: YLFPacketRef?
      XCTAssertEqual(ylf_read_packet(context, &packet), 0)
      guard let ownedPacket = packet else { continue }
      if ylf_packet_stream_index(ownedPacket) == selectedAudio.index {
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

    let converter = YlAppleCompressedAudioConverter()
    try converter.configure(stream: YlAudioStreamConfiguration(
      codec: .mp3,
      sampleRate: Double(selectedAudio.sample_rate),
      channelCount: Int(selectedAudio.channel_count),
      magicCookie: Data(),
      generation: 1
    ))
    let converted = try XCTUnwrap(converter.convert(packet: try XCTUnwrap(compressedPacket)))
    let pcm = try XCTUnwrap(converted.payload as? AVAudioPCMBuffer)
    XCTAssertGreaterThan(pcm.frameLength, 0)
    XCTAssertGreaterThan(converted.byteCount, 0)
  }
}
