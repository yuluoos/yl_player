@testable import yl_player_apple
import AVFoundation
import CoreVideo
import XCTest
import YlFFmpegBridge

/// Characterizes the existing backend before its responsibilities move.
/// The real demux, decoder wrapper, clocks and renderer remain in the path;
/// only the platform VT session and display driver are controlled dependencies.
@MainActor
final class YlManagedFallbackCharacterizationTests: XCTestCase {
  private final class Session: YlVTSession {
    let usesHardwareDecoder = true
    let output: (YlVTDecodedImage) -> Void
    let lock = NSLock()
    var submitted: [UInt64] = []
    var invalidations = 0
    var onInvalidate: (() -> Void)?
    init(output: @escaping (YlVTDecodedImage) -> Void) { self.output = output }
    func decode(_ sample: CMSampleBuffer, generation: UInt64,
                reservation: YlVideoDecodeReservation?) -> OSStatus {
      lock.withLock { submitted.append(generation) }
      reservation?.release()
      return noErr
    }
    func flush() {}
    func invalidate() { lock.withLock { invalidations += 1 }; onInvalidate?() }
    var lastGeneration: UInt64? { lock.withLock { submitted.last } }
    func send(generation: UInt64, status: OSStatus = noErr, ptsUs: Int64 = 0) throws {
      var pixel: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
        kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
      output(YlVTDecodedImage(status: status, pixelBuffer: pixel,
        pts: CMTime(value: ptsUs, timescale: 1_000_000), duration: CMTime(value: 1, timescale: 25),
        keyframe: true, generation: generation, ownershipToken: nil))
    }
  }
  private final class Factory: YlVTSessionFactory {
    var sessions = [Session]()
    var onCreate: (() -> Void)?
    var onInvalidate: (() -> Void)?
    func makeSession(formatDescription: CMVideoFormatDescription,
                     output: @escaping (YlVTDecodedImage) -> Void) throws -> YlVTSession {
      let session = Session(output: output); session.onInvalidate = onInvalidate
      sessions.append(session); onCreate?(); return session
    }
  }
  private final class Output: YlTextureOutput {
    let textureId: Int64 = 731
    var published = 0
    var pixel: CVPixelBuffer?
    var onClear: (() -> Void)?
    func publish(_ pixelBuffer: CVPixelBuffer?) { pixel = pixelBuffer; published += 1 }
    func resize(width: Int, height: Int) {}
    func clear() { pixel = nil; onClear?() }
    func dispose() { clear() }
  }
  private final class Display: YlDisplayDriving {
    var isPaused = true
    var invalidated = false
    func invalidate() { invalidated = true }
  }
  private final class Trace {
    private let lock = NSLock()
    private var entries = [String]()
    func add(_ value: String) { lock.withLock { entries.append(value) } }
    var values: [String] { lock.withLock { entries } }
    func clear() { lock.withLock { entries.removeAll() } }
  }
  private final class SeekControl: YlDemuxControlling {
    let trace: Trace
    let releaseJoin = DispatchSemaphore(value: 0)
    let releaseSeek = DispatchSemaphore(value: 0)
    init(_ trace: Trace) { self.trace = trace }
    func interrupt(_ media: YlOpenedMedia) { trace.add("interrupt"); media.interruptRead() }
    func resume(_ media: YlOpenedMedia) { media.resumeReads(); trace.add("read.resume") }
    func join(_ worker: DispatchQueue, operation: () -> Void) {
      // Real pending work on the exact demux queue must finish before buffers clear.
      worker.async { [self] in
        trace.add("worker.held")
        _ = releaseJoin.wait(timeout: .now() + 10)
        trace.add("worker.finished")
      }
      trace.add("join.begin")
      worker.sync(execute: operation)
      trace.add("join.end")
    }
    func seek(_ media: YlOpenedMedia, toMediaTimeUs target: Int64) throws {
      trace.add("seek.held")
      _ = releaseSeek.wait(timeout: .now() + 10)
      try media.seek(toMediaTimeUs: target)
      trace.add("seek.finished")
    }
  }
  private final class Scheduler: YlPresentationScheduling {
    let actual = YlFrameScheduler()
    let trace: Trace
    init(_ trace: Trace) { self.trace = trace }
    var lateFrameDropCount: Int { actual.lateFrameDropCount }
    var pendingPTS: [Int64] { actual.pendingPTS }
    func enqueue(_ frame: YlFrameEnvelope) -> Bool { actual.enqueue(frame) }
    func frame(at positionUs: Int64, generation: UInt64) -> YlFrameEnvelope? {
      actual.frame(at: positionUs, generation: generation)
    }
    func flush(generation: UInt64) { actual.flush(generation: generation); trace.add("frames.flushed") }
    func dispose() { actual.dispose() }
  }
  private final class Converter: YlAudioPacketConverting {
    let trace: Trace
    init(_ trace: Trace) { self.trace = trace }
    func configure(stream: YlAudioStreamConfiguration) throws {}
    func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate {
      YlAudioBufferEstimate(durationUs: 20_000, byteCount: 64)
    }
    func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer? {
      YlScheduledAudioBuffer(payload: NSObject(), ptsUs: packet.ptsUs,
        durationUs: 20_000, byteCount: 64, generation: packet.generation)
    }
    func reset() { trace.add("converter.reset") }
  }
  private final class AudioOutput: YlAudioOutputDriving {
    let trace: Trace
    let lock = NSLock()
    var volume: Float = 1
    var rate: Float = 1
    var renderedAudioTime: YlRenderedAudioTime? { nil }
    private var storedCompletions = [() -> Void]()
    var completions: [() -> Void] { lock.withLock { storedCompletions } }
    init(_ trace: Trace) { self.trace = trace }
    func configure(sampleRate: Double, channelCount: Int) throws {}
    func schedule(_ buffer: YlScheduledAudioBuffer, completion: @escaping () -> Void) {
      lock.withLock { storedCompletions.append(completion) }
    }
    func play() throws { trace.add("audio.play") }
    func pause() { trace.add("audio.pause") }
    func reset() { trace.add("audio.reset") }
    func dispose() {}
  }
  private final class AudioFactory: YlAudioRendererMaking {
    let output: AudioOutput
    let converter: Converter
    private(set) var renderer: YlAudioRenderer?
    init(_ trace: Trace) { output = AudioOutput(trace); converter = Converter(trace) }
    func makeRenderer(bufferBudget: YlFallbackBufferBudget) -> YlAudioRenderer {
      let value = YlAudioRenderer(bufferBudget: bufferBudget, converter: converter, output: output)
      renderer = value; return value
    }
  }

