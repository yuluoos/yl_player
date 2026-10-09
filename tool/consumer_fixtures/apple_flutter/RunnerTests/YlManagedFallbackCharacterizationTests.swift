@testable import yl_player_apple
import AVFoundation
import CoreVideo
import VideoToolbox
import XCTest
import YlFFmpegBridge
import Network

/// Characterizes the existing backend before its responsibilities move.
/// The real demux, decoder wrapper, clocks and renderer remain in the path;
/// only the platform VT session and display driver are controlled dependencies.
@MainActor
final class YlManagedFallbackCharacterizationTests: XCTestCase {
  private final class Session: YlVTSession {
    let usesHardwareDecoder = true
    var hardwareEvidence = YlHardwareDecoderEvidence(mode: .hardware)
    let output: (YlVTDecodedImage) -> Void
    let lock = NSLock()
    var automaticFrames = false
    var automaticFrameLimitUs: Int64?
    var submitted: [UInt64] = []
    var invalidations = 0
    var onInvalidate: (() -> Void)?
    init(output: @escaping (YlVTDecodedImage) -> Void) { self.output = output }
    func decode(_ sample: CMSampleBuffer, generation: UInt64,
                reservation: YlVideoDecodeReservation?) -> OSStatus {
      lock.withLock { submitted.append(generation) }
      let ptsUs = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 1_000_000, method: .default).value
      if automaticFrames && (automaticFrameLimitUs == nil || ptsUs <= automaticFrameLimitUs!) {
        var pixel: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, nil, &pixel)
        guard status == kCVReturnSuccess else { return status }
        output(YlVTDecodedImage(status: noErr, pixelBuffer: pixel,
          pts: CMSampleBufferGetPresentationTimeStamp(sample), duration: CMSampleBufferGetDuration(sample),
          keyframe: true, generation: generation, reservation: reservation, ownershipToken: nil))
      }
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
    var automaticFrames = false
    var automaticFrameLimitUs: Int64?
    var evidence = YlHardwareDecoderEvidence(mode: .hardware)
    var sessions = [Session]()
    var onCreate: (() -> Void)?
    var onInvalidate: (() -> Void)?
    func makeSession(formatDescription: CMVideoFormatDescription,
                     output: @escaping (YlVTDecodedImage) -> Void) throws -> YlVTSession {
      let session = Session(output: output); session.automaticFrames = automaticFrames; session.onInvalidate = onInvalidate
      session.automaticFrameLimitUs = automaticFrameLimitUs
      session.hardwareEvidence = evidence
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
    private let lock = NSLock()
    private var joinedWorker: DispatchQueue?
    var worker: DispatchQueue? { lock.withLock { joinedWorker } }
    let trace: Trace
    let releaseJoin = DispatchSemaphore(value: 0)
    let releaseSeek = DispatchSemaphore(value: 0)
    init(_ trace: Trace) { self.trace = trace }
    func interrupt(_ media: YlOpenedMedia) { trace.add("interrupt"); media.interruptRead() }
    func resume(_ media: YlOpenedMedia) { media.resumeReads(); trace.add("read.resume") }
    func join(_ worker: DispatchQueue, operation: () -> Void) {
      lock.withLock { joinedWorker = worker }
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
    func completeAll() {
      let pending = lock.withLock { () -> [() -> Void] in
        let values = storedCompletions; storedCompletions.removeAll(); return values
      }
      pending.forEach { $0() }
    }
    init(_ trace: Trace) { self.trace = trace }
    func configure(sampleRate: Double, channelCount: Int) throws {}
    func schedule(_ buffer: YlScheduledAudioBuffer, completion: @escaping () -> Void) {
      lock.withLock { storedCompletions.append(completion) }
    }
    var failPlay = false
    func play() throws {
      if failPlay { failPlay = false; throw NSError(domain: "audio-output", code: 1) }
      trace.add("audio.play")
    }
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

  private final class OpusRecordingConverter: YlAudioPacketConverting {
    let opus = YlOpusAudioConverter()
    let fallback = Converter(Trace())
    let lock = NSLock()
    var isOpus = false
    var rejectOpus = false
    private var entries: [(pts: Int64, target: Int64?, output: Int64?)] = []
    var observed: [(pts: Int64, target: Int64?, output: Int64?)] { lock.withLock { entries } }
    func configure(stream: YlAudioStreamConfiguration) throws {
      isOpus = stream.codec == .opus
      if isOpus {
        if rejectOpus { throw ylOpusUnsupportedError() }
        try opus.configure(stream: stream)
      } else { try fallback.configure(stream: stream) }
    }
    func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate {
      isOpus ? opus.estimateOutput(for: packet) : fallback.estimateOutput(for: packet)
    }
    func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer? {
      let value = try isOpus ? opus.convert(packet: packet) : fallback.convert(packet: packet)
      if isOpus { lock.withLock { entries.append((packet.ptsUs, packet.presentationStartUs, value?.ptsUs)) } }
      return value
    }
    func reset() { if isOpus { opus.reset() } else { fallback.reset() } }
  }
  private final class OpusAudioFactory: YlAudioRendererMaking {
    var rejectOpus = false
    var converters = [OpusRecordingConverter]()
    var outputs = [AudioOutput]()
    var renderers = [YlAudioRenderer]()
    func makeRenderer(bufferBudget: YlFallbackBufferBudget) -> YlAudioRenderer {
      let converter = OpusRecordingConverter(), output = AudioOutput(Trace())
      converter.rejectOpus = rejectOpus
      converters.append(converter); outputs.append(output)
      let renderer = YlAudioRenderer(bufferBudget: bufferBudget, converter: converter, output: output)
      renderers.append(renderer); return renderer
    }
  }
  private final class OpusSwitchControl: YlDemuxControlling {
    var targets = [Int64]()
    var beforeSeek: (() -> Void)?
    func interrupt(_ media: YlOpenedMedia) { media.interruptRead() }
    func resume(_ media: YlOpenedMedia) { media.resumeReads() }
    func join(_ worker: DispatchQueue, operation: () -> Void) { worker.sync(execute: operation) }
    func seek(_ media: YlOpenedMedia, toMediaTimeUs target: Int64) throws {
      targets.append(target); beforeSeek?()
      try media.seek(toMediaTimeUs: target)
    }
  }
  private func opusPrepared() throws -> YlPreparedFallback {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "opus_switch", withExtension: "mkv"))
    return try YlPreparedFallback(source: .init(uri: url.absoluteString, kind: .file, formatHint: .matroska), requireHardwareProbe: false)
  }
  func testOpusTrackSwitchRewindsAndTrimsRealPCMForEachColdDecoder() async throws {
    let video = Factory(), output = Output(), audio = OpusAudioFactory(), control = OpusSwitchControl()
    let clock = YlMediaClock(audioTime: { audio.renderers.last?.renderedAudioTime })
    video.automaticFrames = true
    var latest: YlNativeState?
    let instance = try YlFallbackBackend(playerId: 731,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in Display() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: opusPrepared(), generation: 17,
      videoSessionFactory: video, mediaClock: clock, audioRendererFactory: audio, demuxControl: control,
      emit: { if case .state(let state) = $0.event { latest = state } })
    defer { instance.dispose() }
    try instance.activate()
    try await AppleHostCharacterizations.waitFor { video.sessions[0].lastGeneration != nil }
    let old = video.sessions[0], oldGeneration = try XCTUnwrap(old.lastGeneration)
    for (track, target): (String, Int64) in [("audio-2", 1_250_000), ("audio-3", 1_500_000)] {
      try instance.pause(); clock.seek(to: target)
      try instance.selectAudioTrack(track)
      instance.emitState()
      XCTAssertEqual(control.targets.last, target)
      XCTAssertEqual(latest?.audioTracks.first(where: { $0.isSelected })?.id, track)
      XCTAssertEqual(latest?.status, "paused")
      XCTAssertEqual(latest?.positionMs, target / 1000)
      XCTAssertEqual(old.invalidations, 1)
      let converter = try XCTUnwrap(audio.converters.last)
      try instance.play()
      try await AppleHostCharacterizations.waitFor { converter.observed.contains { $0.output != nil } }
      let rows = converter.observed
      XCTAssertLessThanOrEqual(try XCTUnwrap(rows.first?.pts), target - 80_000)
      XCTAssertTrue(rows.allSatisfy { $0.target == target })
      XCTAssertTrue(rows.contains { $0.output == nil }, "Preroll must decode without presenting")
      let first = try XCTUnwrap(rows.compactMap { $0.output }.first)
      XCTAssertGreaterThanOrEqual(first, target)
      XCTAssertLessThan(first, target + 1_000, "First PCM must start at the target, not a later packet")
      try instance.pause()
      XCTAssertGreaterThanOrEqual(clock.position(atHostTimeUs: YlPresentationCoordinator.hostTimeUs()), target, "The media clock must anchor to trimmed PCM, not the compressed packet PTS")
      let decoderCount = video.sessions.count
      try instance.selectAudioTrack(track)
      XCTAssertEqual(video.sessions.count, decoderCount, "Same-track requests remain no-ops")
    }
    try instance.pause()
    let current = try XCTUnwrap(video.sessions.last)
    try await AppleHostCharacterizations.waitFor { current.lastGeneration != nil }
    let before = output.published
    try old.send(generation: oldGeneration, ptsUs: 1_500_000)
    await Task.yield()
    XCTAssertEqual(output.published, before, "Retired video cannot publish after audio switch rewind")
  }
  func testOpusTrackCandidateFailureKeepsCurrentRendererAndCursor() async throws {
    let audio = OpusAudioFactory(), video = Factory(), output = Output(), control = OpusSwitchControl()
    var latest: YlNativeState?
    let instance = try YlFallbackBackend(playerId: 731,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in Display() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: opusPrepared(), generation: 17,
      videoSessionFactory: video, audioRendererFactory: audio, demuxControl: control,
      emit: { if case .state(let state) = $0.event { latest = state } })
    defer { instance.dispose() }
    try instance.activate(); try instance.play()
    audio.rejectOpus = true
    XCTAssertThrowsError(try instance.selectAudioTrack("audio-2")) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "decoder.audio_opus_unsupported")
    }
    instance.emitState()
    XCTAssertEqual(latest?.audioTracks.first(where: { $0.isSelected })?.id, "audio-1")
    XCTAssertNil(latest?.error)
    XCTAssertTrue(instance.isActive); XCTAssertTrue(instance.playbackIntent)
    XCTAssertTrue(control.targets.isEmpty)
    XCTAssertEqual(video.sessions.count, 1)
    XCTAssertEqual(video.sessions[0].invalidations, 0)
  }
  func testInactiveOpusSwitchPreservesPreparedRendererUntilActivation() throws {
    let audio = OpusAudioFactory(), video = Factory(), output = Output()
    var latest: YlNativeState?
    let instance = try YlFallbackBackend(playerId: 731,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in Display() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: opusPrepared(), generation: 17,
      videoSessionFactory: video, audioRendererFactory: audio,
      emit: { if case .state(let state) = $0.event { latest = state } })
    defer { instance.dispose() }
    XCTAssertThrowsError(try instance.selectAudioTrack("audio-2")) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "policy.opus_track_switch_unsupported")
    }
    instance.emitState()
    XCTAssertEqual(latest?.audioTracks.first(where: { $0.isSelected })?.id, "audio-1")
    XCTAssertNil(latest?.error)
    XCTAssertEqual(audio.converters.count, 1)
    XCTAssertFalse(instance.isActive)
    try instance.activate()
    XCTAssertTrue(instance.isActive)
  }
  func testCancelledOpusSwitchAfterRewindCannotResumePartialPipeline() throws {
    let audio = OpusAudioFactory(), video = Factory(), output = Output(), control = OpusSwitchControl()
    let token = YlOpenCancellationToken()
    var latest: YlNativeState?
    let instance = try YlFallbackBackend(playerId: 731,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in Display() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: opusPrepared(), generation: 17,
      videoSessionFactory: video, audioRendererFactory: audio, demuxControl: control,
      emit: { if case .state(let state) = $0.event { latest = state } })
    defer { instance.dispose() }
    try instance.activate(); try instance.play()
    control.beforeSeek = { token.cancel() }
    XCTAssertThrowsError(try instance.selectAudioTrack("audio-2", cancellationToken: token)) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "network.cancelled")
    }
    XCTAssertEqual(control.targets.count, 1)
    instance.emitState()
    XCTAssertFalse(instance.isActive, "A interrupted cursor cannot resume with old decoder history")
    XCTAssertEqual(latest?.error?.code, "network.cancelled")
  }

  private final class TerminalPCM: YlAudioPacketConverting {
    let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)
    var trimUs: Int64 = 0
    var limitUs: Int64?
    func configure(stream: YlAudioStreamConfiguration) throws {}
    func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate { .init(durationUs: 21333, byteCount: 8192) }
    func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer? {
      if let limitUs, packet.ptsUs > limitUs { return nil }
      let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat!, frameCapacity: 1024)!
      pcm.frameLength = 1024
      return .init(payload: pcm, ptsUs: max(0, packet.ptsUs + trimUs), durationUs: 21333,
        byteCount: 8192, generation: packet.generation)
    }
  }
  private final class TerminalDriver: YlAudioOutputDriving {
    let supportsTerminalCompletion = true
    var volume: Float = 1; var rate: Float = 1
    private let lock = NSLock()
    private var entries: [(YlAudioOutputCompletionMode, YlAudioOutputCallbacks)] = []
    private var position: Int64 = 0
    private var invalidation: (() -> Void)?
    var modes: [YlAudioOutputCompletionMode] { lock.withLock { entries.map { $0.0 } } }
    var renderedAudioTime: YlRenderedAudioTime? { lock.withLock { .init(sampleTime: position, sampleRate: 1_000_000) } }
    func configure(sampleRate: Double, channelCount: Int) throws {}
    func setInvalidationHandler(_ handler: (() -> Void)?) { lock.withLock { invalidation = handler } }
    func invalidationCallback() -> (() -> Void)? { lock.withLock { invalidation } }
    func schedule(_ buffer: YlScheduledAudioBuffer, completion: @escaping () -> Void) { completion() }
    func schedule(_ buffer: YlScheduledAudioBuffer, mode: YlAudioOutputCompletionMode, callbacks: YlAudioOutputCallbacks) {
      lock.withLock { entries.append((mode, callbacks)); position = buffer.ptsUs + buffer.durationUs }
      if mode == .renderedResource { callbacks.resourcesReleased() }
    }
    func completeAll() {
      let callbacks = lock.withLock { entries.map { $0.1 } }
      callbacks.forEach { $0.playedBack() }
    }
    func play() throws {}
    func pause() {}
    func reset() {}
    func dispose() {}
  }
  private final class TerminalFactory: YlAudioRendererMaking {
    var renderers: [YlAudioRenderer] = []; var outputs: [TerminalDriver] = []
    let converter = TerminalPCM()
    func makeRenderer(bufferBudget: YlFallbackBufferBudget) -> YlAudioRenderer {
      let output = TerminalDriver()
      let renderer = YlAudioRenderer(bufferBudget: bufferBudget, converter: converter, output: output)
      outputs.append(output); renderers.append(renderer)
      return renderer
    }
  }
  private final class TerminalTimeline: YlAudioTimeline, YlAudioPipelineOutput {
    var anchors: [(Int64, Int64)] = []
    func anchorAudio(ptsUs: Int64, sampleTime: Int64) { anchors.append((ptsUs, sampleTime)) }
    func setDemuxPumping(_ value: Bool) {}
    func requestAudioPump() {}
    func requestAudioPump(after delay: TimeInterval) {}
    func fail(_ error: NativePlayerError) { XCTFail(error.code) }
  }
  private func terminalPrepared(network: Bool = false, bounded: Bool = false) throws -> (YlPreparedFallback, ReactivationMediaServer?) {
    let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "opus_switch", withExtension: "mkv"))
    let server = network ? try ReactivationMediaServer(data: Data(contentsOf: fixture)) : nil
    let plan = bounded ? try YlBoundedBufferPlan(minDurationMs: 0, maxDurationMs: 2000, maxBytes: 16 * 1024 * 1024) : nil
    let source = YlAppleSourceDescriptor(uri: (server?.url ?? fixture).absoluteString,
      kind: network ? .network : .file, formatHint: .matroska, boundedPlan: plan)
    return (try YlPreparedFallback(source: source, requireHardwareProbe: false), server)
  }

  func testTerminalSessionEligibilityUsesRecipeAndDefaultOptOut() throws {
    for (enabled, bounded, network) in [(false, false, false), (true, false, false), (true, true, false), (true, false, true)] {
      let (prepared, server) = try terminalPrepared(network: network, bounded: bounded)
      defer { server?.close() }
      let factory = TerminalFactory()
      let instance = try YlManagedPlaybackSession(playerId: 731,
        services: .init(platform: .current, textureOutput: Output(), makeDisplayDriver: { _ in Display() }),
        configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: prepared, generation: 17,
        videoSessionFactory: Factory(), audioRendererFactory: factory, emit: { _ in },
        audioTerminalCandidateEnabled: enabled)
      XCTAssertEqual(factory.renderers[0].usesSubmissionAnchor, enabled && !bounded && !network && YlApplePlatform.current == .macos)
      instance.dispose()
    }
  }

  func testTerminalPipelineAnchorsTrimmedFirstSubmissionAndIgnoresDetachedGeneration() async throws {
    let factory = TerminalFactory(); factory.converter.trimUs = 500
    let pipeline = YlAudioPipeline(bufferBudget: try .make(configuration: .init(map: [:])), lock: NSLock(), generation: 7,
      factory: factory, completionContext: .init(enabled: true, platform: .macos, localFiniteSeekable: true,
        hasBoundedPlan: false, codec: .aac, sampleRate: 48000, channels: 2, rate: 1))
    let timeline = TerminalTimeline(); pipeline.timeline = timeline; pipeline.output = timeline
    var stream = YLFStreamInfo(); stream.codec = Int32(YLFCodecAAC); stream.sample_rate = 48000; stream.channel_count = 2
    pipeline.initializeRenderer(); try pipeline.configureInitial(stream: stream, cookies: [:])
    defer { pipeline.discardRenderer() }
    _ = pipeline.enqueue(.init(data: Data(), ptsUs: 1000, durationUs: 21333, generation: 7), codecName: "AAC", onBackpressure: { _ in XCTFail() })
    XCTAssertTrue(timeline.anchors.isEmpty, "Held PCM cannot anchor video")
    _ = pipeline.enqueue(.init(data: Data(), ptsUs: 50000, durationUs: 21333, generation: 7), codecName: "AAC", onBackpressure: { _ in XCTFail() })
    for _ in 0..<100 where timeline.anchors.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
    XCTAssertEqual(timeline.anchors.first?.0, 1500); XCTAssertEqual(timeline.anchors.first?.1, 1500)
    let oldCallback = try XCTUnwrap(factory.renderers[0].onFirstPCMSubmitted)
    let old = pipeline.detach(); pipeline.adoptGeneration(8); pipeline.resetAnchor()
    pipeline.install(try pipeline.prepareTrack(stream: stream, generation: 8, cookies: [:]))
    oldCallback(7, 999999); old?.dispose()
    _ = pipeline.enqueue(.init(data: Data(), ptsUs: 70000, durationUs: 21333, generation: 8), codecName: "AAC", onBackpressure: { _ in XCTFail() })
    pipeline.finishInput() // EOF must use the same trimmed first-submission event.
    for _ in 0..<100 where timeline.anchors.count < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
    XCTAssertEqual(timeline.anchors.map { $0.0 }, [1500, 70500])
    let sameOwnerCallback = try XCTUnwrap(factory.renderers.last!.onFirstPCMSubmitted)
    pipeline.prepareReset(generation: 9).perform(); pipeline.resetAnchor()
    sameOwnerCallback(8, 999999)
    try await Task.sleep(nanoseconds: 10_000_000)
    XCTAssertEqual(timeline.anchors.count, 2)
    _ = pipeline.enqueue(.init(data: Data(), ptsUs: 80000, durationUs: 21333, generation: 9), codecName: "AAC", onBackpressure: { _ in XCTFail() })
    try pipeline.playInstalled() // The watchdog also enters the same trimmed anchor path.
    for _ in 0..<100 where timeline.anchors.count < 3 { try await Task.sleep(nanoseconds: 5_000_000) }
    XCTAssertEqual(timeline.anchors.map { $0.0 }, [1500, 70500, 80500])
    pipeline.setRate(2, hasAudio: true, updateTimeline: {})
    let third = try pipeline.prepareTrack(stream: stream, generation: 9, cookies: [:])
    let previous = pipeline.install(third); previous?.dispose()
    XCTAssertFalse(factory.renderers.last!.usesSubmissionAnchor, "Rebuild must use desired rate")
    pipeline.setRate(1, hasAudio: true, updateTimeline: {})
    stream.sample_rate = 44100
    let fourth = try pipeline.prepareTrack(stream: stream, generation: 10, cookies: [:])
    pipeline.install(fourth)?.dispose()
    XCTAssertFalse(factory.renderers.last!.usesSubmissionAnchor, "New track must use its actual format")
  }

  func testTerminalSessionDefaultAndTrackReplacementReevaluateEligibility() async throws {
    let (defaultPrepared, _) = try terminalPrepared()
    let defaultFactory = TerminalFactory()
    let defaultSession = try YlManagedPlaybackSession(playerId: 731,
      services: .init(platform: .current, textureOutput: Output(), makeDisplayDriver: { _ in Display() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: defaultPrepared, generation: 17,
      videoSessionFactory: Factory(), audioRendererFactory: defaultFactory, emit: { _ in })
    XCTAssertFalse(defaultFactory.renderers[0].usesSubmissionAnchor)
    defaultSession.dispose()
    let (prepared, _) = try terminalPrepared(); let streams = prepared.audioStreams
    let factory = TerminalFactory(); var failures: [String] = []
    let instance = try YlManagedPlaybackSession(playerId: 731,
      services: .init(platform: .macos, textureOutput: Output(), makeDisplayDriver: { _ in Display() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: prepared, generation: 17,
      videoSessionFactory: Factory(), audioRendererFactory: factory,
      emit: { if case let .failure(error) = $0.event { failures.append(error.code) } }, audioTerminalCandidateEnabled: true)
    defer { instance.dispose() }
    try instance.activate()
    let retiredInvalidation = try XCTUnwrap(factory.outputs[0].invalidationCallback())
    try instance.selectAudioTrack("audio-\(streams[1].index)", cancellationToken: nil)
    XCTAssertFalse(factory.renderers.last!.usesSubmissionAnchor)
    retiredInvalidation()
    try instance.selectAudioTrack("audio-\(streams[0].index)", cancellationToken: nil)
    XCTAssertTrue(factory.renderers.last!.usesSubmissionAnchor)
    try await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertTrue(failures.isEmpty)
  }

  func testTerminalSessionGraphInvalidationFailsOnceAndOldCallbackAfterSeekIsIgnored() async throws {
    let (prepared, _) = try terminalPrepared()
    let factory = TerminalFactory(); var failures: [String] = []
    let instance = try YlManagedPlaybackSession(playerId: 731,
      services: .init(platform: .macos, textureOutput: Output(), makeDisplayDriver: { _ in Display() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: prepared, generation: 17,
      videoSessionFactory: Factory(), audioRendererFactory: factory, emit: { if case let .failure(error) = $0.event { failures.append(error.code) } },
      audioTerminalCandidateEnabled: true)
    defer { instance.dispose() }
    try instance.activate()
    let old = try XCTUnwrap(factory.outputs[0].invalidationCallback())
    try instance.seek(toMs: 100, cancellationToken: nil)
    old()
    try await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertTrue(failures.isEmpty)
    let current = try XCTUnwrap(factory.outputs[0].invalidationCallback())
    current(); current()
    for _ in 0..<100 where failures.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
    XCTAssertEqual(failures, ["render.audio_engine_failed"])
    XCTAssertFalse(factory.renderers[0].hasPendingPlayback)
  }

  func testTerminalSessionEOFWaitsForAudioFenceThenCompletes() async throws {
    try await runTerminalEOF()
  }
  func testTerminalSessionCompletesWhenDecodedVideoOutlastsAudio() async throws {
    try await runTerminalEOF(audioLimitUs: 500000)
  }
  func testTerminalSessionCompletesWhenDecodedAudioOutlastsVideo() async throws {
    try await runTerminalEOF(videoLimitUs: 500000)
  }
  private func runTerminalEOF(audioLimitUs: Int64? = nil, videoLimitUs: Int64? = nil) async throws {
    let (prepared, _) = try terminalPrepared()
    let factory = TerminalFactory(), video = Factory(), display = BoundedDisplay(), output = Output()
    video.automaticFrames = true; video.automaticFrameLimitUs = videoLimitUs
    factory.converter.limitUs = audioLimitUs
    var completed = false; var failures: [String] = []
    let instance = try YlManagedPlaybackSession(playerId: 731,
      services: .init(platform: .macos, textureOutput: output, makeDisplayDriver: { display.tick = $0; return display }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: prepared, generation: 17,
      videoSessionFactory: video, audioRendererFactory: factory, emit: {
        if case let .state(state) = $0.event { completed = state.status == "completed" }
        if case let .failure(error) = $0.event { failures.append(error.code) }
      }, audioTerminalCandidateEnabled: true)
    defer { instance.dispose() }
    try instance.activate(); try instance.play()
    for _ in 0..<1000 where !factory.outputs[0].modes.contains(.playedBack) {
      try await Task.sleep(nanoseconds: 5_000_000); display.advance()
    }
    XCTAssertTrue(factory.outputs[0].modes.contains(.playedBack))
    XCTAssertFalse(completed, "Rendered-resource returns cannot complete the session")
    for _ in 0..<1000 where !completed && failures.isEmpty {
      factory.outputs[0].completeAll()
      try await Task.sleep(nanoseconds: 5_000_000); display.advance()
    }
    XCTAssertTrue(failures.isEmpty, "\(failures)")
    XCTAssertTrue(completed); XCTAssertGreaterThan(output.published, 0)
  }

  private func prepared(_ token: YlOpenCancellationToken? = nil, policy: YlDecoderPolicy? = nil) throws -> YlPreparedFallback {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mkv"))
    return try YlPreparedFallback(source: YlAppleSourceDescriptor(uri: url.absoluteString, kind: .file, formatHint: .matroska,
      loadOptions: policy.map { .init(decoderPolicy: $0) }),
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

  private final class VorbisRecordingConverter: YlAudioPacketConverting {
    let vorbis = YlVorbisAudioConverter()
    let fallback = Converter(Trace())
    let lock = NSLock()
    var isVorbis = false
    var rejectVorbis = false
    private var entries: [(pts: Int64, target: Int64?, output: Int64?)] = []
    var observed: [(pts: Int64, target: Int64?, output: Int64?)] { lock.withLock { entries } }
    func configure(stream: YlAudioStreamConfiguration) throws {
      isVorbis = stream.codec == .vorbis
      if isVorbis {
        if rejectVorbis { throw ylVorbisUnsupportedError() }
        try vorbis.configure(stream: stream)
      } else { try fallback.configure(stream: stream) }
    }
    func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate {
      isVorbis ? vorbis.estimateOutput(for: packet) : fallback.estimateOutput(for: packet)
    }
    func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer? {
      let value = try isVorbis ? vorbis.convert(packet: packet) : fallback.convert(packet: packet)
      if isVorbis { lock.withLock { entries.append((packet.ptsUs, packet.presentationStartUs, value?.ptsUs)) } }
      return value
    }
    func reset() { if isVorbis { vorbis.reset() } else { fallback.reset() } }
  }
  private final class VorbisAudioFactory: YlAudioRendererMaking {
    var rejectVorbis = false
    var converters = [VorbisRecordingConverter]()
    var outputs = [AudioOutput]()
    var renderers = [YlAudioRenderer]()
    func makeRenderer(bufferBudget: YlFallbackBufferBudget) -> YlAudioRenderer {
      let converter = VorbisRecordingConverter(), output = AudioOutput(Trace())
      converter.rejectVorbis = rejectVorbis
      converters.append(converter); outputs.append(output)
      let renderer = YlAudioRenderer(bufferBudget: bufferBudget, converter: converter, output: output)
      renderers.append(renderer); return renderer
    }
  }
  private final class VorbisSwitchControl: YlDemuxControlling {
    var targets = [Int64]()
    var beforeSeek: (() -> Void)?
    func interrupt(_ media: YlOpenedMedia) { media.interruptRead() }
    func resume(_ media: YlOpenedMedia) { media.resumeReads() }
    func join(_ worker: DispatchQueue, operation: () -> Void) { worker.sync(execute: operation) }
    func seek(_ media: YlOpenedMedia, toMediaTimeUs target: Int64) throws {
      targets.append(target); beforeSeek?()
      try media.seek(toMediaTimeUs: target)
    }
  }
  private func vorbisPrepared() throws -> YlPreparedFallback {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "vorbis_switch", withExtension: "mkv"))
    return try YlPreparedFallback(source: .init(uri: url.absoluteString, kind: .file, formatHint: .matroska), requireHardwareProbe: false)
  }
  func testVorbisTrackSwitchRewindsAndTrimsRealPCMForEachColdDecoder() async throws {
    let video = Factory(), output = Output(), audio = VorbisAudioFactory(), control = VorbisSwitchControl()
    let clock = YlMediaClock(audioTime: { audio.renderers.last?.renderedAudioTime })
    video.automaticFrames = true
    var latest: YlNativeState?
    let instance = try YlFallbackBackend(playerId: 731,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in Display() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: vorbisPrepared(), generation: 17,
      videoSessionFactory: video, mediaClock: clock, audioRendererFactory: audio, demuxControl: control,
      emit: { if case .state(let state) = $0.event { latest = state } })
    defer { instance.dispose() }
    try instance.activate()
    try await AppleHostCharacterizations.waitFor { video.sessions[0].lastGeneration != nil }
    let old = video.sessions[0], oldGeneration = try XCTUnwrap(old.lastGeneration)
    for (track, target): (String, Int64) in [("audio-2", 1_250_000), ("audio-3", 1_500_000)] {
      try instance.pause(); clock.seek(to: target)
      try instance.selectAudioTrack(track)
      instance.emitState()
      XCTAssertEqual(control.targets.last, target)
      XCTAssertEqual(latest?.audioTracks.first(where: { $0.isSelected })?.id, track)
      XCTAssertEqual(latest?.status, "paused")
      XCTAssertEqual(latest?.positionMs, target / 1000)
      XCTAssertEqual(old.invalidations, 1)
      let converter = try XCTUnwrap(audio.converters.last)
      try instance.play()
      try await AppleHostCharacterizations.waitFor { converter.observed.contains { $0.output != nil } }
      let rows = converter.observed
      XCTAssertLessThanOrEqual(try XCTUnwrap(rows.first?.pts), target - 200_000)
      XCTAssertTrue(rows.allSatisfy { $0.target == target })
      XCTAssertTrue(rows.contains { $0.output == nil }, "Preroll must decode without presenting")
      let first = try XCTUnwrap(rows.compactMap { $0.output }.first)
      XCTAssertGreaterThanOrEqual(first, target)
      XCTAssertLessThan(first, target + 1_000, "First PCM must start at the target, not a later packet")
      try instance.pause()
      XCTAssertGreaterThanOrEqual(clock.position(atHostTimeUs: YlPresentationCoordinator.hostTimeUs()), target, "The media clock must anchor to trimmed PCM, not the compressed packet PTS")
      let decoderCount = video.sessions.count
      try instance.selectAudioTrack(track)
      XCTAssertEqual(video.sessions.count, decoderCount, "Same-track requests remain no-ops")
    }
    try instance.pause()
    let current = try XCTUnwrap(video.sessions.last)
    try await AppleHostCharacterizations.waitFor { current.lastGeneration != nil }
    let before = output.published
    try old.send(generation: oldGeneration, ptsUs: 1_500_000)
    await Task.yield()
    XCTAssertEqual(output.published, before, "Retired video cannot publish after audio switch rewind")
  }
  func testVorbisTrackCandidateFailureKeepsCurrentRendererAndCursor() async throws {
    let audio = VorbisAudioFactory(), video = Factory(), output = Output(), control = VorbisSwitchControl()
    var latest: YlNativeState?
    let instance = try YlFallbackBackend(playerId: 731,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in Display() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: vorbisPrepared(), generation: 17,
      videoSessionFactory: video, audioRendererFactory: audio, demuxControl: control,
      emit: { if case .state(let state) = $0.event { latest = state } })
    defer { instance.dispose() }
    try instance.activate(); try instance.play()
    audio.rejectVorbis = true
    XCTAssertThrowsError(try instance.selectAudioTrack("audio-2")) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "decoder.audio_vorbis_unsupported")
    }
    instance.emitState()
    XCTAssertEqual(latest?.audioTracks.first(where: { $0.isSelected })?.id, "audio-1")
    XCTAssertNil(latest?.error)
    XCTAssertTrue(instance.isActive); XCTAssertTrue(instance.playbackIntent)
    XCTAssertTrue(control.targets.isEmpty)
    XCTAssertEqual(video.sessions.count, 1)
    XCTAssertEqual(video.sessions[0].invalidations, 0)
  }
  func testInactiveVorbisSwitchPreservesPreparedRendererUntilActivation() throws {
    let audio = VorbisAudioFactory(), video = Factory(), output = Output()
    var latest: YlNativeState?
    let instance = try YlFallbackBackend(playerId: 731,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in Display() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: vorbisPrepared(), generation: 17,
      videoSessionFactory: video, audioRendererFactory: audio,
      emit: { if case .state(let state) = $0.event { latest = state } })
    defer { instance.dispose() }
    XCTAssertThrowsError(try instance.selectAudioTrack("audio-2")) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "policy.vorbis_track_switch_unsupported")
    }
    XCTAssertThrowsError(try instance.selectAudioTrack("audio-2", cancellationToken: YlOpenCancellationToken())) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "policy.vorbis_track_switch_unsupported")
    }
    instance.emitState()
    XCTAssertEqual(latest?.audioTracks.first(where: { $0.isSelected })?.id, "audio-1")
    XCTAssertNil(latest?.error)
    XCTAssertEqual(audio.converters.count, 1)
    XCTAssertFalse(instance.isActive)
    try instance.activate()
    XCTAssertTrue(instance.isActive)
  }
  func testCancelledVorbisSwitchAfterRewindCannotResumePartialPipeline() throws {
    let audio = VorbisAudioFactory(), video = Factory(), output = Output(), control = VorbisSwitchControl()
    let token = YlOpenCancellationToken()
    var latest: YlNativeState?
    let instance = try YlFallbackBackend(playerId: 731,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in Display() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: vorbisPrepared(), generation: 17,
      videoSessionFactory: video, audioRendererFactory: audio, demuxControl: control,
      emit: { if case .state(let state) = $0.event { latest = state } })
    defer { instance.dispose() }
    try instance.activate(); try instance.play()
    control.beforeSeek = { token.cancel() }
    XCTAssertThrowsError(try instance.selectAudioTrack("audio-2", cancellationToken: token)) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "network.cancelled")
    }
    XCTAssertEqual(control.targets.count, 1)
    instance.emitState()
    XCTAssertFalse(instance.isActive, "A interrupted cursor cannot resume with old decoder history")
    XCTAssertEqual(latest?.error?.code, "network.cancelled")
  }

  private func vp9Format() throws -> CMVideoFormatDescription {
    var format: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
      codecType: kCMVideoCodecType_VP9, width: 320, height: 180, extensions: nil, formatDescriptionOut: &format), noErr)
    return try XCTUnwrap(format)
  }
  func testWebMVODRequiresCodecInspectionBeforeFallbackCommit() {
    for (uri, kind, route) in [
      ("file:///tmp/clip.webm", YlSourceKind.file, YlAppleSourceRoute.localMatroska),
      ("https://media.test/clip.webm", .network, .networkMatroska)
    ] {
      let source = YlAppleSourceDescriptor(uri: uri, kind: kind, intent: .onDemand)
      let assessment = YlEngineRouter.assess(source)
      XCTAssertEqual(assessment.outcome, .requiresInspection)
      XCTAssertEqual(assessment.candidate, route)
      XCTAssertNil(assessment.rejection)
      let rejected = YlEngineRouter.assess(source, inspection: .init(format: .webm,
        demuxerSupported: true, codecsSupported: false, hasVideo: true, hardwareAccelerated: nil))
      XCTAssertEqual(rejected.rejection?.code, "decoder.unsupported")
    }
  }

  func testVP9RejectsUnverifiedDecoderEvenWithoutRequiredPolicy() throws {
    for policy: YlDecoderPolicy in [.systemDefault, .hardwarePreferred, .hardwareRequired] {
      for mode: YlHardwareDecoderEvidence.Mode in [.software, .unknown] {
        let factory = Factory(); factory.evidence = .init(mode: mode)
        let pipeline = YlVideoPipeline(format: try vp9Format(), bufferBudget: try .make(configuration: .init(map: [:])),
          factory: factory, policy: policy)
        XCTAssertThrowsError(try pipeline.initializeDecoder()) {
          XCTAssertEqual(($0 as? NativePlayerError)?.code, "decoder.unavailable")
        }
        XCTAssertFalse(pipeline.hasDecoder)
        XCTAssertEqual(factory.sessions.first?.invalidations, 1)
      }
    }
  }
  func testVP9RecreationCannotFallBackToSoftware() throws {
    let factory = Factory()
    let pipeline = YlVideoPipeline(format: try vp9Format(), bufferBudget: try .make(configuration: .init(map: [:])), factory: factory)
    try pipeline.initializeDecoder()
    XCTAssertEqual(pipeline.hardwareEvidence.mode, .hardware)
    pipeline.discardDecoder(); factory.evidence = .init(mode: .software)
    XCTAssertThrowsError(try pipeline.prepareCurrent()) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "decoder.unavailable")
    }
    XCTAssertFalse(pipeline.hasDecoder)
    XCTAssertEqual(factory.sessions.last?.invalidations, 1)
  }

  func testHardwareEvidenceRequiresActualCFBooleanAndSafeIdentity() {
    let values: [(OSStatus, CFTypeRef?, YlHardwareDecoderEvidence.Mode)] = [
      (noErr, kCFBooleanTrue, .hardware), (noErr, kCFBooleanFalse, .software),
      (noErr, nil, .unknown), (-1, kCFBooleanTrue, .unknown),
      (noErr, NSNumber(value: 1), .unknown), (noErr, "true" as CFString, .unknown)
    ]
    for (status, value, expected) in values {
      let evidence = YlHardwareDecoderEvidence(status: status, value: value)
      XCTAssertEqual(evidence.mode, expected)
      XCTAssertEqual(evidence.decoderName, "VideoToolbox")
    }
  }

  func testRequiredPipelineRejectsSoftwareBeforeDecoderInstallation() throws {
    let candidate = try prepared(); defer { candidate.discard() }
    let factory = Factory(); factory.evidence = .init(mode: .software)
    let pipeline = YlVideoPipeline(format: candidate.videoFormat,
      bufferBudget: try .make(configuration: .init(map: [:]), prepared: candidate),
      factory: factory, policy: .hardwareRequired)
    XCTAssertThrowsError(try pipeline.initializeDecoder()) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "decoder.unavailable")
    }
    XCTAssertFalse(pipeline.hasDecoder)
    XCTAssertEqual(factory.sessions.first?.invalidations, 1)
  }

  func testRequiredPipelineRecreationRejectsUnknownBeforeInstall() throws {
    let candidate = try prepared(); defer { candidate.discard() }
    let factory = Factory()
    let pipeline = YlVideoPipeline(format: candidate.videoFormat,
      bufferBudget: try .make(configuration: .init(map: [:]), prepared: candidate),
      factory: factory, policy: .hardwareRequired)
    try pipeline.initializeDecoder()
    XCTAssertEqual(pipeline.hardwareEvidence.mode, .hardware)
    pipeline.discardDecoder()
    factory.evidence = .unknown
    XCTAssertThrowsError(try pipeline.prepareCurrent()) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "decoder.unavailable")
    }
    XCTAssertFalse(pipeline.hasDecoder)
    XCTAssertEqual(factory.sessions.last?.invalidations, 1)
  }

  func testStrictInspectedFormatRecreationRejectsSoftware() throws {
    let candidate = try prepared(); defer { candidate.discard() }
    let media = try candidate.takeMedia(); defer { media.close() }
    let factory = Factory(); factory.evidence = .init(mode: .software)
    let pipeline = YlVideoPipeline(format: candidate.videoFormat,
      bufferBudget: try .make(configuration: .init(map: [:]), prepared: candidate),
      factory: factory, policy: .hardwareRequired)
    XCTAssertThrowsError(try pipeline.prepare(context: XCTUnwrap(media.context), streamIndex: candidate.videoStream.index)) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "decoder.unavailable")
    }
    XCTAssertFalse(pipeline.hasDecoder)
    XCTAssertEqual(factory.sessions.last?.invalidations, 1)
  }

  func testPreferredPipelineAllowsUnknownWithoutClaimingHardware() throws {
    let candidate = try prepared(); defer { candidate.discard() }
    let factory = Factory(); factory.evidence = .unknown
    let pipeline = YlVideoPipeline(format: candidate.videoFormat,
      bufferBudget: try .make(configuration: .init(map: [:]), prepared: candidate),
      factory: factory, policy: .hardwarePreferred)
    try pipeline.initializeDecoder(); defer { pipeline.discardDecoder() }
    XCTAssertEqual(pipeline.hardwareEvidence.mode, .unknown)
    XCTAssertEqual(pipeline.usesHardwareDecoder, false)
  }

  private func hardwareRequest(_ id: String, policy: AppleDecoderPolicy = .hardwareRequired) throws -> AppleLoadRequest {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mkv"))
    var request = AppleHostFixture.request(id, url: url.absoluteString, format: .matroska)
    request.source.kind = .file; request.source.locator = url.path
    request.options.decoderPolicyOverride = policy
    return request
  }

  func testManagedAudioAutoplayPreparationFailureAndRetiredBackendCleanup() async throws {
    let driver = YlAudioOwnershipTests.Driver()
    let shared = YlAudioOwnershipCoordinator(driver: driver)
    let owner = YlPlayerAudioOwnership(coordinator: shared, key: .init(registry: UUID(), player: "managed"))
    let factory = Factory()
    let f = AppleHostFixture(videoSessionFactory: factory, audioOwnership: owner)
    defer { f.host.close() }
    factory.onCreate = { XCTAssertTrue(driver.calls.isEmpty, "Private VT evidence must not activate audio") }
    var request = try hardwareRequest("owned"); request.options.autoplay = true
    let accepted = try await f.load(request)
    XCTAssertEqual(driver.calls, ["configure", "activate"])
    XCTAssertEqual(shared.ownerCount, 1)
    factory.onCreate = nil
    factory.evidence = .unknown
    do { _ = try await f.load(hardwareRequest("reject")); XCTFail("Strict replacement must reject") } catch {}
    XCTAssertEqual(f.host.sessionId, accepted.sessionId)
    XCTAssertEqual(shared.ownerCount, 1)
    XCTAssertEqual(driver.calls, ["configure", "activate"])
    let retired = factory.sessions[0]
    // Hold the current AV input locally: an unrelated TLS/DNS failure from the
    // default placeholder URL would legitimately release its current lease.
    let heldAV = try AppleHeldMediaServer(onRequest: {})
    defer { heldAV.close() }
    let heldAVURL = heldAV.url.deletingLastPathComponent().appendingPathComponent("active.mp4")
    _ = try await f.load(AppleHostFixture.request("av", url: heldAVURL.absoluteString, autoplay: true))
    try retired.send(generation: retired.lastGeneration ?? 1, status: -1)
    await f.settle()
    XCTAssertNil(f.host.initialState.failure, "Current input must remain healthy during retired-callback isolation")
    XCTAssertEqual(shared.ownerCount, 1, "Retiring the fallback or its delayed failure cannot release the AV session lease")
    try await f.host.stop()
    XCTAssertEqual(shared.ownerCount, 0)
    XCTAssertEqual(driver.calls.last, "deactivate.notifyOthers")
  }

  func testManagedAudioActivationFailureBeforeReplacementPreservesAcceptedFallback() async throws {
    let driver = YlAudioOwnershipTests.Driver()
    let shared = YlAudioOwnershipCoordinator(driver: driver)
    let owner = YlPlayerAudioOwnership(coordinator: shared, key: .init(registry: UUID(), player: "managed"))
    let factory = Factory()
    let f = AppleHostFixture(videoSessionFactory: factory, audioOwnership: owner)
    defer { f.host.close() }
    let accepted = try await f.load(hardwareRequest("paused"))
    XCTAssertTrue(driver.calls.isEmpty)
    driver.failActivation = true
    do { _ = try await f.load(AppleHostFixture.request("rejected-av", autoplay: true)); XCTFail("Audio activation must reject") } catch {}
    XCTAssertEqual(f.host.sessionId, accepted.sessionId)
    XCTAssertEqual(factory.sessions.first?.invalidations, 0, "Reject before disposing accepted decoder")
    XCTAssertEqual(shared.ownerCount, 0)
    driver.failActivation = false
    try await f.host.play(command: .init(sessionId: accepted.sessionId))
    XCTAssertEqual(shared.ownerCount, 1)
    XCTAssertEqual(f.host.initialState.engine, .managedFallback)
  }

  func testAudioOutputStartFailurePublishesTerminalFailure() async throws {
    let audio = AudioFactory(Trace()), factory = Factory()
    var failures = [NativePlayerError]()
    let instance = try YlFallbackBackend(playerId: 732,
      services: .init(platform: .current, textureOutput: Output(), makeDisplayDriver: { _ in Display() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: prepared(),
      generation: 1, videoSessionFactory: factory, audioRendererFactory: audio,
      emit: { if case let .failure(error) = $0.event { failures.append(error) } })
    defer { instance.dispose() }
    try instance.activate()
    audio.output.failPlay = true
    XCTAssertThrowsError(try instance.play())
    for _ in 0..<16 { await Task.yield() }
    XCTAssertEqual(failures.map(\.code), ["render.audio_engine_failed"])
    XCTAssertFalse(instance.playbackIntent)
  }

  func testManagedAudioTerminalOutputFailureReleasesCurrentLeaseExactlyOnce() async throws {
    let driver = YlAudioOwnershipTests.Driver()
    let shared = YlAudioOwnershipCoordinator(driver: driver)
    let owner = YlPlayerAudioOwnership(coordinator: shared, key: .init(registry: UUID(), player: "failure"))
    let factory = Factory()
    let f = AppleHostFixture(videoSessionFactory: factory, audioOwnership: owner)
    defer { f.host.close() }
    var request = try hardwareRequest("fail"); request.options.autoplay = true
    _ = try await f.load(request)
    try await AppleHostCharacterizations.waitFor { factory.sessions[0].lastGeneration != nil }
    let session = factory.sessions[0]
    try session.send(generation: XCTUnwrap(session.lastGeneration), status: -1)
    try await AppleHostCharacterizations.waitFor { f.host.initialState.failure != nil }
    XCTAssertEqual(shared.ownerCount, 0)
    try await f.host.stop(); f.host.close()
    XCTAssertEqual(driver.calls, ["configure", "activate", "deactivate.notifyOthers"])
  }

  func testStrictHostTransfersExactProvenDecoderBeforeCommitAndFirstFrameOnce() async throws {
    let factory = Factory()
    let f = AppleHostFixture(videoSessionFactory: factory); defer { f.host.close() }
    try f.host.attach()
    var publicCommitCount = 0
    f.host.willCommit = { _ in
      publicCommitCount += 1
      XCTAssertEqual(factory.sessions.count, 1)
      XCTAssertTrue(f.output.frames.isEmpty)
      XCTAssertTrue(f.callbacks.frames.isEmpty)
    }
    let reply = try await f.load(hardwareRequest("positive"))
    XCTAssertEqual(publicCommitCount, 1)
    XCTAssertEqual(factory.sessions.count, 1, "Commit must adopt the exact proven decoder")
    await f.settle()
    let published = f.callbacks.states.filter { $0.sessionId == reply.sessionId }
    XCTAssertFalse(published.isEmpty)
    XCTAssertTrue(published.allSatisfy { $0.decoderMode == .hardware }, "Strict public commit must never expose an unknown placeholder")
    XCTAssertEqual(f.host.initialState.decoderMode, .hardware)
    XCTAssertEqual(f.host.initialState.geometry?.displaySize.width, 320)
    XCTAssertEqual(f.host.initialState.geometry?.displaySize.height, 180)
    XCTAssertEqual(f.host.initialState.geometry?.encodedSize.width, 320)
    XCTAssertEqual(f.host.initialState.geometry?.encodedSize.height, 180)
    XCTAssertEqual(f.host.initialState.geometry?.pixelAspectRatio, 1)
    XCTAssertEqual(f.host.initialState.geometry?.rotationDegrees, 0)
    XCTAssertEqual(f.host.sessionId, reply.sessionId)
    try await AppleHostCharacterizations.waitFor { factory.sessions[0].lastGeneration != nil }
    try factory.sessions[0].send(generation: XCTUnwrap(factory.sessions[0].lastGeneration))
    try await AppleHostCharacterizations.waitFor { f.callbacks.frames.count == 1 }
    try f.host.seekTo(command: .init(sessionId: reply.sessionId, positionMs: 0))
    try await AppleHostCharacterizations.waitFor { factory.sessions.count == 2 }
    XCTAssertEqual(factory.sessions.count, 2)
    try await AppleHostCharacterizations.waitFor { factory.sessions[1].lastGeneration != nil }
    try factory.sessions[1].send(generation: XCTUnwrap(factory.sessions[1].lastGeneration))
    await f.settle()
    XCTAssertEqual(f.callbacks.frames.count, 1)
  }

  func testStrictSoftwareAndUnknownCandidatesPreserveAcceptedSession() async throws {
    for mode: YlHardwareDecoderEvidence.Mode in [.software, .unknown] {
      let factory = Factory(); factory.evidence = .init(mode: mode)
      let f = AppleHostFixture(videoSessionFactory: factory); defer { f.host.close() }
      let old = try await f.load(AppleHostFixture.request("old"))
      let item = f.av.currentItem
      try f.host.setVolume(volume: 0.3)
      var commits = 0
      f.host.willCommit = { _ in commits += 1 }
      do { _ = try await f.load(hardwareRequest("rejected")); XCTFail("Nonhardware candidate committed") }
      catch { XCTAssertEqual((error as NSError).domain, "decoder.unavailable") }
      XCTAssertEqual(commits, 0)
      XCTAssertEqual(f.host.sessionId, old.sessionId)
      XCTAssertTrue(f.av.currentItem === item)
      XCTAssertEqual(f.av.volume, 0.3, accuracy: 0.001)
      XCTAssertFalse(f.host.playbackIntent)
      XCTAssertEqual(factory.sessions.last?.invalidations, 1)
    }
  }

  func testPreferredHostCommitsUnknownAndSoftwareHonestly() async throws {
    for mode: YlHardwareDecoderEvidence.Mode in [.unknown, .software] {
      let factory = Factory(); factory.evidence = .init(mode: mode)
      let f = AppleHostFixture(videoSessionFactory: factory); defer { f.host.close() }
      _ = try await f.load(hardwareRequest("preferred", policy: .hardwarePreferred))
      XCTAssertEqual(f.host.initialState.decoderMode, mode == .software ? .software : .unknown)
    }
  }

  func testStrictCommittedSeekRejectsRecreatedSoftwareAndLateFrames() async throws {
    let factory = Factory(), output = Output()
    let instance = try backend(prepared(policy: .hardwareRequired), factory: factory, output: output)
    defer { instance.dispose() }
    try instance.activate()
    try await AppleHostCharacterizations.waitFor { factory.sessions[0].lastGeneration != nil }
    let old = factory.sessions[0], oldGeneration = try XCTUnwrap(factory.sessions[0].lastGeneration)
    factory.evidence = .init(mode: .software)
    XCTAssertThrowsError(try instance.seek(toMs: Int64(0), cancellationToken: nil)) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "decoder.unavailable")
    }
    XCTAssertEqual(factory.sessions.last?.invalidations, 1)
    try old.send(generation: oldGeneration)
    await Task.yield()
    XCTAssertEqual(output.published, 0)
  }

  func testRealHardwareRequiredFixtureCommitsHardwareOrTruthfullyRejects() async throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    do {
      _ = try await f.load(hardwareRequest("real-hardware-policy"))
      XCTAssertEqual(f.host.initialState.decoderMode, .hardware)
      let attachment = XCTAttachment(string: "Actual VT hardwareRequired commit; decoderMode=hardware. Simulator is policy evidence only.")
      attachment.name = "Task5-real-hardware-policy"; attachment.lifetime = .keepAlways; add(attachment)
    } catch {
      XCTAssertEqual((error as NSError).domain, "decoder.unavailable")
      XCTAssertNil(f.host.sessionId)
      let attachment = XCTAttachment(string: "Actual VT hardwareRequired rejected decoder.unavailable; no hardware performance claim.")
      attachment.name = "Task5-real-hardware-policy"; attachment.lifetime = .keepAlways; add(attachment)
    }
  }

  private final class EvidenceClock {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    private var timeout: (() -> Void)?
    func now() -> TimeInterval { lock.withLock { time } }
    func schedule(_ seconds: TimeInterval, _ action: @escaping () -> Void) -> (() -> Void) {
      XCTAssertEqual(seconds, 5)
      lock.withLock { timeout = action }
      return { [weak self] in self?.lock.withLock { self?.timeout = nil } }
    }
    func expire() {
      let action = lock.withLock { () -> (() -> Void)? in time += 5; return timeout }
      action?()
    }
  }

  func testEvidenceDeadlineRetainsLatePayloadAndRejectsSecondProbeUntilNativeReturn() async throws {
    try await heldEvidence(cancel: false)
  }
  func testEvidenceCancellationRetainsLatePayloadAndNeverAcceptsLateSuccess() async throws {
    try await heldEvidence(cancel: true)
  }
  private func heldEvidence(cancel: Bool) async throws {
    final class Payload {
      let token: YlManagedBufferLedger.Token
      init(_ token: YlManagedBufferLedger.Token) { self.token = token }
    }
    let clock = EvidenceClock()
    let stage = YlHardwareEvidencePreparation(now: clock.now, schedule: clock.schedule)
    let token = YlOpenCancellationToken(), ledger = YlManagedBufferLedger()
    let scope = try ledger.makeScope(maxBytes: 1024)
    let entered = expectation(description: "actual retained native work")
    let finished = expectation(description: "authority completed before native return")
    let discarded = expectation(description: "late owner discarded on actual return")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    DispatchQueue.global().async {
      do {
        _ = try stage.run(token: token, work: {
          let payload = Payload(try XCTUnwrap(scope.reserve(category: .compressedPackets, bytes: 128)))
          entered.fulfill(); _ = release.wait(timeout: .now() + 10); return payload
        }, discard: { _ in discarded.fulfill() })
        XCTFail("Late result acquired authority")
      } catch {
        XCTAssertEqual((error as? NativePlayerError)?.code, cancel ? "network.cancelled" : "decoder.unavailable")
      }
      finished.fulfill()
    }
    await fulfillment(of: [entered], timeout: 2)
    if cancel { token.cancel() } else { clock.expire() }
    await fulfillment(of: [finished], timeout: 2)
    XCTAssertEqual(ledger.snapshot.currentBytes, 128)
    let busy = expectation(description: "second probe rejects without a new worker")
    DispatchQueue.global().async {
      do {
        let _: Int = try stage.run(token: .init(), work: { XCTFail("Overlapping work started"); return 1 }, discard: { (_: Int) in })
        XCTFail("Overlapping probe admitted")
      } catch { XCTAssertEqual((error as? NativePlayerError)?.code, "decoder.unavailable") }
      busy.fulfill()
    }
    await fulfillment(of: [busy], timeout: 2)
    release.signal()
    await fulfillment(of: [discarded], timeout: 2)
    try await AppleHostCharacterizations.waitFor { ledger.snapshot.currentBytes == 0 }
  }

  func testInjectedPropertyReaderPreservesCompatibleKeyAndCFType() {
    for value: CFTypeRef in [kCFBooleanTrue!, kCFBooleanFalse!, NSNumber(value: 1)] {
      let reader = YlVTSessionPropertyReader(copy: { _, key, output in
        XCTAssertEqual(key as String, "UsingHardwareAcceleratedVideoDecoder")
        output = value; return noErr
      })
      // The reader is injected; the opaque handle is never passed to native VT.
      let evidence = reader.evidence(for: kCFBooleanTrue)
      XCTAssertEqual(evidence.mode, CFGetTypeID(value) != CFBooleanGetTypeID() ? .unknown : (CFEqual(value, kCFBooleanTrue) ? .hardware : .software))
    }
  }

  func testStrictHostDeadlineCannotCommitLateProvenDecoder() async throws {
    let clock = EvidenceClock(), factory = Factory()
    let entered = expectation(description: "candidate native factory held")
    let returned = expectation(description: "native candidate invalidated after actual return")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    factory.onCreate = { entered.fulfill(); _ = release.wait(timeout: .now() + 10) }
    factory.onInvalidate = { returned.fulfill() }
    let stage = YlHardwareEvidencePreparation(now: clock.now, schedule: clock.schedule)
    let f = AppleHostFixture(videoSessionFactory: factory, hardwareEvidenceStage: stage)
    defer { f.host.close() }
    let old = try await f.load(AppleHostFixture.request("old"))
    let item = f.av.currentItem
    var commits = 0
    f.host.willCommit = { _ in commits += 1 }
    let request = try hardwareRequest("late-positive")
    let loading = Task { try await f.load(request) }
    await fulfillment(of: [entered], timeout: 2)
    clock.expire()
    do { _ = try await loading.value; XCTFail("Deadline candidate committed") }
    catch { XCTAssertEqual((error as NSError).domain, "decoder.unavailable") }
    XCTAssertEqual(factory.sessions[0].invalidations, 0)
    XCTAssertEqual(f.host.sessionId, old.sessionId)
    XCTAssertTrue(f.av.currentItem === item)
    release.signal()
    await fulfillment(of: [returned], timeout: 2)
    await f.settle()
    XCTAssertEqual(commits, 0)
    XCTAssertEqual(factory.sessions[0].invalidations, 1)
    XCTAssertEqual(f.host.sessionId, old.sessionId)
  }

  func testStrictHostReplacementRespectsPlatformDecoderPermit() async throws {
    let factory = Factory()
    let f = AppleHostFixture(videoSessionFactory: factory); defer { f.host.close() }
    let old = try await f.load(hardwareRequest("old-hardware"))
    var commits = 0
    f.host.willCommit = { _ in commits += 1 }
    if YlAppleCompatibility.current.limitsVideoReservations {
      do { _ = try await f.load(hardwareRequest("busy")); XCTFail("Second scarce permit acquired") }
      catch { XCTAssertEqual((error as NSError).domain, "decoder.unavailable") }
      XCTAssertEqual(commits, 0)
      XCTAssertEqual(f.host.sessionId, old.sessionId)
      XCTAssertEqual(factory.sessions.count, 1)
      XCTAssertEqual(factory.sessions[0].invalidations, 0)
    } else {
      let replacement = try await f.load(hardwareRequest("coexisting"))
      XCTAssertEqual(commits, 1)
      XCTAssertNotEqual(replacement.sessionId, old.sessionId)
      XCTAssertEqual(f.host.sessionId, replacement.sessionId)
      XCTAssertEqual(factory.sessions.count, 2)
      XCTAssertEqual(factory.sessions[0].invalidations, 1)
    }
    XCTAssertEqual(f.host.initialState.decoderMode, .hardware)
    XCTAssertFalse(f.host.playbackIntent)
  }

  func testAudioOnlyFallbackRejectsActualUnsupportedRouteBeforeHardwareProbe() throws {
    // 624-byte AAC-LC Matroska: ffmpeg anullsrc 48k stereo, 50ms, AAC.
    // This is an actual audio-only demux input, not a video-evidence rejection.
    let bytes = Data(base64Encoded: "GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAACPBFNm3TAv4QP11p3TbuLU6uEFUmpZlOsgaFNu4tTq4QWVK5rU6yB7027jFOrhBJUw2dTrIIBTk27jFOrhBxTu2tTrIICIOwBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsm/hCJ4+sIq17GDD0JATYCMTGF2ZjYyLjMuMTAwV0GMTGF2ZjYyLjMuMTAwc6SQudSwHc6PsCoj/Cb6H1kIPUSJiEBRwAAAAAAAFlSua9q/hBSGLoquAQAAAAAAAEvXgQFzxYgiBWUlNB3T35yBACK1nIN1bmSIgQCGhUFfQUFDVqqEAUWFVYOBAuGRn4ECtYhA53AAAAAAAGJkgSBV7oEAY6KFEZBW5QASVMNn/r+EIJ0GuXNzn2PAgGfImUWjh0VOQ09ERVJEh4xMYXZmNjIuMy4xMDBzc9NjwItjxYgiBWUlNB3T32fInkWjh0VOQ09ERVJEh5FMYXZjNjIuMTEuMTAwIGFhY2fIoUWjiERVUkFUSU9ORIeTMDA6MDA6MDAuMDcxMDAwMDAwAB9DtnXKv4RSlaYJ54EAo5uBAACA3gIATGF2YzYyLjExLjEwMABCIAjBGDijioEAFYAhEARgjByjioEAKoAhEARgjByjioEAQIAhEARgjBwcU7trl7+ED3V4pruPs4EAt4r3gQHxggHR8IEJ")!
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mka")
    try bytes.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
    let source = YlAppleSourceDescriptor(uri: file.absoluteString, kind: .file,
      formatHint: .matroska, loadOptions: .init(decoderPolicy: .hardwareRequired))
    XCTAssertThrowsError(try YlPreparedFallback(source: source, requireHardwareProbe: false)) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "policy.unsupported")
      XCTAssertEqual(($0 as? NativePlayerError)?.category, "unsupported")
    }
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
    let currentVideo = try XCTUnwrap(factory.sessions.last)
    try await AppleHostCharacterizations.waitFor { currentVideo.lastGeneration != nil }
    let currentGeneration = try XCTUnwrap(currentVideo.lastGeneration)
    try instance.pause()
    // Once video has prebuffered, paused pumpOne admits no new packets. Drain
    // the actual demux turn that may already have passed its playing check.
    try XCTUnwrap(control.worker).sync {}
    XCTAssertEqual(try renderer.enqueue(packet: YlCompressedAudioPacket(data: Data([1]),
      ptsUs: 0, durationUs: 20_000, generation: oldGeneration)), .staleGeneration)
    let scheduledAfterSeek = renderer.scheduledBytes
    for completion in oldCompletions { completion() }
    XCTAssertEqual(renderer.scheduledBytes, scheduledAfterSeek, "Pre-seek completions cannot consume new audio")
    XCTAssertEqual(oldVideo.invalidations, 1)
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

