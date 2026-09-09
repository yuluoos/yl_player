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
    init(output: @escaping (YlVTDecodedImage) -> Void) { self.output = output }
    func decode(_ sample: CMSampleBuffer, generation: UInt64,
                reservation: YlVideoDecodeReservation?) -> OSStatus {
      lock.withLock { submitted.append(generation) }
      reservation?.release()
      return noErr
    }
    func flush() {}
    func invalidate() { lock.withLock { invalidations += 1 } }
    var lastGeneration: UInt64? { lock.withLock { submitted.last } }
    func send(generation: UInt64, status: OSStatus = noErr) throws {
      var pixel: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
        kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
      output(YlVTDecodedImage(status: status, pixelBuffer: pixel,
        pts: .zero, duration: CMTime(value: 1, timescale: 25),
        keyframe: true, generation: generation, ownershipToken: nil))
    }
  }
  private final class Factory: YlVTSessionFactory {
    var sessions = [Session]()
    func makeSession(formatDescription: CMVideoFormatDescription,
                     output: @escaping (YlVTDecodedImage) -> Void) throws -> YlVTSession {
      let session = Session(output: output); sessions.append(session); return session
    }
  }
  private final class Output: YlTextureOutput {
    let textureId: Int64 = 731
    var published = 0
    var pixel: CVPixelBuffer?
    func publish(_ pixelBuffer: CVPixelBuffer?) { pixel = pixelBuffer; published += 1 }
    func resize(width: Int, height: Int) {}
    func clear() { pixel = nil }
    func dispose() { clear() }
  }
  private final class Display: YlDisplayDriving {
    var isPaused = true
    var invalidated = false
    func invalidate() { invalidated = true }
  }
  private func prepared(_ token: YlOpenCancellationToken? = nil) throws -> YlPreparedFallback {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mkv"))
    return try YlPreparedFallback(source: ["uri": url.absoluteString, "formatHint": "matroska"],
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
    try instance.command(name: "seekTo", arguments: ["positionMs": Int64(0)])
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
