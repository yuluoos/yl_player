@testable import yl_player_apple
import CoreMedia
import CoreVideo
import XCTest
import YlFFmpegBridge

private final class SoftwareSelectionResource: YlVideoDecoderResource {
  let hardwareEvidence: YlHardwareDecoderEvidence
  var usesHardwareDecoder: Bool { hardwareEvidence.mode == .hardware }
  var disposed = false
  init(_ mode: YlHardwareDecoderEvidence.Mode) { hardwareEvidence = .init(mode: mode) }
  func reserve(byteCount: Int, shouldCancel: () -> Bool) throws -> YlVideoDecodeReservation? { nil }
  func reserveSubmission(byteCount: Int, shouldCancel: () -> Bool) throws -> YlVideoDecodeReservation? { nil }
  func decode(sample: CMSampleBuffer, generation: UInt64, reservation: YlVideoDecodeReservation?) {}
  func drain() {}
  func flush() {}
  func dispose() { disposed = true }
}

private struct NoSoftwareHardware: YlVTSessionFactory {
  var onAttempt: () -> Void = {}
  func makeSession(formatDescription: CMVideoFormatDescription, output: @escaping (YlVTDecodedImage) -> Void) throws -> YlVTSession {
    onAttempt(); throw YlHardwareDecoderEvidence.unavailable()
  }
}

private final class SoftwarePipelineOutput: YlVideoPipelineOutput {
  let lock = NSLock()
  var pixels = [UInt32](); var retained: CVPixelBuffer?; var errors = [String]()
  func setDemuxPumping(_ value: Bool) {}
  func receive(_ frame: YlVideoFrame) {
    lock.withLock {
      pixels.append(CVPixelBufferGetPixelFormatType(frame.pixelBuffer))
      if retained == nil { retained = frame.pixelBuffer }
    }
  }
  func fail(_ error: NativePlayerError) { lock.withLock { errors.append(error.code) } }
  func shouldCancelVideoTask(generation: UInt64) -> Bool { false }
  func shouldReportVideoFailure(generation: UInt64) -> Bool { true }
  func isVideoDrainCurrent(generation: UInt64) -> Bool { true }
}

private final class SoftwareTexture: YlTextureOutput {
  let textureId: Int64 = 994
  func publish(_ pixelBuffer: CVPixelBuffer?) {}
  func resize(width: Int, height: Int) {}
  func clear() {}
  func dispose() {}
}
private final class SoftwareDisplay: YlDisplayDriving {
  var isPaused = false
  func invalidate() { isPaused = true }
}

private final class SoftwareDashHop: YlDashResourceHop {
  let action: () -> Void
  init(_ action: @escaping () -> Void) { self.action = action }
  func start() { action() }
  func cancel() {}
}

final class YlSoftwareVideoLifecycleTests: XCTestCase {
  func testHardwareRequiredNeverCallsSoftwareAndRejectsUnknownEvidence() throws {
    for mode in [YlHardwareDecoderEvidence.Mode.unknown, .software] {
      let resource = SoftwareSelectionResource(mode); var calls = 0
      XCTAssertThrowsError(try YlVideoDecoderSelection.choose(policy: .hardwareRequired,
        hardware: { resource }, software: { calls += 1; return SoftwareSelectionResource(.software) })) {
        XCTAssertEqual(($0 as? NativePlayerError)?.code, "decoder.unavailable")
      }
      XCTAssertTrue(resource.disposed); XCTAssertEqual(calls, 0)
    }
  }
  func testHardwareFirstAndOnlyUnavailableErrorsCanFallback() throws {
    let hardware = SoftwareSelectionResource(.hardware); var calls = 0
    let result = try YlVideoDecoderSelection.choose(policy: .hardwarePreferred,
      hardware: { hardware }, software: { calls += 1; return SoftwareSelectionResource(.software) })
    XCTAssertTrue(result === hardware); XCTAssertEqual(calls, 0)
    XCTAssertThrowsError(try YlVideoDecoderSelection.choose(policy: .systemDefault,
      hardware: { throw NativePlayerError(category: "decoder", code: "decoder.video_configuration_invalid", message: "test") },
      software: { calls += 1; return SoftwareSelectionResource(.software) }))
    XCTAssertEqual(calls, 0)
    let software = try YlVideoDecoderSelection.choose(policy: .systemDefault,
      hardware: { throw YlHardwareDecoderEvidence.unavailable() },
      software: { calls += 1; return SoftwareSelectionResource(.software) })
    XCTAssertEqual(calls, 1); XCTAssertFalse(software.usesHardwareDecoder)
  }