  private func prepared(_ token: YlOpenCancellationToken? = nil) throws -> YlPreparedFallback {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mkv"))
    return try YlPreparedFallback(source: YlAppleSourceDescriptor(uri: url.absoluteString, kind: .file, formatHint: .matroska),
      requireHardwareProbe: false, cancellationToken: token)
  }
  private func backend(_ prepared: YlPreparedFallback, factory: Factory, output: Output,
                       emit: @escaping (YlNativeBackendCallback) -> Void = { _ in }) throws -> YlFallbackBackend {
    try YlFallbackBackend(playerId: 731,
      services: YlPlatformServices(platform: .current, textureOutput: output,
        makeDisplayDriver: { _ in Display() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: prepared,
      generation: 17, videoSessionFactory: factory, emit: emit)
  }

  // Removing candidate privacy or media transfer invalidation must fail this.
  func testPreparedCandidateIsSilentAndDiscardPreventsTransfer() throws {
    let factory = Factory(), output = Output()
    var callbacks = [YlNativeBackendCallback]()
    let candidate = try backend(prepared(), factory: factory, output: output, emit: { callbacks.append($0) })
    XCTAssertFalse(candidate.isActive)
    XCTAssertEqual(factory.sessions.count, 1)
    XCTAssertTrue(callbacks.isEmpty)
    XCTAssertEqual(output.published, 0)
    candidate.dispose(); candidate.dispose()
    XCTAssertEqual(factory.sessions[0].invalidations, 1)
    let discarded = try prepared()
    discarded.discard()
    XCTAssertThrowsError(try discarded.takeMedia())
    let token = YlOpenCancellationToken(); token.cancel()
    XCTAssertThrowsError(try prepared(token)) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "network.cancelled")
    }
  }

  // A queued old VT output must never publish after a seek recreates its decoder.
  func testSeekRecreatesDecoderAndRejectsOldOutputBeforeNewFrame() async throws {
    let factory = Factory(), output = Output()
    let instance = try backend(prepared(), factory: factory, output: output)
    defer { instance.dispose() }
    try instance.activate()
    try await AppleHostCharacterizations.waitFor { factory.sessions[0].lastGeneration != nil }
    let old = factory.sessions[0]
    let generation = try XCTUnwrap(old.lastGeneration)
    try instance.seek(toMs: Int64(0), cancellationToken: nil)
    XCTAssertEqual(factory.sessions.count, 2)
    XCTAssertEqual(old.invalidations, 1)
    try await AppleHostCharacterizations.waitFor { factory.sessions[1].lastGeneration != nil }
    let current = factory.sessions[1]
    XCTAssertNotEqual(current.lastGeneration, generation)
    try old.send(generation: generation)
    await Task.yield()
    XCTAssertEqual(output.published, 0)
    try current.send(generation: XCTUnwrap(current.lastGeneration))
    try await AppleHostCharacterizations.waitFor { output.published > 0 }
    XCTAssertNotNil(instance.copyPixelBuffer())
  }