extension YlManagedFallbackCharacterizationTests {
  /// A finite repository FLV prefix on an intentionally still-open live body.
  /// Immediate EOF means reconnect for FLV, unlike Matroska VOD completion.
  private final class StreamingFLVServer {
    private final class State { var connections = [NWConnection]() }
    private let state = State()
    private let queue = DispatchQueue(label: "yl.test.strict-flv-live-body")
    private let listener: NWListener
    let url: URL
    init(data: Data) throws {
      listener = try NWListener(using: .tcp, on: .any)
      let ready = DispatchSemaphore(value: 0), queue = self.queue, state = self.state
      listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
      listener.newConnectionHandler = { connection in
        // All connection collection accesses are serialized on this queue.
        state.connections.append(connection); connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { bytes, _, _, _ in
          guard let bytes, !bytes.isEmpty else { connection.cancel(); return }
          let headers = "HTTP/1.1 200 OK\r\nContent-Type: video/x-flv\r\nContent-Length: \(data.count + 1)\r\nConnection: close\r\n\r\n"
          connection.send(content: Data(headers.utf8) + data, completion: .contentProcessed { _ in })
        }
      }
      listener.start(queue: queue)
      guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
        listener.cancel(); throw NSError(domain: "StrictFixtureServer", code: 1)
      }
      url = URL(string: "http://127.0.0.1:\(port.rawValue)/fixture.flv")!
    }
    func close() { listener.cancel(); queue.sync { state.connections.forEach { $0.cancel() }; state.connections.removeAll() } }
  }
  private final class BoundedDisplay: YlDisplayDriving {
    var isPaused = true
    var tick: (() -> Void)?
    func invalidate() { tick = nil }
    func advance() { if !isPaused { tick?() } }
  }
  func testBoundedSixteenMiBRealManagedFixtureProgressMetricsAndEOF() async throws {
    try await runBoundedFixture(controlledVideo: false)
  }
  func testBoundedSixteenMiBManagedFixtureWithControlledVideoMustProgressAndReachEOF() async throws {
    try await runBoundedFixture(controlledVideo: true)
  }
  func testBoundedFiveHundredMsControlledFixtureProgressesWithoutExceedingDuration() async throws {
    try await runBoundedFixture(controlledVideo: true, maximumMs: 500)
  }
  func testBoundedEOFBelowMinimumStillProgressesWithRealManagedInput() async throws {
    try await runBoundedFixture(controlledVideo: true, minimumMs: 10000, maximumMs: 12000)
  }
  func testFLVInitialAndReopenedInspectionUseAACSequenceHeaderMetadata() throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "flv"))
    let source = YlAppleSourceDescriptor(uri: url.absoluteString, kind: .file, formatHint: .flv,
      loadOptions: .init(decoderPolicy: .systemDefault))
    let candidate = try YlPreparedFallback(source: source, requireHardwareProbe: false)
    let first = try XCTUnwrap(candidate.audioStreams.first)
    XCTAssertEqual(first.sample_rate, 48000); XCTAssertEqual(first.channel_count, 1)
    let cookie = try XCTUnwrap(candidate.audioCookies[first.index])
    XCTAssertEqual(cookie, Data([0x11, 0x88, 0x56, 0xe5, 0]))
    let budget = try YlFallbackBufferBudget.make(configuration: .init(map: [:]), prepared: candidate)
    let demux = try YlDemuxPipeline(prepared: candidate, lock: NSLock(), bufferBudget: budget)
    defer { demux.discardMedia() }
    let reopened = try demux.inspectReopened(context: XCTUnwrap(demux.context), info: demux.currentMedia!.info,
      validateVideo: { XCTAssertEqual($0.width, 320) })
    let audio = try XCTUnwrap(reopened.audio.first)
    XCTAssertEqual(audio.sample_rate, 48000); XCTAssertEqual(audio.channel_count, 1)
    XCTAssertEqual(reopened.cookies[audio.index], cookie)
  }
  func testBoundedFLVRealManagedFixtureMustProgressAndReleasePayload() async throws {
    try await runBoundedFixture(controlledVideo: false, fixtureExtension: "flv")
  }
  private func runBoundedFixture(controlledVideo: Bool, fixtureExtension: String = "mkv", minimumMs: Int64 = 100, maximumMs: Int64 = 2000) async throws {
    let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: fixtureExtension))
    let rangeServer = fixtureExtension == "mkv" ? try ReactivationMediaServer(data: Data(contentsOf: fixture)) : nil
    let liveServer = fixtureExtension == "flv" ? try StreamingFLVServer(data: Data(contentsOf: fixture)) : nil
    defer { rangeServer?.close(); liveServer?.close() }
    let fixtureURL = rangeServer?.url ?? liveServer!.url
    let ledger = YlManagedBufferLedger()
    let scope = try ledger.makeScope(maxBytes: 16 * 1024 * 1024)
    let plan = try YlBoundedBufferPlan(minDurationMs: minimumMs, maxDurationMs: maximumMs, maxBytes: 16 * 1024 * 1024)
    let source = YlAppleSourceDescriptor(uri: fixtureURL.absoluteString, kind: .network, formatHint: fixtureExtension == "flv" ? .flv : .matroska,
      networkPolicy: .managed, loadOptions: fixtureExtension == "flv" ? .init(decoderPolicy: .systemDefault) : nil,
      bufferScope: scope, boundedPlan: plan)
    var candidate: YlPreparedFallback? = try YlPreparedFallback(source: source, requireHardwareProbe: false)
    if fixtureExtension == "flv" {
      let audio = try XCTUnwrap(candidate!.audioStreams.first)
      let cookie = try XCTUnwrap(candidate!.audioCookies[audio.index])
      XCTAssertEqual(audio.sample_rate, 48000, "inspected FLV rate")
      XCTAssertEqual(cookie, Data([0x11, 0x88, 0x56, 0xe5, 0x00]))
      XCTAssertEqual(ylBoundedAACPacketDurationUs(sampleRate: Double(audio.sample_rate), cookie: cookie), 21334)
    }
    let subtype = CMFormatDescriptionGetMediaSubType(candidate!.videoFormat)
    let hardwareAvailable = VTIsHardwareDecodeSupported(subtype)
    let attachment = XCTAttachment(string: "fixture=h264_aac.\(fixtureExtension) subtype=\(subtype) h264=\(kCMVideoCodecType_H264) hardwareAvailable=\(hardwareAvailable) controlledVideo=\(controlledVideo)")
    attachment.name = fixtureExtension == "mkv" ? "Task4-video-capability" : "Task8-FLV-video-capability"; attachment.lifetime = .keepAlways; add(attachment)
    XCTAssertEqual(subtype, kCMVideoCodecType_H264)
    #if targetEnvironment(simulator)
    if fixtureExtension == "mkv", !controlledVideo, subtype == kCMVideoCodecType_H264, !hardwareAvailable {
      throw XCTSkip("Task4 actual H264 hardware fixture: simulator VTIsHardwareDecodeSupported=false; physical iOS evidence pending (R19).")
    }
    #endif
    let controlledFactory = Factory(); controlledFactory.automaticFrames = true
    let selectedFactory: any YlVTSessionFactory = controlledVideo ? controlledFactory : YlHardwareVTSessionFactory(policy: fixtureExtension == "flv" ? .systemDefault : .hardwareRequired)
    let output = Output(), display = BoundedDisplay()
    var failures = [String](), lastPosition: Int64 = 0, completed = false, metricSamples = 0
    let eventLock = NSLock()
    var instance: YlFallbackBackend? = try YlFallbackBackend(playerId: 731,
      services: YlPlatformServices(platform: .current, textureOutput: output,
        makeDisplayDriver: { tick in display.tick = tick; return display }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: candidate!, generation: 31,
      videoSessionFactory: selectedFactory,
      emit: { callback in
        eventLock.withLock {
          switch callback.event {
          case .failure(let error): failures.append(error.code + ":" + (error.diagnostic ?? "none"))
          case .delta(let delta):
            lastPosition = max(lastPosition, delta.positionMs)
            if let bytes = delta.metrics.bufferedBytes {
              XCTAssertLessThanOrEqual(bytes, 16 * 1024 * 1024)
              XCTAssertNotNil(delta.metrics.bufferedDurationMs)
              XCTAssertLessThanOrEqual(delta.metrics.bufferedDurationMs ?? 0, maximumMs); metricSamples += 1
            }
          case .state(let state):
            lastPosition = max(lastPosition, state.positionMs); completed = state.status == "completed"
            if let bytes = state.metrics.bufferedBytes {
              XCTAssertLessThanOrEqual(bytes, 16 * 1024 * 1024)
              XCTAssertNotNil(state.metrics.bufferedDurationMs)
              XCTAssertLessThanOrEqual(state.metrics.bufferedDurationMs ?? 0, maximumMs); metricSamples += 1
            }
          default: break
          }
        }
      })
    defer { instance?.dispose() }
    candidate = nil
    try instance!.activate(); try instance!.play()
    for _ in 0..<1000 {
      try await Task.sleep(nanoseconds: 10_000_000)
      display.advance()
      let done = eventLock.withLock { completed || !failures.isEmpty || (fixtureExtension == "flv" && lastPosition > 700) }
      if done { break }
    }
    eventLock.withLock {
      XCTAssertTrue(failures.isEmpty, "\(failures)")
      if fixtureExtension == "mkv" { XCTAssertTrue(completed, "position=\(lastPosition), ledger=\(ledger.snapshot.currentBytes)") }
      XCTAssertGreaterThan(lastPosition, 500, "published=\(output.published) timing=\(scope.timingDiagnostic)")
      XCTAssertGreaterThan(metricSamples, 1)
    }
    XCTAssertGreaterThan(output.published, 1)
    XCTAssertLessThanOrEqual(ledger.snapshot.peakBytes, 16 * 1024 * 1024)
    instance?.dispose(); instance = nil
    for _ in 0..<100 where ledger.snapshot.currentBytes != 0 { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }
  func testBoundedInspectedFrameRejectsTooSmallBudgetBeforeActivation() throws {
    let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mkv"))
    let plan = try YlBoundedBufferPlan(minDurationMs: 0, maxDurationMs: 500,
      maxBytes: YlBoundedBufferPlan.safetyBytes + 1)
    let source = YlAppleSourceDescriptor(uri: fixture.absoluteString, kind: .file,
      formatHint: .matroska, boundedPlan: plan)
    XCTAssertThrowsError(try YlPreparedFallback(source: source, requireHardwareProbe: false)) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "policy.unsupported")
    }
  }
  func testBoundedAudioHeldCompletionRemainsChargedAfterResetAndDisposal() throws {
    let ledger = YlManagedBufferLedger(maxBytes: 16 * 1024 * 1024)
    let scope = try ledger.makeScope(maxBytes: nil)
    let trace = Trace(), output = AudioOutput(Trace()), converter = Converter(trace)
    let renderer = YlAudioRenderer(bufferScope: scope, converter: converter, output: output)
    try renderer.configure(stream: YlAudioStreamConfiguration(codec: .aac, sampleRate: 48000,
      channelCount: 2, magicCookie: Data(), generation: 1))
    XCTAssertEqual(try renderer.enqueue(packet: YlCompressedAudioPacket(data: Data([1]), ptsUs: 0,
      durationUs: 20000, generation: 1)), .scheduled)
    XCTAssertEqual(ledger.snapshot.currentBytes, 64)
    renderer.reset(generation: 2)
    XCTAssertEqual(ledger.snapshot.currentBytes, 64)
    renderer.dispose()
    XCTAssertEqual(ledger.snapshot.currentBytes, 64)
    output.completeAll()
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }
}