  func testActualVP9RetainedOutputSurvivesDecoderAndConfigurationRelease() throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "p03-webm-vp9-vorbis", withExtension: "webm"))
    var context: YLFMediaContextRef?; var info = YLFMediaInfo()
    XCTAssertEqual(ylf_open_local(url.path, &context, &info), 0)
    defer { ylf_close(&context) }
    let media = try XCTUnwrap(context)
    let config = try YlSoftwareVideoConfiguration(context: media, streamIndex: 0)
    let prepared = try YlPreparedFallback(source: .init(uri: url.absoluteString, kind: .file, formatHint: .matroska), requireHardwareProbe: false)
    defer { prepared.discard() }
    let key = config.key(model: "controlled", osBuild: "test", decoderBuild: "test", threads: 1,
      outputPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let limits = YlSoftwareDecodeLimits(maxOwnedBytes: 32 * 1024 * 1024, maxFrames: 64,
      maxPacketBytes: 1024 * 1024, windowNs: 1_000_000, maxCpuNs: 1_000_000, maxDecodeWallNs: 1_000_000)
    let pool = YlSoftwareDecodePool(); var ticks: UInt64 = 0
    var retained: CVPixelBuffer?; var count = 0; var failures = [NativePlayerError]()
    let decoder = try YlSoftwareVideoDecoder(configuration: config, key: key,
      admission: .init(entries: [key: limits]), pool: pool, maxInFlightBytes: 1024 * 1024,
      observe: { _ in ticks += 1; return .init(monotonicNs: ticks, cumulativeCpuNs: ticks, decodeWallNs: 1, thermalNominal: true) },
      onFrame: { frame in
        count += 1; if retained == nil { retained = frame.pixelBuffer }
        XCTAssertEqual(frame.generation, 4)
        if count <= 2 { XCTAssertEqual(frame.keyframe, count == 1) }
        XCTAssertEqual(CVPixelBufferGetWidth(frame.pixelBuffer), 320)
      }, onError: { failures.append($0) })
    XCTAssertEqual(decoder.hardwareEvidence.decoderName, "FFmpeg VP9")
    XCTAssertFalse(decoder.usesHardwareDecoder)
    while true {
      var packet: YLFPacketRef?
      if ylf_read_packet(media, &packet) != 0 { break }
      guard let p = packet else { XCTFail("missing packet"); break }
      if ylf_packet_stream_index(p) == 0 {
        var sample: Unmanaged<CMSampleBuffer>?
        XCTAssertEqual(ylf_create_video_sample_buffer(&packet, prepared.videoFormat, &sample), 0)
        decoder.decode(sample: try XCTUnwrap(sample).takeRetainedValue(), generation: 4, reservation: nil)
      }
      ylf_packet_release(&packet)
    }
    decoder.drain(); decoder.dispose(); decoder.dispose()
    XCTAssertTrue(failures.isEmpty, "\(failures)"); XCTAssertEqual(count, 96)
    XCTAssertGreaterThan(pool.ownedBytes, 0)
    XCTAssertNotNil(retained); retained = nil
    XCTAssertEqual(pool.ownedBytes, 0)
  }
  func testPipelineUnadmittedCandidatePreservesCurrentResource() throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "p03-webm-vp9-vorbis", withExtension: "webm"))
    let prepared = try YlPreparedFallback(source: .init(uri: url.absoluteString, kind: .file, formatHint: .matroska), requireHardwareProbe: false)
    defer { prepared.discard() }
    let pipeline = YlVideoPipeline(format: prepared.videoFormat,
      bufferBudget: try .make(configuration: .init(map: [:]), prepared: prepared),
      factory: NoSoftwareHardware(), policy: .hardwarePreferred,
      softwareConfiguration: prepared.softwareConfiguration)
    let current = SoftwareSelectionResource(.hardware)
    pipeline.install(.ordinary(current, prepared.videoFormat))
    XCTAssertThrowsError(try pipeline.prepareCurrent()) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "decoder.unavailable")
    }
    XCTAssertFalse(current.disposed); XCTAssertTrue(pipeline.hasDecoder)
    XCTAssertEqual(pipeline.hardwareEvidence.mode, .hardware)
    pipeline.discardDecoder(); XCTAssertTrue(current.disposed)
  }

  private func samples(_ name: String, ext: String = "mkv") throws -> (YlSoftwareVideoConfiguration, CMVideoFormatDescription, [CMSampleBuffer]) {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    let prepared = try YlPreparedFallback(source: .init(uri: url.absoluteString, kind: .file, formatHint: .matroska), requireHardwareProbe: false)
    defer { prepared.discard() }
    var context: YLFMediaContextRef?; var info = YLFMediaInfo()
    XCTAssertEqual(ylf_open_local(url.path, &context, &info), 0)
    defer { ylf_close(&context) }
    let media = try XCTUnwrap(context)
    let configuration = try YlSoftwareVideoConfiguration(context: media, streamIndex: 0)
    var samples = [CMSampleBuffer]()
    while true {
      var packet: YLFPacketRef?
      if ylf_read_packet(media, &packet) != 0 { break }
      defer { ylf_packet_release(&packet) }
      guard let p = packet, ylf_packet_stream_index(p) == 0 else { continue }
      var sample: Unmanaged<CMSampleBuffer>?
      XCTAssertEqual(ylf_create_video_sample_buffer(&packet, prepared.videoFormat, &sample), 0)
      samples.append(try XCTUnwrap(sample).takeRetainedValue())
    }
    return (configuration, prepared.videoFormat, samples)
  }
  private func controlled(_ config: YlSoftwareVideoConfiguration, pool: YlSoftwareDecodePool,
      observe: YlSoftwareVideoDecoder.Observe? = nil, onFrame: @escaping (YlVideoFrame) -> Void,
      onError: @escaping (NativePlayerError) -> Void) throws -> YlSoftwareVideoDecoder {
    let pixel = config.descriptor.bit_depth == 10 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let key = config.key(model: "test", osBuild: "test", decoderBuild: "test", threads: 1, outputPixelFormat: pixel)
    let limits = YlSoftwareDecodeLimits(maxOwnedBytes: 32 * 1024 * 1024, maxFrames: 64,
      maxPacketBytes: 1024 * 1024, windowNs: 1_000_000, maxCpuNs: 1_000_000, maxDecodeWallNs: 1_000_000)
    var ticks: UInt64 = 0
    return try YlSoftwareVideoDecoder(configuration: config, key: key,
      admission: .init(entries: [key: limits]), pool: pool, maxInFlightBytes: 1024 * 1024,
      observe: observe ?? { _ in ticks += 1; return .init(monotonicNs: ticks, cumulativeCpuNs: ticks, decodeWallNs: 1, thermalNominal: true) },
      onFrame: onFrame, onError: onError)
  }
  func testActualAV1EightAndTenBitAfterDemuxClosed() throws {
    for (name, expected, pixel) in [("p03-av1-main8", 96, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                                  ("p03-av1-main10", 24, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)] {
      let (config, _, packets) = try samples(name)
      let pool = YlSoftwareDecodePool(); var count = 0; var pts = [Int64](); var errors = [NativePlayerError]()
      let decoder = try controlled(config, pool: pool, onFrame: {
        count += 1; pts.append($0.ptsUs)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType($0.pixelBuffer), pixel)
      }, onError: { errors.append($0) })
      XCTAssertEqual(decoder.hardwareEvidence.decoderName, "dav1d")
      for packet in packets { decoder.decode(sample: packet, generation: 1, reservation: nil) }
      decoder.drain(); decoder.dispose()
      XCTAssertEqual(count, expected); XCTAssertEqual(pts, pts.sorted()); XCTAssertTrue(errors.isEmpty, "\(errors)")
      XCTAssertEqual(pool.ownedBytes, 0)
    }
  }
  func testSeekRejectsLateGenerationAndRetainsOldImageCharge() throws {
    let (config, _, packets) = try samples("p03-webm-vp9-vorbis", ext: "webm")
    let first = try XCTUnwrap(packets.first); let pool = YlSoftwareDecodePool()
    var frames = [YlVideoFrame](); var errors = [NativePlayerError]()
    let decoder = try controlled(config, pool: pool, onFrame: { frames.append($0) }, onError: { errors.append($0) })
    decoder.decode(sample: first, generation: 4, reservation: nil)
    XCTAssertEqual(frames.map(\.generation), [4]); decoder.flush()
    XCTAssertGreaterThan(pool.ownedBytes, 0)
    decoder.decode(sample: first, generation: 4, reservation: nil)
    decoder.decode(sample: first, generation: 5, reservation: nil)
    XCTAssertEqual(frames.map(\.generation), [4,5]); decoder.dispose()
    XCTAssertGreaterThan(pool.ownedBytes, 0); frames.removeAll()
    XCTAssertEqual(pool.ownedBytes, 0); XCTAssertTrue(errors.isEmpty)
  }
  func testPostReceiveThermalFailureReleasesImageAndReportsOnce() throws {
    let (config, _, packets) = try samples("p03-webm-vp9-vorbis", ext: "webm")
    let first = try XCTUnwrap(packets.first); let pool = YlSoftwareDecodePool()
    var ticks: UInt64 = 0; var errors = [NativePlayerError](); var outputs = 0
    let decoder = try controlled(config, pool: pool, observe: { _ in
      ticks += 1
      return .init(monotonicNs: ticks, cumulativeCpuNs: ticks, decodeWallNs: 1, thermalNominal: ticks != 6)
    }, onFrame: { _ in outputs += 1 }, onError: { errors.append($0) })
    decoder.decode(sample: first, generation: 1, reservation: nil)
    decoder.decode(sample: first, generation: 1, reservation: nil)
    decoder.drain(); decoder.dispose()
    XCTAssertEqual(outputs, 0); XCTAssertEqual(errors.map(\.code), ["resource.exhausted"])
    XCTAssertEqual(pool.ownedBytes, 0)
  }

  private func services(_ configurations: [YlSoftwareVideoConfiguration], pool: YlSoftwareDecodePool) -> YlSoftwareDecodeServices {
    let identity = YlSoftwareDecodeIdentity(model: "test", osBuild: "test", decoderBuild: "test")
    let limits = YlSoftwareDecodeLimits(maxOwnedBytes: 64 * 1024 * 1024, maxFrames: 64,
      maxPacketBytes: 1024 * 1024, windowNs: 1_000_000, maxCpuNs: 1_000_000, maxDecodeWallNs: 1_000_000)
    var entries = [YlSoftwareDecodeKey: YlSoftwareDecodeLimits](); var ticks: UInt64 = 0
    for configuration in configurations {
      let pixel = configuration.descriptor.bit_depth == 10 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      entries[configuration.key(model: "test", osBuild: "test", decoderBuild: "test", threads: 1, outputPixelFormat: pixel)] = limits
    }
    var service = YlSoftwareDecodeServices()
    service.monitorProcess = false
    service.admission = .init(entries: entries); service.pool = pool; service.threads = 1
    service.identity = { identity }
    service.observe = { _ in ticks += 1; return .init(monotonicNs: ticks, cumulativeCpuNs: ticks, decodeWallNs: 1, thermalNominal: true) }
    return service
  }
  private func consume(_ media: YlOpenedMedia, pipeline: YlVideoPipeline, generation: UInt64,
                       hasAudio: Bool = false) throws {
    let context = try XCTUnwrap(media.context)
    while true {
      var packet: YLFPacketRef?
      if ylf_read_packet(context, &packet) != 0 { break }
      guard let owned = packet else { XCTFail("packet missing"); break }
      if ylf_packet_stream_index(owned) == 0 {
        _ = pipeline.consume(packet: &packet, ownedPacket: owned, generation: generation,
          hasAudio: hasAudio, compatibility: .current, shouldCancel: { false }, onSubmitted: {}, onCancelled: {})
      }
      ylf_packet_release(&packet)
    }
    pipeline.finishInput(generation: generation, hasAudio: hasAudio, compatibility: .current)
  }
  private func preparedFixture(_ name: String, ext: String = "mkv") throws -> YlPreparedFallback {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    return try YlPreparedFallback(source: .init(uri: url.absoluteString, kind: .file, formatHint: .matroska), requireHardwareProbe: false)
  }
  func testHiddenVP9SuperframesThroughActualPipelineAndEOS() async throws {
    let prepared = try preparedFixture("p03-vp9-hidden", ext: "webm"); defer { prepared.discard() }
    let config = try XCTUnwrap(prepared.softwareConfiguration), pool = YlSoftwareDecodePool()
    let pipeline = YlVideoPipeline(format: prepared.videoFormat,
      bufferBudget: try .make(configuration: .init(map: [:]), prepared: prepared),
      factory: NoSoftwareHardware(), softwareConfiguration: config, softwareServices: services([config], pool: pool))
    let output = SoftwarePipelineOutput(); pipeline.connect(output)
    try pipeline.initializeDecoder()
    let media = try prepared.takeMedia(); defer { media.close() }
    try consume(media, pipeline: pipeline, generation: 1)
    for _ in 0..<200 where !pipeline.isDrained { try await Task.sleep(nanoseconds: 10_000_000) }
    pipeline.cancelVideoSubmissions(); pipeline.discardDecoder()
    output.lock.withLock {
      XCTAssertEqual(output.pixels.count, 96); XCTAssertTrue(output.errors.isEmpty, "\(output.errors)")
      XCTAssertGreaterThan(pool.ownedBytes, 0); output.retained = nil
    }
    XCTAssertEqual(pool.ownedBytes, 0)
  }
  func testPeriodCandidateUsesItsOwnTenBitConfigurationAndRecreatesIt() async throws {
    let first = try preparedFixture("p03-av1-main8"), second = try preparedFixture("p03-av1-main10")
    defer { first.discard(); second.discard() }
    let a = try XCTUnwrap(first.softwareConfiguration), b = try XCTUnwrap(second.softwareConfiguration)
    let pool = YlSoftwareDecodePool()
    let pipeline = YlVideoPipeline(format: first.videoFormat,
      bufferBudget: try .make(configuration: .init(map: [:]), prepared: first),
      factory: NoSoftwareHardware(), softwareConfiguration: a, softwareServices: services([a,b], pool: pool))
    let output = SoftwarePipelineOutput(); pipeline.connect(output); try pipeline.initializeDecoder()
    let one = try first.takeMedia(), two = try second.takeMedia(); defer { one.close(); two.close() }
    try consume(one, pipeline: pipeline, generation: 1, hasAudio: true)
    for _ in 0..<200 where !pipeline.isDrained { try await Task.sleep(nanoseconds: 10_000_000) }
    let candidate = try pipeline.prepare(context: XCTUnwrap(two.context), streamIndex: 0)
    pipeline.install(candidate)?.dispose()
    // The independently owned candidate metadata must survive the source lifecycle.
    let recreated = try pipeline.prepareCurrent(); pipeline.install(recreated)?.dispose()
    try consume(two, pipeline: pipeline, generation: 2, hasAudio: true)
    for _ in 0..<200 where !pipeline.isDrained { try await Task.sleep(nanoseconds: 10_000_000) }
    pipeline.cancelVideoSubmissions(); pipeline.discardDecoder()
    output.lock.withLock {
      XCTAssertEqual(output.pixels, Array(repeating: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, count: 96)
        + Array(repeating: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, count: 24))
      XCTAssertTrue(output.errors.isEmpty, "\(output.errors)"); output.retained = nil
    }
    XCTAssertEqual(pool.ownedBytes, 0)
  }

  @MainActor func testActualSessionReportsDav1dIdentity() async throws {
    let template = try preparedFixture("p03-av1-main8"); defer { template.discard() }
    let config = try XCTUnwrap(template.softwareConfiguration), pool = YlSoftwareDecodePool()
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "p03-av1-main8", withExtension: "mkv"))
    let prepared = try YlPreparedFallback(source: .init(uri: url.absoluteString, kind: .file, formatHint: .matroska),
      requireHardwareProbe: false, softwareServices: services([config], pool: pool))
    var states = [YlNativeState]()
    let backend = try YlFallbackBackend(playerId: 994,
      services: .init(platform: .current, textureOutput: SoftwareTexture(), makeDisplayDriver: { _ in SoftwareDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: prepared, generation: 1,
      videoSessionFactory: NoSoftwareHardware(), emit: { if case .state(let state) = $0.event { states.append(state) } })
    defer { backend.dispose() }
    try backend.activate(); backend.emitState()
    let state = try XCTUnwrap(states.last)
    XCTAssertEqual(state.decoderName, "dav1d")
    XCTAssertEqual(state.decoderEvidence?.mode, .software)
    XCTAssertFalse(state.isHardwareDecoding)
  }

  func testDashPeriodUsesAdmittedSoftwareAndActualPixels() throws {
    let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "p03-av1-fragment", withExtension: "mp4"))
    let bytes = try Data(contentsOf: fixture); var split = 0
    while split + 8 <= bytes.count {
      let count = bytes[split..<(split + 4)].reduce(0) { ($0 << 8) | Int($1) }
      if String(decoding: bytes[(split + 4)..<(split + 8)], as: UTF8.self) == "moof" { break }
      guard count >= 8, count <= bytes.count - split else { XCTFail("invalid fixture box"); return }
      split += count
    }
    XCTAssertLessThan(split, bytes.count)
    let initialization = bytes.prefix(split), fragment = bytes.dropFirst(split)
    let url = URL(string: "https://owned.test/av1.mpd")!, token = YlOpenCancellationToken()
    let ledger = YlManagedBufferLedger(), scope = try ledger.makeScope(maxBytes: nil)
    let resources = YlDashProgramResources(source: url, headers: [:], credentials: [:], configuration: .init(map: [:]),
      factory: { request, emit in
        let body = request.url!.lastPathComponent == "i" ? Data(initialization) : Data(fragment)
        return SoftwareDashHop {
          emit(.headers(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(body.count)])!))
          emit(.body(body)); emit(.complete(nil))
        }
      }, reserve: { try scope.require(category: .compressedPackets, bytes: $0) })
    let xml = """
    <MPD mediaPresentationDuration="PT4S"><Period duration="PT4S"><AdaptationSet mimeType="video/mp4"><Representation id="v" codecs="av01.0.00M.08" bandwidth="350000" width="320" height="180"><SegmentTemplate initialization="i" media="s" duration="4"/></Representation></AdaptationSet></Period></MPD>
    """
    let program = try YlDashProgramDocument.parse(Data(xml.utf8), source: url, final: url)
    let prepared = try YlPreparedDashProgram(program: program, resources: resources, scope: scope, cancellation: token)
    defer { prepared.discard() }
    let period = try XCTUnwrap(prepared.takeInitial())
    let config = try XCTUnwrap(period.firstVideo.source.softwareConfiguration), pool = YlSoftwareDecodePool()
    var errors = [String]()
    let pipeline = try YlDashPeriodPlayback(prepared: period, generation: 1, scope: scope,
      policy: .hardwarePreferred, videoFactory: NoSoftwareHardware(), softwareServices: services([config], pool: pool),
      onError: { errors.append($0.code) })
    defer { pipeline.dispose() }
    XCTAssertEqual(pipeline.video.hardwareEvidence.decoderName, "dav1d")
    try pipeline.pump(cancellation: token)
    var frame = pipeline.scheduler.nextFrame(upTo: 0, generation: 1)
    XCTAssertNotNil(frame)
    if let payload = frame?.payload {
      let pixel = payload as! CVPixelBuffer
      CVPixelBufferLockBaseAddress(pixel, .readOnly)
      let y = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self)[0]
      XCTAssertEqual(Int(y), 81, accuracy: 4)
      CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
    }
    pipeline.dispose(); XCTAssertGreaterThan(pool.ownedBytes, 0)
    frame = nil; XCTAssertEqual(pool.ownedBytes, 0); XCTAssertTrue(errors.isEmpty, "\(errors)")
  }

  func testPausedDecoderKeepsBudgetObservationsUntilResume() async throws {
    let (config, _, packets) = try samples("p03-webm-vp9-vorbis", ext: "webm")
    let first = try XCTUnwrap(packets.first), pool = YlSoftwareDecodePool()
    let key = config.key(model: "test", osBuild: "test", decoderBuild: "test", threads: 1,
      outputPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let limits = YlSoftwareDecodeLimits(maxOwnedBytes: 32 * 1024 * 1024, maxFrames: 64,
      maxPacketBytes: 1024 * 1024, windowNs: 100_000_000, maxCpuNs: 100_000_000, maxDecodeWallNs: 100_000_000)
    let lock = NSLock(); var errors = [String](); var outputs = 0; var observations = 0
    let decoder = try YlSoftwareVideoDecoder(configuration: config, key: key,
      admission: .init(entries: [key: limits]), pool: pool, maxInFlightBytes: 1024 * 1024,
      observe: { _ in
        lock.withLock { observations += 1 }
        return .init(monotonicNs: DispatchTime.now().uptimeNanoseconds, cumulativeCpuNs: 0, decodeWallNs: 0, thermalNominal: true)
      }, monitoringIntervalNs: 10_000_000,
      onFrame: { _ in lock.withLock { outputs += 1 } }, onError: { error in lock.withLock { errors.append(error.code) } })
    try await Task.sleep(nanoseconds: 250_000_000)
    decoder.decode(sample: first, generation: 1, reservation: nil)
    decoder.dispose()
    lock.withLock { XCTAssertGreaterThan(observations, 6); XCTAssertEqual(outputs, 1); XCTAssertTrue(errors.isEmpty, "\(errors)") }
    XCTAssertEqual(pool.ownedBytes, 0)
  }

  func testCancellationAfterSoftwareCandidateCreationKeepsCurrentDecoder() async throws {
    let prepared = try preparedFixture("p03-av1-main8"); defer { prepared.discard() }
    let configuration = try XCTUnwrap(prepared.softwareConfiguration), pool = YlSoftwareDecodePool()
    var attempts = 0
    let pipeline = YlVideoPipeline(format: prepared.videoFormat,
      bufferBudget: try .make(configuration: .init(map: [:]), prepared: prepared),
      factory: NoSoftwareHardware(onAttempt: { attempts += 1 }), softwareConfiguration: configuration,
      softwareServices: services([configuration], pool: pool))
    let output = SoftwarePipelineOutput(); pipeline.connect(output); try pipeline.initializeDecoder()
    let media = try prepared.takeMedia(); defer { media.close() }
    XCTAssertThrowsError(try pipeline.prepare(context: XCTUnwrap(media.context), streamIndex: 0,
      checkCancellation: { if attempts > 1 { throw YlOpenCancellationToken.cancellationError() } })) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "network.cancelled")
    }
    XCTAssertEqual(attempts, 2); XCTAssertTrue(pipeline.hasDecoder)
    try consume(media, pipeline: pipeline, generation: 1)
    for _ in 0..<200 where !pipeline.isDrained { try await Task.sleep(nanoseconds: 10_000_000) }
    pipeline.cancelVideoSubmissions(); pipeline.discardDecoder()
    output.lock.withLock { XCTAssertEqual(output.pixels.count, 96); XCTAssertTrue(output.errors.isEmpty); output.retained = nil }
    XCTAssertEqual(pool.ownedBytes, 0)
  }

}