  // R10: added in fix round1, not historical pre-extraction evidence. These are
  // the actual backend's wired stages; observers forward to real queue/media,
  // renderer and frame scheduler instead of constructing a transaction helper.
  func testBackendSeekOrdersHeldStagesAndSuppressesOldAudioAndVideo() async throws {
    let trace = Trace(), factory = Factory(), output = Output()
    let audio = AudioFactory(trace), control = SeekControl(trace), scheduler = Scheduler(trace)
    factory.onCreate = { trace.add("video.created") }
    factory.onInvalidate = { trace.add("video.retired") }
    output.onClear = { trace.add("texture.cleared") }
    let instance = try YlFallbackBackend(playerId: 731,
      services: YlPlatformServices(platform: .current, textureOutput: output,
        makeDisplayDriver: { _ in Display() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: prepared(),
      generation: 17, videoSessionFactory: factory,
      audioRendererFactory: audio, presentationScheduler: scheduler, demuxControl: control,
      emit: { _ in })
    defer { control.releaseJoin.signal(); control.releaseSeek.signal(); instance.dispose() }
    try instance.activate()
    try instance.play()
    try await AppleHostCharacterizations.waitFor {
      factory.sessions[0].lastGeneration != nil && !audio.output.completions.isEmpty
    }
    let oldVideo = factory.sessions[0], oldGeneration = try XCTUnwrap(oldVideo.lastGeneration)
    let renderer = try XCTUnwrap(audio.renderer)
    let oldCompletions = audio.output.completions
    try oldVideo.send(generation: oldGeneration)
    try oldVideo.send(generation: oldGeneration, ptsUs: 1_000_000)
    try await AppleHostCharacterizations.waitFor { output.pixel != nil && !scheduler.pendingPTS.isEmpty }
    trace.clear()
    let completed = expectation(description: "actual backend seek completed")
    DispatchQueue.global().async {
      defer { completed.fulfill() }
      do { try instance.seek(toMs: Int64(100), cancellationToken: nil) }
      catch { XCTFail("Seek failed: \(error)") }
    }
    try await AppleHostCharacterizations.waitFor { trace.values.contains("worker.held") }
    XCTAssertTrue(trace.values.contains("audio.pause"))
    XCTAssertFalse(trace.values.contains("texture.cleared"))
    XCTAssertFalse(trace.values.contains("seek.held"))
    control.releaseJoin.signal()
    try await AppleHostCharacterizations.waitFor { trace.values.contains("seek.held") }
    XCTAssertTrue(scheduler.pendingPTS.isEmpty, "The real scheduler must flush before actual demux seek")
    XCTAssertNil(instance.copyPixelBuffer())
    XCTAssertNil(output.pixel)
    XCTAssertFalse(trace.values.contains("audio.reset"), "Audio reset follows completed demux seek")
    XCTAssertEqual(oldVideo.invalidations, 0)
    let publishedBeforeStale = output.published
    try oldVideo.send(generation: oldGeneration)
    await Task.yield()
    XCTAssertEqual(output.published, publishedBeforeStale)
    control.releaseSeek.signal()
    await fulfillment(of: [completed], timeout: 10)
    let stages = trace.values
    let required = ["audio.pause", "interrupt", "worker.finished", "join.end", "texture.cleared",
                    "frames.flushed", "seek.held", "seek.finished", "converter.reset", "audio.reset",
                    "video.retired", "video.created", "audio.play"]
    var previous = -1
    for stage in required {
      let index = try XCTUnwrap(stages.firstIndex(of: stage), "Missing actual stage: \(stage); \(stages)")
      XCTAssertGreaterThan(index, previous, "Wrong actual seek order: \(stages)")
      previous = index
    }
    try instance.pause()
    XCTAssertEqual(try renderer.enqueue(packet: YlCompressedAudioPacket(data: Data([1]),
      ptsUs: 0, durationUs: 20_000, generation: oldGeneration)), .staleGeneration)
    let scheduledAfterSeek = renderer.scheduledBytes
    for completion in oldCompletions { completion() }
    XCTAssertEqual(renderer.scheduledBytes, scheduledAfterSeek, "Pre-seek completions cannot consume new audio")
    XCTAssertEqual(oldVideo.invalidations, 1)
    let currentVideo = try XCTUnwrap(factory.sessions.last)
    try await AppleHostCharacterizations.waitFor { currentVideo.lastGeneration != nil }
    let currentGeneration = try XCTUnwrap(currentVideo.lastGeneration)
    try oldVideo.send(generation: oldGeneration)
    try currentVideo.send(generation: currentGeneration, ptsUs: 0)
    await Task.yield()
    XCTAssertEqual(output.published, publishedBeforeStale, "Stale generation and pre-target video stay suppressed")
    try currentVideo.send(generation: currentGeneration, ptsUs: 100_000)
    // Initial firstFrame was already sent: verify actual scheduler output at target.
    XCTAssertEqual(scheduler.pendingPTS, [100_000])
    XCTAssertNotNil(scheduler.frame(at: 100_000, generation: currentGeneration))
  }

  // Removing lifecycle generation invalidation would revive disposed output.
  func testStopAndDisposeRejectHeldDecodeOutputAndReleasePackets() async throws {
    let factory = Factory(), output = Output()
    var events = [YlNativeBackendCallback]()
    let instance = try backend(prepared(), factory: factory, output: output, emit: { events.append($0) })
    try instance.activate()
    try await AppleHostCharacterizations.waitFor { factory.sessions[0].lastGeneration != nil }
    let session = factory.sessions[0]
    let generation = try XCTUnwrap(session.lastGeneration)
    instance.stop()
    let count = events.count
    try session.send(generation: generation)
    await Task.yield()
    XCTAssertEqual(events.count, count)
    XCTAssertFalse(instance.isActive)
    XCTAssertNil(instance.copyPixelBuffer())
    XCTAssertEqual(output.published, 0)
    instance.dispose(); instance.dispose()
    XCTAssertEqual(session.invalidations, 1)
    XCTAssertEqual(ylf_debug_outstanding_packet_count(), 0)
  }

  // The decoder's real error callback must reach the backend terminal transition.
  func testCurrentDecodeErrorFailsOnceAndSuppressesRetiredFailure() async throws {
    let factory = Factory(), output = Output()
    var errors = [NativePlayerError]()
    let instance = try backend(prepared(), factory: factory, output: output, emit: {
      if case .failure(let error) = $0.event { errors.append(error) }
    })
    defer { instance.dispose() }
    try instance.activate()
    try await AppleHostCharacterizations.waitFor { factory.sessions[0].lastGeneration != nil }
    let session = factory.sessions[0]
    let generation = try XCTUnwrap(session.lastGeneration)
    try session.send(generation: generation, status: -1)
    try await AppleHostCharacterizations.waitFor { !errors.isEmpty }
    XCTAssertEqual(errors.count, 1)
    XCTAssertFalse(instance.isActive)
    try session.send(generation: generation, status: -1)
    await Task.yield()
    XCTAssertEqual(errors.count, 1)
  }

  // Clock rate must affect which real scheduler frame is due, with no early frame.
  func testPresentationChoosesFramesAtQuarterNormalDoubleAndQuadrupleRate() {
    for (rate, position, due) in [(0.25, Int64(25_000), Int64(20_000)),
                                 (1.0, 100_000, 100_000),
                                 (2.0, 200_000, 200_000),
                                 (4.0, 400_000, 400_000)] {
      let clock = YlMediaClock()
      let scheduler = YlFrameScheduler()
      clock.setRate(rate, atHostTimeUs: 0)
      clock.play(atHostTimeUs: 0)
      for pts in [due - 10_000, due, due + 10_000] {
        XCTAssertTrue(scheduler.enqueue(YlFrameEnvelope(payload: NSObject(), ptsUs: pts,
          durationUs: 10_000, keyframe: false, generation: 1)))
      }
      XCTAssertEqual(clock.position(atHostTimeUs: 100_000), position)
      XCTAssertEqual(scheduler.frame(at: position, generation: 1)?.ptsUs, due)
      XCTAssertEqual(scheduler.pendingPTS, [due + 10_000])
    }
  }

  // EOF is distinct from callback failure, and invalid reads retain container identity.
  func testDemuxEOFCancellationAndMalformedReadRemainDistinct() throws {
    let value = try prepared()
    let media = try value.takeMedia()
    defer { media.close() }
    var result = Int32(YLFResultOK)
    while result == Int32(YLFResultOK) {
      var packet: YLFPacketRef?
      result = ylf_read_packet(media.context, &packet)
      ylf_packet_release(&packet)
    }
    XCTAssertEqual(result, Int32(YLFResultEOF))
    let transient = NativePlayerError(category: "network", code: "network.read_timeout", message: "Timed out")
    XCTAssertEqual(ylFallbackPacketReadError(result: Int32(YLFResultCallbackFailed),
      inputError: transient, container: .flv).code, "network.read_timeout")
    XCTAssertEqual(ylFallbackPacketReadError(result: -1, inputError: transient,
      container: .flv).code, "container.flv_malformed")
    XCTAssertEqual(ylFallbackPacketReadError(result: -1, inputError: nil,
      container: .matroska).code, "container.mkv_malformed")
    XCTAssertEqual(ylf_debug_outstanding_packet_count(), 0)
  }
}
