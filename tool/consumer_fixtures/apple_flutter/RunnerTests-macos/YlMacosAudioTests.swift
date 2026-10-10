@testable import yl_player_apple
import AppKit
import AVFAudio
import Foundation
import Darwin
import VideoToolbox
import XCTest
import YlFFmpegBridge

final class YlMacosAudioTests: XCTestCase {

  private func terminalContext(
    enabled: Bool = true, platform: YlApplePlatform = .macos,
    localFiniteSeekable: Bool = true, hasBoundedPlan: Bool = false,
    codec: YlAudioCodec = .aac, sampleRate: Double = 48000,
    channels: Int = 2, rate: Float = 1
  ) -> YlAudioCompletionContext {
    .init(enabled: enabled, platform: platform,
      localFiniteSeekable: localFiniteSeekable, hasBoundedPlan: hasBoundedPlan,
      codec: codec, sampleRate: sampleRate, channels: channels, rate: rate)
  }

  func testTerminalPolicyRequiresExplicitEligibleContext() {
    XCTAssertEqual(YlAudioCompletionPolicy.select(terminalContext()), .terminalCandidate)
    XCTAssertEqual(YlAudioCompletionPolicy.select(terminalContext(enabled: false)),
      .legacy(.disabled))
    XCTAssertEqual(YlAudioCompletionPolicy.select(terminalContext(platform: .ios)),
      .legacy(.platform))
    // The session derives this fact from the source recipe, duration and seekability.
    XCTAssertEqual(YlAudioCompletionPolicy.select(terminalContext(localFiniteSeekable: false)),
      .legacy(.source))
    XCTAssertEqual(YlAudioCompletionPolicy.select(terminalContext(hasBoundedPlan: true)),
      .legacy(.bounded))
  }

  func testTerminalPolicyRejectsUnsupportedStreamFormats() {
    for codec: YlAudioCodec in [.mp3, .dts, .ac3, .eac3, .flac, .opus, .vorbis, .unsupported] {
      XCTAssertEqual(YlAudioCompletionPolicy.select(terminalContext(codec: codec)),
        .legacy(.format), "codec: \(codec)")
    }
    for sampleRate: Double in [44100, 96000, 0, -48000, .nan, .infinity,
                              -.infinity, Double(48000).nextDown, Double(48000).nextUp] {
      XCTAssertEqual(YlAudioCompletionPolicy.select(terminalContext(sampleRate: sampleRate)),
        .legacy(.format), "sample rate: \(sampleRate)")
    }
    for channels in [0, -1, 1, 6, Int.max] {
      XCTAssertEqual(YlAudioCompletionPolicy.select(terminalContext(channels: channels)),
        .legacy(.format), "channels: \(channels)")
    }
  }

  func testTerminalPolicyRequiresExactNormalRate() {
    for rate: Float in [0, -1, 0.5, 2, 4, .nan, .infinity, -.infinity,
                       Float(1).nextDown, Float(1).nextUp] {
      XCTAssertEqual(YlAudioCompletionPolicy.select(terminalContext(rate: rate)),
        .legacy(.rate), "rate: \(rate)")
    }
  }

  func testTerminalPolicyReportsFirstExclusionDeterministically() {
    XCTAssertEqual(YlAudioCompletionPolicy.select(terminalContext(enabled: false,
      platform: .ios, localFiniteSeekable: false, hasBoundedPlan: true,
      codec: .unsupported, rate: .nan)), .legacy(.disabled))
    XCTAssertEqual(YlAudioCompletionPolicy.select(terminalContext(platform: .ios,
      localFiniteSeekable: false, hasBoundedPlan: true, codec: .unsupported, rate: .nan)),
      .legacy(.platform))
    XCTAssertEqual(YlAudioCompletionPolicy.select(terminalContext(localFiniteSeekable: false,
      hasBoundedPlan: true, codec: .unsupported, rate: .nan)), .legacy(.source))
    XCTAssertEqual(YlAudioCompletionPolicy.select(terminalContext(hasBoundedPlan: true,
      codec: .unsupported, rate: .nan)), .legacy(.bounded))
    XCTAssertEqual(YlAudioCompletionPolicy.select(terminalContext(codec: .unsupported,
      rate: .nan)), .legacy(.format))
  }


  func testDefaultOutputBridgeRemainsPlayedBack() {
    for mode: YlAudioOutputCompletionMode in [.renderedResource, .playedBack] {
      let output = TestAudioOutput()
      let driver: any YlAudioOutputDriving = output
      XCTAssertFalse(driver.supportsTerminalCompletion)
      let group = YlAudioCompletionGroup()
      var released = 0
      var played = 0
      let buffer = YlScheduledAudioBuffer(payload: NSObject(), ptsUs: 0,
        durationUs: 21333, byteCount: 8192, generation: 1)
      driver.schedule(buffer, mode: mode, callbacks: group.makeCallbacks(
        releaseResources: { released += 1 }, completePlayback: { played += 1 }))
      XCTAssertEqual(released, 0)
      XCTAssertEqual(played, 0)
      let completion = output.retainedCompletion(at: 0)
      completion()
      completion()
      XCTAssertEqual(released, 1)
      XCTAssertEqual(played, 1)
    }
  }

  func testRenderedOutputNeverSendsPlayedBack() throws {
    let output = YlSystemAudioOutput()
    let driver: any YlAudioOutputDriving = output
    defer { driver.dispose() }
    XCTAssertTrue(driver.supportsTerminalCompletion)
    let converter = LifetimePCMConverter()
    try driver.configure(format: converter.format)
    driver.rate = 1
    driver.volume = 0
    let first = try XCTUnwrap(converter.convert(packet: .init(data: Data(),
      ptsUs: 0, durationUs: 21333, generation: 1)))
    let last = try XCTUnwrap(converter.convert(packet: .init(data: Data(),
      ptsUs: 21333, durationUs: 21333, generation: 1)))
    let rendered = expectation(description: "Ordinary PCM resources released")
    let lastReleased = expectation(description: "Terminal PCM resources released")
    let played = expectation(description: "Terminal PCM actually played back")
    let ordinaryPlayed = expectation(description: "Rendered notification must not complete playback")
    ordinaryPlayed.isInverted = true
    let group = YlAudioCompletionGroup()
    driver.schedule(first, mode: .renderedResource, callbacks: group.makeCallbacks(
      releaseResources: { rendered.fulfill() }, completePlayback: { ordinaryPlayed.fulfill() }))
    driver.schedule(last, mode: .playedBack, callbacks: group.makeCallbacks(
      releaseResources: { lastReleased.fulfill() }, completePlayback: { played.fulfill() }))
    try driver.play()
    wait(for: [rendered, lastReleased, played, ordinaryPlayed], timeout: 4)
  }

  func testExplicitOutputRejectionOnlyReleasesResources() throws {
    let converter = LifetimePCMConverter()
    let pcm = try XCTUnwrap(converter.convert(packet: .init(data: Data(),
      ptsUs: 0, durationUs: 21333, generation: 1)))
    let invalid = YlScheduledAudioBuffer(payload: NSObject(), ptsUs: 0,
      durationUs: 21333, byteCount: 8192, generation: 1)
    for mode: YlAudioOutputCompletionMode in [.renderedResource, .playedBack] {
      let driver: any YlAudioOutputDriving = YlSystemAudioOutput()
      defer { driver.dispose() }
      let group = YlAudioCompletionGroup()
      var released = 0
      var played = 0
      func schedule(_ buffer: YlScheduledAudioBuffer) {
        driver.schedule(buffer, mode: mode, callbacks: group.makeCallbacks(
          releaseResources: { released += 1 }, completePlayback: { played += 1 }))
      }
      schedule(pcm) // Unconfigured.
      XCTAssertEqual(released, 1)
      XCTAssertEqual(played, 0)
      try driver.configure(format: converter.format)
      schedule(invalid)
      XCTAssertEqual(released, 2)
      XCTAssertEqual(played, 0)
      driver.dispose()
      schedule(pcm)
      XCTAssertEqual(released, 3)
      XCTAssertEqual(played, 0)
    }
  }

  private final class InlineCompletionOutput: YlAudioOutputDriving {
    var volume: Float = 1
    var rate: Float = 1
    var renderedAudioTime: YlRenderedAudioTime?
    var completesOnSchedule = true
    var callbacks: [() -> Void] = []
    func configure(sampleRate: Double, channelCount: Int) throws {}
    func schedule(_ buffer: YlScheduledAudioBuffer, completion: @escaping () -> Void) {
      callbacks.append(completion)
      if completesOnSchedule { completion(); completion() }
    }
    func play() throws {}
    func pause() {}
    func reset() {
      let old = callbacks
      callbacks.removeAll()
      for callback in old { callback(); callback() }
    }
    func dispose() { reset() }
  }

  func testOutputBridgeAllowsSynchronousCompletionReentry() {
    let finished = expectation(description: "Synchronous scheduling/reset reentry finishes")
    DispatchQueue.global().async {
      let output = InlineCompletionOutput()
      let driver: any YlAudioOutputDriving = output
      let group = YlAudioCompletionGroup()
      let buffer = YlScheduledAudioBuffer(payload: NSObject(), ptsUs: 0,
        durationUs: 1, byteCount: 1, generation: 1)
      var releases = 0
      var plays = 0
      driver.schedule(buffer, mode: .renderedResource, callbacks: group.makeCallbacks(
        releaseResources: { releases += 1; driver.reset() },
        completePlayback: {
          plays += 1
          driver.schedule(buffer, mode: .playedBack, callbacks: group.makeCallbacks(
            releaseResources: { releases += 1 }, completePlayback: { plays += 1 }))
        }))
      driver.reset()
      XCTAssertEqual(releases, 2)
      XCTAssertEqual(plays, 2)
      finished.fulfill()
    }
    wait(for: [finished], timeout: 5)
  }

  func testRendererResetAcceptsSynchronousOldOutputCallbacks() throws {
    let output = InlineCompletionOutput()
    output.completesOnSchedule = false
    let ledger = YlManagedBufferLedger()
    let renderer = YlAudioRenderer(bufferScope: try ledger.makeScope(maxBytes: nil),
      converter: TestAudioConverter(), output: output)
    defer { renderer.dispose() }
    try renderer.configure(stream: .init(codec: .aac, sampleRate: 48000,
      channelCount: 2, magicCookie: Data(), generation: 1))
    XCTAssertEqual(try renderer.enqueue(packet: .init(data: Data(), ptsUs: 0,
      durationUs: 250000, generation: 1)), .scheduled)
    let old = try XCTUnwrap(output.callbacks.first)
    renderer.reset(generation: 2) // Output delivers the old callbacks inside reset.
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    XCTAssertFalse(renderer.hasPendingPlayback)
    XCTAssertEqual(try renderer.enqueue(packet: .init(data: Data(), ptsUs: 250000,
      durationUs: 250000, generation: 2)), .scheduled)
    old(); old()
    XCTAssertEqual(ledger.snapshot.currentBytes, 1000)
    XCTAssertTrue(renderer.hasPendingPlayback)
    renderer.dispose()
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }


  private final class IntegrationMarkers {
    private let lock = NSLock()
    private var frames = 0, zeros = 0, gaps = 0, errors = 0
    func consume(_ pcm: AVAudioPCMBuffer) {
      lock.withLock {
        guard let channel = pcm.floatChannelData?[0] else { errors += 1; return }
        for index in 0..<Int(pcm.frameLength) {
          let value = channel[index]
          if value == 0 { if frames > 0 { zeros += 1 }; continue }
          let expected = Float(frames % 2097152 + 1) / 4194304
          if value != expected { errors += 1 }
          frames += 1; gaps += zeros; zeros = 0
        }
      }
    }
    var snapshot: [String: Int] { lock.withLock { ["frames": frames, "interiorZeroFrames": gaps, "errors": errors] } }
  }
  private final class IntegrationPCM: YlAudioPacketConverting {
    let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)
    func configure(stream: YlAudioStreamConfiguration) throws {}
    func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate { .init(durationUs: 21334, byteCount: 8192) }
    func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer? {
      let ordinal = Int(packet.data.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) })
      let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat!, frameCapacity: 1024)!
      pcm.frameLength = 1024
      for channel in 0..<2 { for frame in 0..<1024 {
        pcm.floatChannelData![channel][frame] = Float((ordinal * 1024 + frame) % 2097152 + 1) / 4194304
      } }
      return .init(payload: pcm, ptsUs: packet.ptsUs, durationUs: 21334, byteCount: 8192, generation: packet.generation)
    }
  }
  // Test-only, bounded scalar trace. Never retain Error/engine/buffer objects
  // or publish arbitrary NSError text, domain, userInfo or source strings.
  private final class AudioFailureProbe {
    private let lock = NSLock()
    private var total = 0
    private var counts: [String: Int] = [:]
    private var events: [[String: Any]] = []
    func record(_ kind: String, error: Error? = nil) {
      lock.withLock {
        total += 1; counts[kind, default: 0] += 1
        var event: [String: Any] = ["sequence": total, "kind": kind,
          "uptime": ProcessInfo.processInfo.systemUptime]
        if let error {
          if kind == "rendererFailure" || kind == "startupFailure" {
            let native = error as? NativePlayerError
            let messages = [
              "The native audio output configuration changed; playback must be rebuilt.": "configurationChanged",
              "The native audio engine could not start.": "startFailed"]
            let reason = native?.code == "render.audio_engine_failed" ? messages[native?.message ?? ""] : nil
            event["code"] = native?.code == "render.audio_engine_failed" ? "render.audio_engine_failed" : "platform.failure"
            event["reason"] = reason ?? "unclassified"
            event["message"] = reason == nil ? "Playback operation failed." : native!.message
            event["diagnostic"] = YlAppleSafeDiagnostics.diagnostic(error)
          } else {
            let native = error as NSError
            event["nativeDomain"] = [NSOSStatusErrorDomain, NSCocoaErrorDomain, "AVFoundationErrorDomain"].contains(native.domain) ? native.domain : "other"
            event["nativeCode"] = native.code
          }
        }
        if events.count == 32 { events.removeFirst() }
        events.append(event)
      }
    }
    var snapshot: [String: Any] { lock.withLock { ["total": total, "counts": counts, "events": events] } }
  }
  private func startObservedPlayback(probe: AudioFailureProbe, start: () throws -> Void,
                                     cleanup: () -> Void, observe: (String) throws -> Void) throws {
    do { try start() }
    catch {
      probe.record("startupFailure", error: error)
      do { try observe("startupFailure") }
      catch { cleanup(); throw error }
      cleanup()
      try observe("disposed")
      throw error
    }
  }

  private final class NaturalEOFProbe {
    private let lock = NSLock()
    let hold: Bool
    private var pending: (() -> Void)?
    private var nativeTimes: [Double] = []
    private var forwardedTimes: [Double] = []
    init(hold: Bool) { self.hold = hold }
    func receive(_ callback: @escaping () -> Void) {
      let retained = lock.withLock { () -> Bool in
        if nativeTimes.count < 2 { nativeTimes.append(ProcessInfo.processInfo.systemUptime) }
        if hold && pending == nil && forwardedTimes.isEmpty { pending = callback; return true }
        if forwardedTimes.count < 2 { forwardedTimes.append(ProcessInfo.processInfo.systemUptime) }
        return false
      }
      if !retained { callback() }
    }
    func release() -> (() -> Void)? {
      let callback = lock.withLock { () -> (() -> Void)? in
        guard let callback = pending else { return nil }
        pending = nil; forwardedTimes.append(ProcessInfo.processInfo.systemUptime)
        return callback
      }
      callback?()
      return callback
    }
    var snapshot: [String: Any] { lock.withLock {
      ["nativePlayedTimes": nativeTimes, "forwardedPlayedTimes": forwardedTimes, "held": pending != nil]
    } }
    var hasHeldCallback: Bool { lock.withLock { pending != nil } }
  }

  private final class IntegrationOutput: YlAudioOutputDriving {
    let system: YlSystemAudioOutput
    let wrapsCallbacks: Bool
    var onSubmit: ((YlScheduledAudioBuffer) -> Void)?
    var onSubmissionMode: ((YlAudioOutputCompletionMode) -> Void)?
    // Bounded test-only capture for replaying one retired generation callback.
    var captureNextPlayedCompletion = false
    var capturedPlayedCompletion: (() -> Void)?
    private let lock = NSLock()
    private var counts = ["renderedSubmissions": 0, "playedSubmissions": 0, "renderedCallbacks": 0, "playedCallbacks": 0]
    var snapshot: [String: Int] { lock.withLock { counts } }
    let supportsTerminalCompletion = true
    private let failureProbe: AudioFailureProbe?
    var invalidateOnPlay = false
    var eofProbe: NaturalEOFProbe?
    init(engine: AVAudioEngine, failureProbe: AudioFailureProbe? = nil, wrapsCallbacks: Bool = true) {
      self.wrapsCallbacks = wrapsCallbacks
      self.failureProbe = failureProbe; system = YlSystemAudioOutput(engine: engine)
    }
    var volume: Float { get { system.volume } set { system.volume = newValue } }
    var rate: Float { get { system.rate } set { system.rate = newValue } }
    var renderedAudioTime: YlRenderedAudioTime? { system.renderedAudioTime }
    func setInvalidationHandler(_ handler: (() -> Void)?) {
      guard let handler else { system.setInvalidationHandler(nil); return }
      let probe = failureProbe
      system.setInvalidationHandler { [weak probe] in
        probe?.record("configurationInvalidated"); handler()
      }
    }
    func configure(sampleRate: Double, channelCount: Int) throws { try system.configure(sampleRate: sampleRate, channelCount: channelCount) }
    func configure(format: AVAudioFormat) throws { try system.configure(format: format) }
    func schedule(_ buffer: YlScheduledAudioBuffer, completion: @escaping () -> Void) {
      onSubmit?(buffer)
      onSubmissionMode?(.playedBack)
      if captureNextPlayedCompletion {
        captureNextPlayedCompletion = false; capturedPlayedCompletion = completion
      }
      lock.withLock { counts["playedSubmissions", default: 0] += 1 }
      if !wrapsCallbacks { system.schedule(buffer, completion: completion); return }
      system.schedule(buffer) { [weak self] in
        self?.lock.withLock { self?.counts["playedCallbacks", default: 0] += 1 }; completion()
      }
    }
    func schedule(_ buffer: YlScheduledAudioBuffer, mode: YlAudioOutputCompletionMode, callbacks: YlAudioOutputCallbacks) {
      onSubmit?(buffer)
      onSubmissionMode?(mode)
      if captureNextPlayedCompletion && mode == .playedBack {
        captureNextPlayedCompletion = false
        capturedPlayedCompletion = { callbacks.resourcesReleased(); callbacks.playedBack() }
      }
      lock.withLock { counts[mode == .renderedResource ? "renderedSubmissions" : "playedSubmissions", default: 0] += 1 }
      if !wrapsCallbacks { system.schedule(buffer, mode: mode, callbacks: callbacks); return }
      system.schedule(buffer, mode: mode, callbacks: .init(resourcesReleased: { [weak self] in
        self?.lock.withLock { self?.counts["renderedCallbacks", default: 0] += 1 }; callbacks.resourcesReleased()
      }, playedBack: { [weak self] in
        self?.lock.withLock { self?.counts["playedCallbacks", default: 0] += 1 }
        if let probe = self?.eofProbe { probe.receive(callbacks.playedBack) } else { callbacks.playedBack() }
      }))
    }
    func play() throws {
      failureProbe?.record("playAttempt")
      if invalidateOnPlay { system.dispose() }
      do { try system.play(); failureProbe?.record("playSucceeded") }
      catch { failureProbe?.record("playFailed", error: error); throw error }
    }
    func pause() { system.pause() }
    func reset() { system.reset() }
    func dispose() { failureProbe?.record("disposed"); system.dispose() }
  }

  private final class DecodedAudioFactory: YlAudioRendererMaking {
    let engine = AVAudioEngine()
    let failureProbe = AudioFailureProbe()
    let wrapsCallbacks: Bool
    init(wrapsCallbacks: Bool = true) { self.wrapsCallbacks = wrapsCallbacks }
    lazy var output = IntegrationOutput(engine: engine, failureProbe: failureProbe, wrapsCallbacks: wrapsCallbacks)
    private let lock = NSLock()
    private var prefix: [[String: Any]] = []
    var submittedPrefix: [[String: Any]] { lock.withLock { prefix } }
    var renderers: [YlAudioRenderer] = []
    func makeRenderer(bufferBudget: YlFallbackBufferBudget) -> YlAudioRenderer {
      engine.mainMixerNode.outputVolume = 0
      output.onSubmit = { [weak self] buffer in
        guard let self, let pcm = buffer.payload as? AVAudioPCMBuffer else { return }
        self.lock.withLock {
          if self.prefix.count < 3 {
            self.prefix.append(["ptsUs": buffer.ptsUs, "durationUs": buffer.durationUs,
              "frames": Int(pcm.frameLength), "sampleRate": pcm.format.sampleRate,
              "channels": Int(pcm.format.channelCount), "float32": pcm.format.commonFormat == .pcmFormatFloat32,
              "interleaved": pcm.format.isInterleaved])
          }
        }
      }
      let renderer = YlAudioRenderer(bufferBudget: bufferBudget, output: output)
      renderers.append(renderer)
      return renderer
    }
    var nativePlaying: Bool { engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.contains { $0.isPlaying } }
  }
  private final class DecodedScheduler: YlPresentationScheduling {
    let actual = YlFrameScheduler(collectDropDiagnostics: true)
    var videoFrames = 0, orderErrors = 0
    var awaitingPublish = false
    var selectedUptime: Double = 0
    var maxLagUs: Int64 = 0, positionUs: Int64 = 0, videoPTS: Int64 = -1
    var lateFrameDropCount: Int { actual.lateFrameDropCount }
    var dropDiagnostics: [String: Any] {
      let snapshot = actual.dropDiagnostics
      return ["total": snapshot.total, "waitingEnqueues": snapshot.waitingEnqueues, "counts": Dictionary(uniqueKeysWithValues: YlFrameDropReason.allCases.map { ($0.rawValue, snapshot.counts[$0] ?? 0) }),
        "events": snapshot.events.map { event -> [String: Any] in
          ["reason": event.reason.rawValue, "count": event.count, "total": event.total,
           "uptime": event.uptime, "generation": event.generation, "firstPTS": event.firstPTS,
           "lastPTS": event.lastPTS, "queueCount": event.queueCount,
           "positionUs": event.positionUs as Any? ?? NSNull(), "selectedPTS": event.selectedPTS as Any? ?? NSNull(),
           "previousPositionUs": event.previousPositionUs as Any? ?? NSNull(),
           "previousTickUptime": event.previousTickUptime as Any? ?? NSNull(), "enqueueWaitSeconds": event.enqueueWaitSeconds]
        }]
    }
    var pendingPTS: [Int64] { actual.pendingPTS }
    var bufferedDurationUs: Int64 { actual.bufferedDurationUs }
    func configureBounded(_ plan: YlBoundedBufferPlan?) { actual.configureBounded(plan) }
    func setRate(_ rate: Double) { actual.setRate(rate) }
    func enqueue(_ frame: YlFrameEnvelope) -> Bool { actual.enqueue(frame) }
    func frame(at positionUs: Int64, generation: UInt64) -> YlFrameEnvelope? {
      let frame = actual.frame(at: positionUs, generation: generation)
      if let frame {
        if frame.ptsUs <= videoPTS || frame.ptsUs > positionUs || frame.generation != generation { orderErrors += 1 }
        awaitingPublish = true; selectedUptime = ProcessInfo.processInfo.systemUptime
        videoPTS = frame.ptsUs; self.positionUs = positionUs
        maxLagUs = max(maxLagUs, positionUs - frame.ptsUs); videoFrames += 1
      }
      return frame
    }
    func flush(generation: UInt64) { actual.flush(generation: generation) }
    func dispose() { actual.dispose() }
  }
  private final class DecodedTexture: YlTextureOutput {
    let textureId: Int64 = 731
    let scheduler: DecodedScheduler
    init(scheduler: DecodedScheduler) { self.scheduler = scheduler }
    var published = 0, directPublished = 0
    func publish(_ pixelBuffer: CVPixelBuffer?) {
      guard pixelBuffer != nil else { return }
      published += 1
      if scheduler.awaitingPublish { scheduler.awaitingPublish = false }
      else { directPublished += 1 }
    }
    func resize(width: Int, height: Int) {}
    func clear() {}
    func dispose() {}
  }

  func testDisplayTimingSeparatesTickGapFromWorkAndCapsHistory() throws {
    var now = 1.0
    let probe = DisplayTimingProbe(enabled: true, clock: { now })
    probe.tick { now = 1.01 }
    now = 1.20
    probe.tick { now = 1.24 }
    let first = probe.snapshot
    let events = try XCTUnwrap(first["events"] as? [[String: Any]])
    XCTAssertEqual(events.compactMap { $0["kind"] as? String }, ["tickGap", "tickWork"])
    XCTAssertEqual(try XCTUnwrap(events.first?["seconds"] as? Double), 0.20, accuracy: 0.000001)
    XCTAssertEqual(try XCTUnwrap(events.last?["seconds"] as? Double), 0.04, accuracy: 0.000001)
    for _ in 0..<40 { now += 0.2; probe.tick {} }
    let bounded = probe.snapshot
    XCTAssertEqual(bounded["total"] as? Int, 42)
    XCTAssertEqual((bounded["events"] as? [[String: Any]])?.count, 32)
    XCTAssertEqual(bounded["tickCalls"] as? Int, 42)
    XCTAssertEqual((bounded["counts"] as? [String: Int])?["tickGap"], 41)
  }

  func testDisplayTimingLimitsPendingProbeAndFencesStop() throws {
    var now = 1.0, queued: [() -> Void] = []
    let probe = DisplayTimingProbe(enabled: true, clock: { now }, dispatchMain: { queued.append($0) })
    probe.pulse()
    now = 1.05; probe.pulse()
    XCTAssertEqual(queued.count, 1)
    now = 1.16; let delivered = try XCTUnwrap(queued.first); queued.removeFirst(); delivered()
    let row = probe.snapshot
    XCTAssertEqual(row["probeSent"] as? Int, 1)
    XCTAssertEqual(row["probeCompleted"] as? Int, 1)
    XCTAssertEqual(row["probeSkipped"] as? Int, 1)
    let event = try XCTUnwrap((row["events"] as? [[String: Any]])?.last)
    XCTAssertEqual(event["kind"] as? String, "mainQueue")
    XCTAssertEqual(try XCTUnwrap(event["seconds"] as? Double), 0.16, accuracy: 0.000001)
    now = 1.20; probe.pulse() // producer gap must be independently visible
    probe.stop()
    let stopped = try JSONSerialization.data(withJSONObject: probe.snapshot, options: [.sortedKeys])
    now = 2; let retired = try XCTUnwrap(queued.first); queued.removeFirst(); retired(); probe.pulse(); probe.tick {}
    XCTAssertEqual(try JSONSerialization.data(withJSONObject: probe.snapshot, options: [.sortedKeys]), stopped)
    XCTAssertEqual((probe.snapshot["counts"] as? [String: Int])?["producerGap"], 1)
    var forwarded = false
    let disabled = DisplayTimingProbe(enabled: false, clock: { now }, dispatchMain: { _ in XCTFail("Disabled probe scheduled work") })
    disabled.start(); disabled.pulse(); disabled.tick { forwarded = true }; disabled.stop()
    XCTAssertTrue(forwarded)
    XCTAssertEqual(disabled.snapshot["total"] as? Int, 0)
    XCTAssertEqual(disabled.snapshot["tickCalls"] as? Int, 0)
  }

  func testDisplayTimingAttributesCadenceRefreshAndBodySeparately() throws {
    var now = 1.0, queued: [() -> Void] = []
    let probe = DisplayTimingProbe(enabled: true, clock: { now }, dispatchMain: { queued.append($0) })
    probe.cadence { now = 1.002; probe.tick { now = 1.005 } }
    now = 1.01; probe.runLoop(activity: CFRunLoopActivity.beforeWaiting.rawValue)
    now = 1.02; probe.pulse()
    now = 1.021; try XCTUnwrap(queued.first)(); queued.removeFirst()
    now = 1.079; probe.runLoop(activity: CFRunLoopActivity.afterWaiting.rawValue)
    now = 1.08
    probe.cadence { now = 1.12; probe.tick { now = 1.125 } }
    let boundary = try XCTUnwrap(probe.snapshot["cadenceBoundary"] as? [String: Any])
    let event = try XCTUnwrap((boundary["events"] as? [[String: Any]])?.last)
    XCTAssertEqual(try XCTUnwrap(event["entryGap"] as? Double), 0.08, accuracy: 0.000001)
    XCTAssertEqual(try XCTUnwrap(event["refreshWork"] as? Double), 0.04, accuracy: 0.000001)
    XCTAssertEqual(try XCTUnwrap(event["bodyWork"] as? Double), 0.005, accuracy: 0.000001)
    let loop = try XCTUnwrap(event["runLoop"] as? [[String: Any]])
    XCTAssertEqual(loop.count, 2)
    XCTAssertEqual(try XCTUnwrap(loop.first?["uptime"] as? Double), 1.01, accuracy: 0.000001)
    XCTAssertEqual(try XCTUnwrap(loop.last?["uptime"] as? Double), 1.079, accuracy: 0.000001)
    let response = try XCTUnwrap((event["mainResponses"] as? [[String: Double]])?.first)
    XCTAssertEqual(try XCTUnwrap(response["requested"]), 1.02, accuracy: 0.000001)
    XCTAssertEqual(try XCTUnwrap(response["delivered"]), 1.021, accuracy: 0.000001)
    for _ in 0..<40 { now += 0.1; probe.cadence { probe.tick {} } }
    XCTAssertEqual(((probe.snapshot["cadenceBoundary"] as? [String: Any])?["events"] as? [[String: Any]])?.count, 32)
    probe.stop()
    let frozen = try JSONSerialization.data(withJSONObject: probe.snapshot, options: [.sortedKeys])
    now += 1; probe.cadence { probe.tick {} }
    XCTAssertEqual(try JSONSerialization.data(withJSONObject: probe.snapshot, options: [.sortedKeys]), frozen)
    let disabled = DisplayTimingProbe(enabled: false)
    var forwarded = false
    disabled.cadence { disabled.tick { forwarded = true } }
    XCTAssertTrue(forwarded)
    XCTAssertEqual((disabled.snapshot["cadenceBoundary"] as? [String: Any])?["calls"] as? Int, 0)
  }

  // Test-only observer. No frame payloads and at most one outstanding main-queue probe.
  private final class DisplayTimingProbe {
    private let enabled: Bool, clock: () -> Double
    private let dispatchMain: (@escaping () -> Void) -> Void
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var lastTick: Double?, lastPulse: Double?, pending: Double?
    private var total = 0, tickCalls = 0, sent = 0, completed = 0, skipped = 0, cancelled = 0
    private var counts = ["tickGap": 0, "tickWork": 0, "mainQueue": 0, "producerGap": 0]
    private var maxima = ["tickGap": 0.0, "tickWork": 0.0, "mainQueue": 0.0, "producerGap": 0.0]
    private var events: [[String: Any]] = []
    private var cadenceStart: Double?, cadenceBody: Double?, previousCadence: Double?
    private var cadenceCalls = 0, cadenceTotal = 0
    private var cadenceMaxima = ["entryGap": 0.0, "refreshWork": 0.0, "bodyWork": 0.0]
    private var cadenceEvents: [[String: Any]] = []
    private var mainResponses: [[String: Double]] = []
    private var runLoopObserver: CFRunLoopObserver?
    private var runLoopEvents: [[String: Any]] = []
    init(enabled: Bool, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         dispatchMain: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
      self.enabled = enabled; self.clock = clock; self.dispatchMain = dispatchMain
    }
    // Called only while holding lock, with times from the same monotonic clock.
    private func record(_ kind: String, start: Double, end: Double) {
      let seconds = end - start
      maxima[kind] = max(maxima[kind, default: 0], seconds)
      guard seconds >= (kind == "producerGap" ? 0.1 : 0.03) else { return }
      total += 1; counts[kind, default: 0] += 1
      events.append(["sequence": total, "kind": kind, "start": start, "end": end, "seconds": seconds])
      if events.count > 32 { events.removeFirst() }
    }
    func start() {
      lock.withLock {
        guard enabled, !stopped, timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "yl.tests.display-timing", qos: .utility))
        source.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        source.setEventHandler { [weak self] in self?.pulse() }
        timer = source; source.resume()
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
          CFRunLoopActivity.allActivities.rawValue, true, 0) { [weak self] _, activity in
            self?.runLoop(activity: activity.rawValue)
          }
        runLoopObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
      }
    }
    func pulse() {
      let request: Double? = lock.withLock {
        guard enabled, !stopped else { return nil }
        let now = clock()
        if let lastPulse { record("producerGap", start: lastPulse, end: now) }
        lastPulse = now
        guard pending == nil else { skipped += 1; return nil }
        pending = now; sent += 1; return now
      }
      guard let request else { return }
      dispatchMain { [weak self] in
        guard let self else { return }
        self.lock.withLock {
          guard !self.stopped, self.pending == request else { return }
          let delivered = self.clock()
          self.record("mainQueue", start: request, end: delivered)
          self.mainResponses.append(["requested": request, "delivered": delivered])
          if self.mainResponses.count > 16 { self.mainResponses.removeFirst() }
          self.pending = nil; self.completed += 1
        }
      }
    }
    // Wrap the real cadence factory's callback, before YlDisplayTimer refreshes its screen.
    func runLoop(activity: CFOptionFlags) {
      lock.withLock {
        guard enabled, !stopped else { return }
        runLoopEvents.append(["uptime": clock(), "activity": activity])
        if runLoopEvents.count > 256 { runLoopEvents.removeFirst() }
      }
    }
    func cadence(_ action: () -> Void) {
      let entry: (Double, Double?)? = lock.withLock {
        guard enabled, !stopped else { return nil }
        let now = clock(), previous = previousCadence
        previousCadence = now; cadenceStart = now; cadenceBody = nil; cadenceCalls += 1
        return (now, previous)
      }
      action()
      guard let (start, previous) = entry else { return }
      lock.withLock {
        defer { cadenceStart = nil; cadenceBody = nil }
        guard !stopped, let body = cadenceBody else { return }
        let end = clock(), gap = previous.map { start - $0 } ?? 0
        let refresh = body - start, work = end - body
        for (key, value) in [("entryGap", gap), ("refreshWork", refresh), ("bodyWork", work)] {
          cadenceMaxima[key] = max(cadenceMaxima[key, default: 0], value)
        }
        guard max(gap, refresh, work) >= 0.03 else { return }
        cadenceTotal += 1
        let since = previous ?? start
        let priorIndex = runLoopEvents.lastIndex { ($0["uptime"] as? Double ?? 0) < since } ?? 0
        let loop = Array(runLoopEvents.suffix(from: priorIndex))
        cadenceEvents.append(["sequence": cadenceTotal, "previousEntry": previous as Any? ?? NSNull(),
          "entry": start, "body": body, "end": end, "entryGap": gap,
          "refreshWork": refresh, "bodyWork": work,
          "runLoop": loop, "runLoopHistoryTruncated": (loop.first?["uptime"] as? Double ?? since) > since,
          "mainResponses": mainResponses.filter { $0["delivered", default: 0] >= (previous ?? start) }])
        if cadenceEvents.count > 32 { cadenceEvents.removeFirst() }
      }
    }
    func tick(_ action: () -> Void) {
      let start: Double? = lock.withLock {
        guard enabled, !stopped else { return nil }
        let now = clock()
        if cadenceStart != nil { cadenceBody = now }
        if let lastTick { record("tickGap", start: lastTick, end: now) }
        lastTick = now; tickCalls += 1; return now
      }
      action()
      if let start { lock.withLock { if !stopped { record("tickWork", start: start, end: clock()) } } }
    }
    func stop() {
      lock.withLock {
        stopped = true; timer?.cancel(); timer = nil
        if let observer = runLoopObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        runLoopObserver = nil
        if pending != nil { pending = nil; cancelled += 1 }
      }
    }
    var snapshot: [String: Any] {
      lock.withLock {
        ["enabled": enabled, "stopped": stopped, "total": total, "counts": counts, "maxima": maxima,
         "events": events, "tickCalls": tickCalls, "probeSent": sent, "probeCompleted": completed,
         "probeSkipped": skipped, "probeCancelled": cancelled, "probePending": pending != nil,
         "cadenceBoundary": ["calls": cadenceCalls, "total": cadenceTotal,
           "maxima": cadenceMaxima, "events": cadenceEvents]]
      }
    }
    deinit {
      timer?.cancel()
      if let observer = runLoopObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    }
  }


  @MainActor
  func testActualTimedNativeSessionPauseSeekEOFAndClose() async throws {
    guard #available(macOS 14.0, *) else { throw XCTSkip("Timed native candidate requires macOS 14") }
    let views = YlMacosVideoViewFactory(), registry = ApplePublicationRegistry()
    let output = YlMacosTextureOutput(textures: registry, nativeViews: views)
    let view = views.create(withViewIdentifier: 941, arguments: ["textureId": NSNumber(value: output.textureId)])
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 256, height: 144), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
    defer { window.close() }
    let owner = YlAppleTextureOwner(output: output, onFrame: { _ in })
    defer { owner.dispose() }
    let lease = owner.makeLease(identity: .init(sessionId: "timed", loadRequestId: "timed")); owner.commit(lease)
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("assets/test_media/format_matrix/mkv-avc-aac.mkv")
    let ledger = YlManagedBufferLedger(), scope = try ledger.makeScope(maxBytes: nil)
    let prepared = try YlPreparedFallback(source: .init(uri: fixture.absoluteString, kind: .file, formatHint: .matroska, bufferScope: scope), requireHardwareProbe: true)
    let services = YlPlatformServices(platform: .macos, textureOutput: output,
      makeDisplayDriver: { YlDisplayTimer(view: view, onTick: $0) }).borrowing(lease)
    var errors: [String] = [], completions = 0, firstFrames = 0
    let instance = try YlManagedPlaybackSession(playerId: 941, services: services,
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: prepared, generation: 1,
      emit: { callback in
        if case let .failure(error) = callback.event { errors.append(error.code) }
        if case let .state(state) = callback.event, state.status == "completed" { completions += 1 }
        if case .firstFrame = callback.event { firstFrames += 1 }
      }, timedVideoCandidateEnabled: true)
    defer { instance.dispose() }
    instance.setVolume(0); try instance.activate()
    try await AppleHostCharacterizations.waitFor({ firstFrames == 1 })
    XCTAssertNil(instance.timedVideoStatistics, "An initially paused preview must not be replaced with an empty timed layer")
    try instance.play()
    try await AppleHostCharacterizations.waitFor({ (instance.timedVideoStatistics?.submitted ?? 0) >= 12 }, timeout: 5)
    try instance.pause()
    try await Task.sleep(nanoseconds: 100_000_000)
    let paused = instance.timedVideoStatistics?.submitted
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(instance.timedVideoStatistics?.submitted, paused)
    for rate: Float in [0.25, 1, 2, 4] {
      try instance.setPlaybackSpeed(rate)
      let before = instance.timedVideoStatistics?.submitted ?? 0
      try instance.play()
      try await AppleHostCharacterizations.waitFor({ (instance.timedVideoStatistics?.submitted ?? 0) >= before + 3 })
      try instance.pause()
    }
    try instance.setPlaybackSpeed(1); try instance.play()
    let layer = try XCTUnwrap(view.layer)
    output.detach(layer)
    try await Task.sleep(nanoseconds: 50_000_000)
    output.attach(layer)
    try await AppleHostCharacterizations.waitFor({ (instance.timedVideoStatistics?.submitted ?? 0) >= 3 })
    try instance.seek(toMs: 2000, cancellationToken: nil)
    try instance.play()
    try await AppleHostCharacterizations.waitFor({ (instance.timedVideoStatistics?.submitted ?? 0) >= 12 })
    try await AppleHostCharacterizations.waitFor({ completions == 1 }, timeout: 8)
    XCTAssertEqual(firstFrames, 1); XCTAssertTrue(errors.isEmpty)
    XCTAssertFalse(instance.timedVideoStatistics?.pending ?? true)
    instance.dispose(); owner.dispose()
    try await AppleHostCharacterizations.waitFor({ ledger.snapshot.currentBytes == 0 }, timeout: 3)
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }

  @MainActor
  func testActualDecodedTerminalContinuousObservation() async throws {
    let env = ProcessInfo.processInfo.environment
    let timing = DisplayTimingProbe(enabled: env["YL_DECODED_TIMING_DIAGNOSTICS"] == "1")
    timing.start(); defer { timing.stop() }
    let seconds = env["YL_DECODED_PROBE_KIND"] == "long" ? 1200.0 : 30.0
    XCTAssertNil(env["MallocStackLogging"]); XCTAssertNil(env["MallocStackLoggingNoCompact"])
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("assets/test_media/format_matrix/continuous-avc-aac.mkv")
    let ledger = YlManagedBufferLedger(), scope = try ledger.makeScope(maxBytes: nil)
    let prepared = try YlPreparedFallback(source: .init(uri: fixture.absoluteString, kind: .file,
      formatHint: .matroska, bufferScope: scope), requireHardwareProbe: true)
    let factory = DecodedAudioFactory(), scheduler = DecodedScheduler()
    let output = DecodedTexture(scheduler: scheduler)
    let eventLock = NSLock(); var failures: [String] = []
    let instance = try YlManagedPlaybackSession(playerId: 731,
      services: .init(platform: .macos, textureOutput: output, makeDisplayDriver: { onTick in
        YlDisplayTimer(cadenceFactory: { screen, fps, callback in
          YlSystemDisplayCadence(screen: screen, fallbackFramesPerSecond: fps) { timing.cadence(callback) }
        }) { timing.tick(onTick) }
      }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: prepared, generation: 17,
      audioRendererFactory: factory, presentationScheduler: scheduler,
      emit: { callback in
        if case let .failure(error) = callback.event {
          eventLock.withLock { factory.failureProbe.record("rendererFailure", error: error); failures.append(error.code) }
        }
      }, audioTerminalCandidateEnabled: true)
    defer { instance.dispose() }
    let renderer = try XCTUnwrap(factory.renderers.first)
    var records: [[String: Any]] = []
    // Passive, bounded observation only; the external diagnostic owns activation.
    var activationEvents: [[String: Any]] = []
    let activationObservers = env["YL_DECODED_ACTIVATION_DIAGNOSTICS"] != "1" ? [] : [
      NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
      NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
    ].map { name in
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
        activationEvents.append(["name": name.rawValue, "uptime": ProcessInfo.processInfo.systemUptime])
        if activationEvents.count > 16 { activationEvents.removeFirst() }
      }
    }
    defer { activationObservers.forEach(NotificationCenter.default.removeObserver) }
    func observe(_ phase: String) throws {
      let diagnostics = scheduler.dropDiagnostics
      let failureState = eventLock.withLock { (failures, factory.failureProbe.snapshot) }
      let nativeAudio = factory.output.renderedAudioTime
      let nativeAudioUs = nativeAudio.map { Int64(Double($0.sampleTime) * 1_000_000 / $0.sampleRate) }
      let audio = renderer.renderedAudioTime
      let audioUs = audio.map { Int64(Double($0.sampleTime) * 1_000_000 / $0.sampleRate) }
      let row: [String: Any] = ["phase": phase, "pid": ProcessInfo.processInfo.processIdentifier,
        "activationEvents": activationEvents,
        "applicationActive": NSApp.isActive, "activationPolicy": NSApp.activationPolicy().rawValue,
        "generation": 17, "uptime": ProcessInfo.processInfo.systemUptime,
        "audioUs": audioUs as Any? ?? NSNull(), "positionUs": scheduler.positionUs,
        "videoPTS": scheduler.videoPTS, "videoFrames": scheduler.videoFrames, "published": output.published,
        "directPublished": output.directPublished, "submittedPrefix": factory.submittedPrefix,
        "frameAgeUs": Int64((ProcessInfo.processInfo.systemUptime - scheduler.selectedUptime) * 1_000_000),
        "maxLagUs": scheduler.maxLagUs, "orderErrors": scheduler.orderErrors, "dropped": diagnostics["total"]!,
        "dropDiagnostics": diagnostics, "timingDiagnostics": timing.snapshot,
        "failures": failureState.0, "audioDiagnostics": failureState.1,
        "engineRunning": factory.engine.isRunning, "nativeAudioUs": nativeAudioUs as Any? ?? NSNull(),
        "candidate": renderer.usesSubmissionAnchor,
        "nativePlaying": factory.nativePlaying, "rendererCount": factory.renderers.count,
        "ledgerBytes": ledger.snapshot.currentBytes, "ledgerPeak": ledger.snapshot.peakBytes,
        "audioOwnedBytes": renderer.scheduledBytes, "pending": renderer.hasPendingPlayback,
        "modes": factory.output.snapshot, "thermalState": ProcessInfo.processInfo.thermalState.rawValue]
      records.append(row)
      if let directory = env["YL_DECODED_PROBE_DIRECTORY"] {
        let path = URL(fileURLWithPath: directory).appendingPathComponent("rows.jsonl")
        if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: path); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10]))
      }
    }
    try startObservedPlayback(probe: factory.failureProbe,
      start: { try instance.activate(); try instance.play() },
      cleanup: { instance.dispose(); timing.stop() }, observe: observe)
    let warmup = ProcessInfo.processInfo.systemUptime
    while (scheduler.videoFrames < 24 || scheduler.positionUs < 2_000_000) && ProcessInfo.processInfo.systemUptime - warmup < 10 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertGreaterThanOrEqual(scheduler.videoFrames, 24); XCTAssertGreaterThanOrEqual(scheduler.positionUs, 2_000_000)
    let start = ProcessInfo.processInfo.systemUptime
    repeat {
      try observe("playing")
      if ProcessInfo.processInfo.systemUptime - start >= seconds { break }
      if !eventLock.withLock({ failures.isEmpty }) || !factory.nativePlaying { break }
      try await Task.sleep(nanoseconds: 5_000_000_000)
    } while true
    XCTAssertTrue(eventLock.withLock { failures.isEmpty })
    XCTAssertTrue(renderer.usesSubmissionAnchor, "Submission anchoring unexpectedly unavailable (actual modes validated separately)")
    XCTAssertEqual(scheduler.orderErrors, 0); XCTAssertEqual(scheduler.lateFrameDropCount, 0)
    XCTAssertLessThanOrEqual(scheduler.maxLagUs, 100_000)
    instance.dispose(); timing.stop(); try observe("disposed")
    try await Task.sleep(nanoseconds: 2_000_000_000); try observe("disposedLater")
    XCTAssertEqual(ledger.snapshot.currentBytes, 0); XCTAssertFalse(renderer.hasPendingPlayback)
    let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
    attachment.name = "decoded-continuity"; attachment.lifetime = .keepAlways; add(attachment)
  }

  func testActualTerminalAdapterFrameSequenceMatrix() throws {
    for candidate in [false, true] {
      for count in [0, 1, 3, 2000] { try runActualAdapter(count: count, candidate: candidate) }
      try runActualAdapter(count: 100, candidate: candidate, starvation: true)
      try runActualAdapter(count: 3, candidate: candidate, pausedEOF: true)
    }
  }

  func testActualTerminalAdapterContinuousObservation() throws {
    let env = ProcessInfo.processInfo.environment
    let kind = env["YL_AUDIO_PROBE_KIND"] ?? "short"
    XCTAssertNil(env["MallocStackLogging"]); XCTAssertNil(env["MallocStackLoggingNoCompact"])
    let afterDrain = kind == "resource-drained-1000" || kind == "resource-drained-2000"
    let count = kind == "long" ? 56485 : kind == "resource-drained-1000" ? 1000 :
      kind == "resource" || afterDrain ? 2000 : 8
    try runActualAdapter(count: count, candidate: env["YL_AUDIO_PROBE_ARM"] != "legacy",
      probeDirectory: env["YL_AUDIO_PROBE_DIRECTORY"], resourceProbe: kind == "resource" || afterDrain,
      captureAfterDrain: afterDrain)
  }

  func testActualTerminalAdapterResourceCaptureWaitsForEOF() throws {
    for candidate in [false, true] {
      let row = try runActualAdapter(count: 64, candidate: candidate, resourceProbe: true, captureAfterDrain: true)
      XCTAssertEqual(row["liveHeapCheckpointRequested"] as? Bool, false,
        "Post-drain resource mode must never request heap during playback")
      XCTAssertEqual((row["marker"] as? [String: Int])?["frames"], 65536)
      XCTAssertEqual((row["marker"] as? [String: Int])?["errors"], 0)
    }
  }

  func testActualSystemOutputClockAfterDisposeIsUnavailable() throws {
    let output = YlSystemAudioOutput()
    XCTAssertNil(output.renderedAudioTime)
    try output.configure(sampleRate: 48000, channelCount: 2)
    output.dispose()
    XCTAssertNil(output.renderedAudioTime)
    output.dispose()
    XCTAssertNil(output.renderedAudioTime)
  }

  private final class ReloadAudioFactory: YlAudioRendererMaking {
    var wrapsCallbacks = true
    var onSubmissionMode: ((YlAudioOutputCompletionMode) -> Void)?
    var entries: [DecodedAudioFactory] = []
    var invalidateNextPlay = false
    var eofProbe: NaturalEOFProbe?
    func makeRenderer(bufferBudget: YlFallbackBufferBudget) -> YlAudioRenderer {
      let entry = DecodedAudioFactory(wrapsCallbacks: wrapsCallbacks)
      entry.output.eofProbe = eofProbe
      entry.output.onSubmissionMode = onSubmissionMode
      entry.output.invalidateOnPlay = invalidateNextPlay
      invalidateNextPlay = false
      entries.append(entry)
      return entry.makeRenderer(bufferBudget: bufferBudget)
    }
  }

  private enum ResourceProbeError: Error { case acknowledgementTimedOut, invalidFixtureDuration, invalidBoundaryMode }

  @MainActor
  private func waitForResourceAcknowledgement(_ exists: () -> Bool, timeout: TimeInterval = 30) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !exists() {
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw ResourceProbeError.acknowledgementTimedOut
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  @MainActor
  func testResourceAcknowledgementTimeoutStopsBeforePlayback() async throws {
    var proceeded = false
    do {
      try await waitForResourceAcknowledgement({ false }, timeout: 0.01)
      proceeded = true
      XCTFail("Missing ACK must throw before playback can begin")
    } catch ResourceProbeError.acknowledgementTimedOut {}
    XCTAssertFalse(proceeded)
    try await waitForResourceAcknowledgement({ true }, timeout: 0)
  }

  @MainActor
  func testActualDecodedEOFResourceObservation() async throws {
    let env = ProcessInfo.processInfo.environment
    XCTAssertNil(env["MallocStackLogging"]); XCTAssertNil(env["MallocStackLoggingNoCompact"])
    let directory = env["YL_AUDIO_PROBE_DIRECTORY"].map { URL(fileURLWithPath: $0) }
    let arms = directory == nil ? [false, true] : [env["YL_AUDIO_PROBE_ARM"] != "legacy"]
    let expectedSeconds = try XCTUnwrap(Double(env["YL_AUDIO_PROBE_SECONDS"] ?? "4.021"))
    guard expectedSeconds > 0 && expectedSeconds <= 60 else { throw ResourceProbeError.invalidFixtureDuration }
    let boundary = env["YL_AUDIO_PROBE_STOP_BOUNDARY"] ?? "none"
    guard ["none", "hold", "stop"].contains(boundary) else { throw ResourceProbeError.invalidBoundaryMode }
    var configurations: [(candidate: Bool, wraps: Bool, boundary: String)]
    if directory == nil {
      configurations = [true, false].flatMap { wraps in arms.map { ($0, wraps, "none") } }
      configurations += [(false, false, "hold"), (false, false, "stop"), (true, false, "stop")]
    } else {
      configurations = [(arms[0], env["YL_AUDIO_PROBE_CALLBACK_WRAPPING"] != "transparent", boundary)]
    }
    for configuration in configurations {
      let candidate = configuration.candidate, wrapCallbacks = configuration.wraps
      let boundaryMode = configuration.boundary
      if boundaryMode != "none" { XCTAssertFalse(wrapCallbacks) }
      let longHold = env["YL_AUDIO_PROBE_STOP_TIMING"] == "1"
      let holdSeconds: UInt64 = longHold && boundaryMode == "hold" ? 30 : 2
      var boundaryTiming: [String: TimeInterval] = [:]
      var playerStopCalls = 0
      var interventionWaitSeconds: TimeInterval = 0
      let factory = ReloadAudioFactory(), ledger = YlManagedBufferLedger()
      factory.wrapsCallbacks = wrapCallbacks
      let registry = ApplePublicationRegistry(), callbacks = AppleRecordingCallbacks()
      var publicDeltaCount = 0
      // Count frequent progress events without retaining a history proportional to duration.
      callbacks.acknowledge = { [weak callbacks] in
        guard let callbacks else { return }
        publicDeltaCount += callbacks.deltas.count
        callbacks.deltas.removeAll(keepingCapacity: true)
        callbacks.order.removeAll(keepingCapacity: true)
      }
      var playbackStarted: TimeInterval?
      var playbackElapsed: TimeInterval = 0
      let host = YlApplePlayerHost(playerId: 743, suffix: "decoded-resource-743",
        options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 50),
        services: registry.services(), callbacks: callbacks, bufferLedger: ledger,
        audioRendererFactory: factory, audioTerminalCandidateEnabled: candidate)
      defer { host.close() }
      try host.attach(); try host.setVolume(volume: 0)
      let defaultFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("assets/test_media/format_matrix/mkv-avc-aac.mkv")
      let fixture = env["YL_AUDIO_PROBE_FIXTURE"].map { URL(fileURLWithPath: $0) } ?? defaultFixture
      var request = AppleHostFixture.request("decoded-resource", url: fixture.path, format: .matroska, autoplay: false)
      request.source.kind = .file
      let session = try await host.load(request: request)
      let entry = try XCTUnwrap(factory.entries.first), renderer = try XCTUnwrap(entry.renderers.first)
      XCTAssertEqual(renderer.usesSubmissionAnchor, candidate)
      let originalNodes = entry.engine.attachedNodes
      let players = originalNodes.compactMap { $0 as? AVAudioPlayerNode }
      XCTAssertEqual(players.count, 1)
      let nativePlayer = try XCTUnwrap(players.first)
      func probe(_ phase: String, checkpoint: Bool = false) async throws {
        if phase == "intervened" { boundaryTiming["probeEntered"] = ProcessInfo.processInfo.systemUptime }
        // onState appends before its async acknowledgement; let that in-flight
        // acknowledgement finish before freezing the resource observation.
        try await waitForResourceAcknowledgement({ callbacks.deltas.isEmpty && callbacks.order.isEmpty }, timeout: 5)
        if phase == "intervened" { boundaryTiming["recorderSettled"] = ProcessInfo.processInfo.systemUptime }
        if checkpoint {
          XCTAssertFalse(entry.nativePlaying)
          if phase != "configured" {
            XCTAssertEqual(callbacks.states.filter { $0.status == .completed }.count, 1)
            XCTAssertFalse(renderer.hasPendingPlayback); XCTAssertEqual(renderer.scheduledBytes, 0)
          }
        }
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
          pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
          }
        }
        if phase == "intervened" { boundaryTiming["memoryReadFinished"] = ProcessInfo.processInfo.systemUptime }
        var observedModes: [String: Any] = entry.output.snapshot.mapValues { $0 as Any }
        if !wrapCallbacks {
          observedModes["renderedCallbacks"] = NSNull(); observedModes["playedCallbacks"] = NSNull()
        }
        let rowUptime = ProcessInfo.processInfo.systemUptime
        if phase == "intervened" { boundaryTiming["rowCaptured"] = rowUptime }
        let row: [String: Any] = ["phase": phase, "uptime": rowUptime,
          "timingProfile": longHold ? "long-hold-v1" : "short-hold-v1", "boundaryTiming": boundaryTiming,
          "boundaryMode": boundaryMode, "playerStopCalls": playerStopCalls,
          "interventionWaitSeconds": interventionWaitSeconds,
          "attachedNodeCount": entry.engine.attachedNodes.count,
          "playerAttached": entry.engine.attachedNodes.contains(nativePlayer),
          "graphUnchanged": entry.engine.attachedNodes == originalNodes,
          "callbackWrapping": wrapCallbacks ? "wrapped" : "transparent",
          "callbackObservation": wrapCallbacks ? "native-wrapped" : "unobserved",
          "fixtureName": fixture.lastPathComponent, "playbackElapsedSeconds": playbackElapsed,
          "publicDeltaCount": publicDeltaCount, "retainedDeltaCount": callbacks.deltas.count,
          "retainedOrderCount": callbacks.order.count,
          "retainedEventCount": callbacks.states.count + callbacks.frames.count + callbacks.engines.count + callbacks.failures.count + callbacks.retries.count,
          "pid": ProcessInfo.processInfo.processIdentifier, "sessionId": session.sessionId,
          "candidate": candidate, "submissionAnchor": renderer.usesSubmissionAnchor, "pending": renderer.hasPendingPlayback,
          "nativePlaying": entry.nativePlaying, "engineRunning": entry.engine.isRunning,
          "ownedBytes": renderer.scheduledBytes, "ledgerBytes": ledger.snapshot.currentBytes,
          "ledgerPeak": ledger.snapshot.peakBytes, "modes": observedModes,
          "completed": callbacks.states.filter { $0.status == .completed }.count,
          "firstFrames": callbacks.frames.filter { $0.sessionId == session.sessionId }.count,
          "failures": callbacks.failures.map { $0.failure.code }, "audioDiagnostics": entry.failureProbe.snapshot,
          "rssBytes": status == KERN_SUCCESS ? info.resident_size as Any : NSNull(),
          "footprintBytes": status == KERN_SUCCESS ? info.phys_footprint as Any : NSNull()]
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "decoded-resource-\(candidate)-\(phase)"; attachment.lifetime = .keepAlways; add(attachment)
        guard let directory else { return }
        let file = directory.appendingPathComponent("rows.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: data + Data([10])); try handle.close()
        if checkpoint {
          let ack = directory.appendingPathComponent(phase + ".ack")
          try await waitForResourceAcknowledgement({ FileManager.default.fileExists(atPath: ack.path) })
        }
      }
      try await probe("configured", checkpoint: true)
      playbackStarted = ProcessInfo.processInfo.systemUptime
      try await host.play(command: .init(sessionId: session.sessionId))
      // Reducer completion precedes the asynchronously queued public state.
      // Keep the original deadline while waiting for the boundary asserted below.
      try await AppleHostCharacterizations.waitFor({
        host.initialState.status == .completed && callbacks.states.contains { $0.status == .completed }
      }, timeout: expectedSeconds + 10)
      playbackElapsed = ProcessInfo.processInfo.systemUptime - (playbackStarted ?? 0)
      XCTAssertEqual(callbacks.states.filter { $0.status == .completed }.count, 1)
      XCTAssertTrue(callbacks.failures.isEmpty)
      XCTAssertFalse(renderer.hasPendingPlayback); XCTAssertEqual(renderer.scheduledBytes, 0)
      let modes = entry.output.snapshot
      if wrapCallbacks {
        XCTAssertEqual(modes["renderedSubmissions"], modes["renderedCallbacks"])
        XCTAssertEqual(modes["playedSubmissions"], modes["playedCallbacks"])
      } else {
        // Counters must not run in transparent mode; no claim of zero native callbacks.
        XCTAssertEqual(modes["renderedCallbacks"], 0); XCTAssertEqual(modes["playedCallbacks"], 0)
      }
      XCTAssertEqual(callbacks.frames.filter { $0.sessionId == session.sessionId }.count, 1)
      if candidate {
        XCTAssertEqual(modes["playedSubmissions"], 1); XCTAssertGreaterThan(modes["renderedSubmissions", default: 0], 1)
      } else {
        XCTAssertEqual(modes["renderedSubmissions"], 0); XCTAssertGreaterThan(modes["playedSubmissions", default: 0], 1)
      }
      try await probe("completed")
      // Quiesce only after natural completion; retain the graph for the drained heap.
      renderer.pause()
      try await probe("drained", checkpoint: true)
      if boundaryMode != "none" {
        boundaryTiming["ackReturned"] = ProcessInfo.processInfo.systemUptime
        let waitStarted = ProcessInfo.processInfo.systemUptime
        boundaryTiming["sleepStarted"] = waitStarted
        try await Task.sleep(nanoseconds: holdSeconds * 1_000_000_000)
        let waitFinished = ProcessInfo.processInfo.systemUptime
        boundaryTiming["sleepFinished"] = waitFinished
        interventionWaitSeconds = waitFinished - waitStarted
        boundaryTiming["actionStarted"] = ProcessInfo.processInfo.systemUptime
        if boundaryMode == "stop" { nativePlayer.stop() }
        boundaryTiming["actionFinished"] = ProcessInfo.processInfo.systemUptime
        if boundaryMode == "stop" { playerStopCalls += 1 }
        XCTAssertEqual(playerStopCalls, boundaryMode == "stop" ? 1 : 0)
        XCTAssertTrue(entry.engine.isRunning)
        XCTAssertEqual(entry.engine.attachedNodes, originalNodes)
        XCTAssertEqual(entry.output.snapshot, modes)
        XCTAssertFalse(renderer.hasPendingPlayback); XCTAssertEqual(renderer.scheduledBytes, 0)
        boundaryTiming["assertionsFinished"] = ProcessInfo.processInfo.systemUptime
        try await probe("intervened", checkpoint: true)
      }
      host.close()
      XCTAssertFalse(entry.engine.attachedNodes.contains(nativePlayer))
      XCTAssertFalse(entry.engine.isRunning); XCTAssertEqual(ledger.snapshot.currentBytes, 0)
      try await probe("disposed", checkpoint: true)
      try await Task.sleep(nanoseconds: 2_000_000_000)
      XCTAssertEqual(entry.output.snapshot, modes)
      XCTAssertEqual(ledger.snapshot.currentBytes, 0); XCTAssertTrue(callbacks.failures.isEmpty)
      try await probe("disposedLater")
    }
  }

  private final class LifecycleCounters: ApplePlayerFlutterApiProtocol {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func record(_ key: String) { lock.withLock { counts[key, default: 0] += 1 } }
    var snapshot: [String: Int] { lock.withLock { counts } }
    func onState(state: AppleStateMessage) async throws { record("publications"); if state.status == .completed { record("completed") } }
    func onStateDelta(delta: AppleStateDeltaMessage) async throws { record("publications") }
    func onFirstFrame(event: AppleFirstFrameMessage) async throws { record("publications"); record("firstFrames") }
    func onRetryScheduled(event: AppleRetryScheduledMessage) async throws { record("publications"); record("retries") }
    func onEngineChanged(event: AppleEngineChangedMessage) async throws { record("publications") }
    func onPlaybackFailed(event: ApplePlaybackFailedMessage) async throws { record("publications"); record("failures") }
  }

  @MainActor
  func testLifecycleCheckpointReadsCountersAfterLateEvents() async throws {
    let counters = LifecycleCounters()
    let before = counters.snapshot
    let late = Task { @MainActor in
      try await Task.sleep(nanoseconds: 10_000_000)
      for key in ["completed", "firstFrames", "failures", "playedSubmissions", "renderedSubmissions", "publications"] { counters.record(key) }
    }
    try await late.value
    let after = counters.snapshot
    for key in ["completed", "firstFrames", "failures", "playedSubmissions", "renderedSubmissions", "publications"] {
      XCTAssertEqual(before[key, default: 0], 0)
      XCTAssertEqual(after[key, default: 0], 1, "A post-settlement read must see late \(key)")
    }
  }

  @MainActor
  func testActualDecodedRepeatedLifecycleResources() async throws {
    let env = ProcessInfo.processInfo.environment
    XCTAssertNil(env["MallocStackLogging"]); XCTAssertNil(env["MallocStackLoggingNoCompact"])
    let directory = env["YL_AUDIO_PROBE_DIRECTORY"].map { URL(fileURLWithPath: $0) }
    let arms = directory == nil ? [false, true] : [env["YL_AUDIO_PROBE_ARM"] == "candidate"]
    let kinds = directory == nil ? ["seek", "load-close"] : [env["YL_AUDIO_LIFECYCLE_KIND"] ?? "invalid"]
    let rounds = directory == nil ? 2 : 6
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("assets/test_media/format_matrix/mkv-avc-aac.mkv")
    for candidate in arms { for kind in kinds {
      guard ["seek", "load-close"].contains(kind) else { throw ResourceProbeError.invalidBoundaryMode }
      let ledger = YlManagedBufferLedger()
      let counters = LifecycleCounters(), registry = ApplePublicationRegistry()
      var sessions = 0
      weak var retiredEntry: DecodedAudioFactory?
      func observe(_ phase: String, cycle: Int, entry: DecodedAudioFactory? = nil) async throws {
        let before = counters.snapshot, framesBefore = registry.positivePublicFrames
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let renderer = entry?.renderers.first
        let live = counters.snapshot
        for key in ["completed", "firstFrames", "failures", "retries", "playedSubmissions", "renderedSubmissions"] {
          XCTAssertEqual(live[key, default: 0], before[key, default: 0], "Late event during settlement: \(key)")
        }
        XCTAssertEqual(registry.positivePublicFrames, framesBefore)
        XCTAssertFalse(entry?.nativePlaying ?? false)
        XCTAssertFalse(renderer?.hasPendingPlayback ?? false)
        XCTAssertEqual(renderer?.scheduledBytes ?? 0, 0)
        if entry == nil { XCTAssertNil(retiredEntry); XCTAssertEqual(ledger.snapshot.currentBytes, 0) }
        let row: [String: Any] = ["phase": phase, "cycle": cycle, "rounds": rounds,
          "pid": ProcessInfo.processInfo.processIdentifier, "uptime": ProcessInfo.processInfo.systemUptime,
          "candidate": candidate, "kind": kind, "completed": live["completed", default: 0], "firstFrames": live["firstFrames", default: 0],
          "sessions": sessions, "playedSubmissions": live["playedSubmissions", default: 0], "renderedSubmissions": live["renderedSubmissions", default: 0],
          "videoFrames": registry.positivePublicFrames, "failures": live["failures", default: 0],
          "publications": live["publications", default: 0], "retries": live["retries", default: 0],
          "callbackObservation": "unobserved", "playedCallbacks": NSNull(), "renderedCallbacks": NSNull(),
          "nativePlaying": entry?.nativePlaying ?? false, "pending": renderer?.hasPendingPlayback ?? false,
          "ownedBytes": renderer?.scheduledBytes ?? 0, "ledgerBytes": ledger.snapshot.currentBytes,
          "retiredEntryAlive": retiredEntry != nil, "activeGraph": entry != nil,
          "attachedNodes": entry?.engine.attachedNodes.count ?? 0,
          "engineRunning": entry?.engine.isRunning ?? false,
          "submissionAnchor": renderer?.usesSubmissionAnchor ?? false]
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "lifecycle-resource-\(candidate)-\(kind)-\(phase)"; attachment.lifetime = .keepAlways; add(attachment)
        guard let directory else { return }
        let file = directory.appendingPathComponent("rows.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: data + Data([10])); try handle.close()
        if ["baseline", "cycle1", "cycle3", "cycle6", "disposed"].contains(phase) {
          try await waitForResourceAcknowledgement({ FileManager.default.fileExists(atPath: directory.appendingPathComponent(phase + ".ack").path) })
        }
      }
      func playHost(passes: Int, firstCycle: Int) async throws {
        let factory = ReloadAudioFactory(); factory.wrapsCallbacks = false
        factory.onSubmissionMode = { mode in
          counters.record(mode == .playedBack ? "playedSubmissions" : "renderedSubmissions")
        }
        let host = YlApplePlayerHost(playerId: Int64(751 + firstCycle), suffix: "lifecycle-resource-\(firstCycle)",
          options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 50),
          services: registry.services(), callbacks: counters, bufferLedger: ledger,
          audioRendererFactory: factory, audioTerminalCandidateEnabled: candidate)
        defer { host.close() }
        try host.attach(); try host.setVolume(volume: 0)
        var request = AppleHostFixture.request("lifecycle-resource", url: fixture.path, format: .matroska, autoplay: false)
        request.source.kind = .file
        let session = try await host.load(request: request); sessions += 1
        let entry = try XCTUnwrap(factory.entries.first), renderer = try XCTUnwrap(entry.renderers.first)
        let nodes = entry.engine.attachedNodes
        let native = try XCTUnwrap(nodes.compactMap { $0 as? AVAudioPlayerNode }.first)
        for pass in 0..<passes {
          let cycle = firstCycle + pass
          if pass > 0 { try host.seekTo(command: .init(sessionId: session.sessionId, positionMs: 0)) }
          let previousFrames = registry.positivePublicFrames
          try await host.play(command: .init(sessionId: session.sessionId))
          try await AppleHostCharacterizations.waitFor({
            host.initialState.timeline.positionMs >= 200 && (entry.output.renderedAudioTime?.sampleTime ?? 0) > 0
          }, timeout: 5)
          try await AppleHostCharacterizations.waitFor({ host.initialState.status == .completed }, timeout: 10)
          try await waitForResourceAcknowledgement({ counters.snapshot["completed", default: 0] == cycle }, timeout: 5)
          XCTAssertEqual(counters.snapshot["firstFrames", default: 0], sessions)
          XCTAssertGreaterThan(registry.positivePublicFrames, previousFrames)
          XCTAssertEqual(counters.snapshot["failures", default: 0], 0)
          XCTAssertFalse(renderer.hasPendingPlayback); XCTAssertEqual(renderer.scheduledBytes, 0)
          XCTAssertEqual(renderer.usesSubmissionAnchor, candidate)
          let modes = entry.output.snapshot
          let expectedPlayed = candidate ? pass + 1 : modes["playedSubmissions", default: 0]
          XCTAssertEqual(modes["playedSubmissions"], expectedPlayed)
          if candidate { XCTAssertGreaterThan(modes["renderedSubmissions", default: 0], pass + 1) }
          else { XCTAssertEqual(modes["renderedSubmissions"], 0); XCTAssertGreaterThan(expectedPlayed, 1) }
          native.pause() // Sampling-only intervention after software drain, no direct stop.
          XCTAssertEqual(host.sessionId, session.sessionId); XCTAssertEqual(factory.entries.count, 1)
          XCTAssertEqual(entry.engine.attachedNodes, nodes)
          if kind == "seek" { try await observe("cycle\(cycle)", cycle: cycle, entry: entry) }
        }
        host.close(); host.close()
        XCTAssertEqual(ledger.snapshot.currentBytes, 0); XCTAssertFalse(entry.engine.isRunning)
        XCTAssertFalse(entry.engine.attachedNodes.contains(native))
        retiredEntry = entry
      }
      try await observe("baseline", cycle: 0)
      if kind == "seek" { try await playHost(passes: rounds, firstCycle: 1) }
      else {
        for cycle in 1...rounds {
          try await playHost(passes: 1, firstCycle: cycle)
          try await observe("cycle\(cycle)", cycle: cycle)
        }
      }
      try await observe("disposed", cycle: rounds)
      try await observe("disposedLater", cycle: rounds)
    } }
  }

  @MainActor
  func testActualDecodedLegacyEOFStopSeekReplay() async throws {
    try await verifyEOFStopSeekReplay(candidate: false)
  }

  @MainActor
  func testActualDecodedCandidateEOFStopSeekReplay() async throws {
    try await verifyEOFStopSeekReplay(candidate: true)
  }

  @MainActor
  func testActualDecodedLegacyEOFSeekReplayWithoutManualStop() async throws {
    try await verifyEOFStopSeekReplay(candidate: false, stopBeforeSeek: false)
  }

  @MainActor
  func testActualDecodedCandidateEOFSeekReplayWithoutManualStop() async throws {
    try await verifyEOFStopSeekReplay(candidate: true, stopBeforeSeek: false)
  }

  @MainActor
  private func verifyEOFStopSeekReplay(candidate: Bool, stopBeforeSeek: Bool = true) async throws {
    let factory = ReloadAudioFactory(), ledger = YlManagedBufferLedger()
    factory.wrapsCallbacks = false
    let registry = ApplePublicationRegistry(), callbacks = AppleRecordingCallbacks()
    let host = YlApplePlayerHost(playerId: 745, suffix: "eof-replay-745",
      options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 50),
      services: registry.services(), callbacks: callbacks, bufferLedger: ledger,
      audioRendererFactory: factory, audioTerminalCandidateEnabled: candidate)
    defer { host.close(); factory.entries.forEach { $0.output.capturedPlayedCompletion = nil } }
    try host.attach(); try host.setVolume(volume: 0)
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("assets/test_media/format_matrix/mkv-avc-aac.mkv")
    var request = AppleHostFixture.request("eof-replay", url: fixture.path, format: .matroska, autoplay: false)
    request.source.kind = .file
    let session = try await host.load(request: request)
    let entry = try XCTUnwrap(factory.entries.first), renderer = try XCTUnwrap(entry.renderers.first)
    let nodes = entry.engine.attachedNodes
    let players = nodes.compactMap { $0 as? AVAudioPlayerNode }
    XCTAssertEqual(players.count, 1)
    let native = try XCTUnwrap(players.first)
    entry.output.captureNextPlayedCompletion = true
    var observations: [[String: Any]] = []
    var completedCount = 0
    func completions() -> Int { callbacks.states.filter { $0.status == .completed }.count }
    for (cycle, target) in [Int64(0), 0, 2000].enumerated() {
      let before = entry.output.snapshot
      let framesBefore = registry.positivePublicFrames
      if cycle > 0 {
        let stopStart = ProcessInfo.processInfo.systemUptime
        if stopBeforeSeek { native.stop() }
        let stopSeconds = ProcessInfo.processInfo.systemUptime - stopStart
        XCTAssertEqual(entry.engine.attachedNodes, nodes); XCTAssertTrue(entry.engine.isRunning)
        if stopBeforeSeek { XCTAssertFalse(native.isPlaying) }
        try host.seekTo(command: .init(sessionId: session.sessionId, positionMs: target))
        XCTAssertEqual(host.initialState.status, .paused)
        let late = try XCTUnwrap(entry.output.capturedPlayedCompletion)
        late(); late()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(completions(), completedCount)
        XCTAssertEqual(host.initialState.status, .paused)
        XCTAssertTrue(callbacks.failures.isEmpty)
        observations.append(["phase": "seek", "cycle": cycle, "targetMs": target,
          "manualStop": stopBeforeSeek, "stopSeconds": stopBeforeSeek ? stopSeconds as Any : NSNull(),
          "completedAfterRetiredCallback": completions()])
      }
      try await host.play(command: .init(sessionId: session.sessionId))
      try await AppleHostCharacterizations.waitFor({
        (entry.output.renderedAudioTime?.sampleTime ?? 0) > 0 &&
          host.initialState.timeline.positionMs >= target + 200
      }, timeout: 5)
      let position = host.initialState.timeline.positionMs
      let audioTime = try XCTUnwrap(entry.output.renderedAudioTime).sampleTime
      if cycle > 0 { entry.output.capturedPlayedCompletion?() }
      try await AppleHostCharacterizations.waitFor({ host.initialState.timeline.positionMs >= position + 200 }, timeout: 3)
      let advancedAudioTime = try XCTUnwrap(entry.output.renderedAudioTime).sampleTime
      XCTAssertGreaterThan(advancedAudioTime, audioTime)
      XCTAssertGreaterThan(registry.positivePublicFrames, framesBefore, "Replay must publish real video frames")
      XCTAssertEqual(completions(), completedCount)
      XCTAssertEqual(host.initialState.status, .playing)
      XCTAssertEqual(host.sessionId, session.sessionId)
      XCTAssertEqual(factory.entries.count, 1, "Seek/replay must reuse the same native output")
      XCTAssertEqual(entry.engine.attachedNodes, nodes)
      XCTAssertEqual(renderer.usesSubmissionAnchor, candidate)
      try await AppleHostCharacterizations.waitFor({ host.initialState.status == .completed }, timeout: 10)
      completedCount += 1
      XCTAssertEqual(completions(), completedCount)
      XCTAssertEqual(callbacks.frames.filter { $0.sessionId == session.sessionId }.count, 1,
        "First-frame publication is once per session, including replay")
      XCTAssertTrue(callbacks.failures.isEmpty)
      XCTAssertFalse(renderer.hasPendingPlayback); XCTAssertEqual(renderer.scheduledBytes, 0)
      XCTAssertEqual(renderer.usesSubmissionAnchor, candidate)
      let after = entry.output.snapshot
      let played = after["playedSubmissions", default: 0] - before["playedSubmissions", default: 0]
      let rendered = after["renderedSubmissions", default: 0] - before["renderedSubmissions", default: 0]
      if candidate { XCTAssertEqual(played, 1); XCTAssertGreaterThan(rendered, 1) }
      else { XCTAssertGreaterThan(played, 1); XCTAssertEqual(rendered, 0) }
      observations.append(["phase": "completed", "cycle": cycle, "targetMs": target,
        "positionBeforeMs": position, "positionAfterMs": host.initialState.timeline.positionMs,
        "videoFramesBefore": framesBefore, "videoFramesAfter": registry.positivePublicFrames,
        "audioSampleBefore": audioTime, "audioSampleAfter": advancedAudioTime,
        "playedSubmissions": played, "renderedSubmissions": rendered,
        "completed": completions(), "firstFrames": callbacks.frames.count,
        "submissionAnchor": renderer.usesSubmissionAnchor, "ownedBytes": renderer.scheduledBytes,
        "pending": renderer.hasPendingPlayback])
    }
    host.close(); host.close()
    try await Task.sleep(nanoseconds: 150_000_000)
    func counts() -> [Int] { [callbacks.states.count, callbacks.deltas.count, callbacks.frames.count,
                            callbacks.failures.count, callbacks.engines.count, callbacks.retries.count] }
    let closedCounts = counts(), closedModes = entry.output.snapshot
    let closedFrames = registry.positivePublicFrames
    entry.output.capturedPlayedCompletion?(); entry.output.capturedPlayedCompletion?()
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(counts(), closedCounts); XCTAssertEqual(entry.output.snapshot, closedModes)
    XCTAssertEqual(registry.positivePublicFrames, closedFrames)
    XCTAssertEqual(ledger.snapshot.currentBytes, 0); XCTAssertEqual(renderer.scheduledBytes, 0)
    XCTAssertFalse(renderer.hasPendingPlayback); XCTAssertFalse(entry.engine.isRunning)
    XCTAssertFalse(entry.engine.attachedNodes.contains(native)); XCTAssertTrue(host.disposed)
    let data = try JSONSerialization.data(withJSONObject: ["candidate": candidate,
      "sessionId": session.sessionId, "outputsCreated": factory.entries.count,
      "manualStop": stopBeforeSeek, "observations": observations, "ledgerAfterClose": ledger.snapshot.currentBytes,
      "publicationsBeforeLateCallback": closedCounts, "publicationsAfterLateCallback": counts(),
      "callbackObservation": "unobserved", "productionAdmission": false,
      "audioDiagnostics": entry.failureProbe.snapshot], options: [.sortedKeys])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "decoded-eof-replay-\(candidate)-manual-stop-\(stopBeforeSeek)"; attachment.lifetime = .keepAlways; add(attachment)
  }

  @MainActor
  func testActualDecodedLegacyEOFSuspendResumeDoesNotAutoplay() async throws {
    try await verifyEOFSuspendResume(candidate: false)
  }

  @MainActor
  func testActualDecodedCandidateEOFSuspendResumeDoesNotAutoplay() async throws {
    try await verifyEOFSuspendResume(candidate: true)
  }

  @MainActor
  private func verifyEOFSuspendResume(candidate: Bool) async throws {
    let factory = ReloadAudioFactory(), ledger = YlManagedBufferLedger()
    factory.wrapsCallbacks = false
    let registry = ApplePublicationRegistry(), callbacks = AppleRecordingCallbacks()
    let host = YlApplePlayerHost(playerId: 747, suffix: "eof-background-747",
      options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 50),
      services: registry.services(), callbacks: callbacks, bufferLedger: ledger,
      audioRendererFactory: factory, audioTerminalCandidateEnabled: candidate)
    defer { host.close(); factory.entries.forEach { $0.output.capturedPlayedCompletion = nil } }
    try host.attach(); try host.setVolume(volume: 0)
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("assets/test_media/format_matrix/mkv-avc-aac.mkv")
    var request = AppleHostFixture.request("eof-background", url: fixture.path, format: .matroska, autoplay: false)
    request.source.kind = .file
    let session = try await host.load(request: request)
    let retired = try XCTUnwrap(factory.entries.first), oldRenderer = try XCTUnwrap(retired.renderers.first)
    retired.output.captureNextPlayedCompletion = true
    try await host.play(command: .init(sessionId: session.sessionId))
    try await AppleHostCharacterizations.waitFor({ host.initialState.status == .completed }, timeout: 10)
    func completions() -> Int { callbacks.states.filter { $0.status == .completed }.count }
    XCTAssertEqual(completions(), 1); XCTAssertFalse(host.playbackIntent)
    XCTAssertFalse(oldRenderer.hasPendingPlayback); XCTAssertEqual(oldRenderer.scheduledBytes, 0)
    XCTAssertEqual(oldRenderer.usesSubmissionAnchor, candidate)
    let atEOF = retired.output.snapshot
    if candidate { XCTAssertEqual(atEOF["playedSubmissions"], 1); XCTAssertGreaterThan(atEOF["renderedSubmissions", default: 0], 1) }
    else { XCTAssertEqual(atEOF["renderedSubmissions"], 0); XCTAssertGreaterThan(atEOF["playedSubmissions", default: 0], 1) }
    let late = try XCTUnwrap(retired.output.capturedPlayedCompletion)
    let eofPosition = host.initialState.timeline.positionMs
    host.suspend(); host.suspend()
    XCTAssertFalse(host.isActive); XCTAssertFalse(retired.engine.isRunning)
    XCTAssertFalse(retired.engine.attachedNodes.contains { $0 is AVAudioPlayerNode })
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    late(); late()
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(completions(), 1); XCTAssertTrue(callbacks.failures.isEmpty)
    host.resume(); host.resume()
    try await AppleHostCharacterizations.waitFor({ host.isActive && host.initialState.status == .paused }, timeout: 10)
    XCTAssertEqual(host.sessionId, session.sessionId)
    XCTAssertEqual(factory.entries.count, 2, "Foreground reuses session but rebuilds retired output once")
    let fresh = try XCTUnwrap(factory.entries.last), renderer = try XCTUnwrap(fresh.renderers.first)
    XCTAssertFalse(fresh === retired); XCTAssertFalse(host.playbackIntent)
    XCTAssertFalse(fresh.nativePlaying); XCTAssertEqual(completions(), 1)
    XCTAssertGreaterThanOrEqual(host.initialState.timeline.positionMs, eofPosition - 100)
    try await Task.sleep(nanoseconds: 150_000_000)
    let pausedPosition = host.initialState.timeline.positionMs
    let pausedModes = fresh.output.snapshot
    let pausedFrames = registry.positivePublicFrames
    late(); late()
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(host.initialState.status, .paused); XCTAssertFalse(host.playbackIntent)
    XCTAssertEqual(host.initialState.timeline.positionMs, pausedPosition)
    XCTAssertFalse(fresh.nativePlaying); XCTAssertEqual(fresh.output.snapshot, pausedModes)
    XCTAssertEqual(registry.positivePublicFrames, pausedFrames)
    XCTAssertEqual(completions(), 1); XCTAssertTrue(callbacks.failures.isEmpty)
    XCTAssertEqual(retired.output.snapshot, atEOF)
    let beforeReplay = fresh.output.snapshot
    try host.seekTo(command: .init(sessionId: session.sessionId, positionMs: 0))
    XCTAssertEqual(host.initialState.status, .paused)
    late()
    try await host.play(command: .init(sessionId: session.sessionId))
    try await AppleHostCharacterizations.waitFor({
      (fresh.output.renderedAudioTime?.sampleTime ?? 0) > 0 && host.initialState.timeline.positionMs >= 200
    }, timeout: 5)
    let position = host.initialState.timeline.positionMs
    let audioTime = try XCTUnwrap(fresh.output.renderedAudioTime).sampleTime
    late()
    try await AppleHostCharacterizations.waitFor({ host.initialState.timeline.positionMs >= position + 200 }, timeout: 3)
    let advancedAudioTime = try XCTUnwrap(fresh.output.renderedAudioTime).sampleTime
    XCTAssertGreaterThan(advancedAudioTime, audioTime)
    XCTAssertGreaterThan(registry.positivePublicFrames, pausedFrames)
    XCTAssertEqual(completions(), 1); XCTAssertEqual(host.initialState.status, .playing)
    XCTAssertTrue(callbacks.failures.isEmpty); XCTAssertEqual(renderer.usesSubmissionAnchor, candidate)
    try await AppleHostCharacterizations.waitFor({ host.initialState.status == .completed }, timeout: 10)
    XCTAssertEqual(completions(), 2); XCTAssertEqual(callbacks.frames.count, 1)
    XCTAssertTrue(callbacks.frames.allSatisfy { $0.sessionId == session.sessionId })
    XCTAssertEqual(host.sessionId, session.sessionId); XCTAssertEqual(factory.entries.count, 2)
    XCTAssertFalse(renderer.hasPendingPlayback); XCTAssertEqual(renderer.scheduledBytes, 0)
    XCTAssertFalse(retired.engine.isRunning); XCTAssertEqual(retired.output.snapshot, atEOF)
    XCTAssertTrue(callbacks.failures.isEmpty)
    let afterReplay = fresh.output.snapshot
    let played = afterReplay["playedSubmissions", default: 0] - beforeReplay["playedSubmissions", default: 0]
    let rendered = afterReplay["renderedSubmissions", default: 0] - beforeReplay["renderedSubmissions", default: 0]
    if candidate { XCTAssertEqual(played, 1); XCTAssertGreaterThan(rendered, 1) }
    else { XCTAssertGreaterThan(played, 1); XCTAssertEqual(rendered, 0) }
    XCTAssertEqual(renderer.usesSubmissionAnchor, candidate)
    host.close(); host.close()
    try await Task.sleep(nanoseconds: 150_000_000)
    func publications() -> [Int] { [callbacks.states.count, callbacks.deltas.count, callbacks.frames.count,
      callbacks.failures.count, callbacks.engines.count, callbacks.retries.count, registry.positivePublicFrames] }
    let beforeLate = publications()
    late(); late(); host.resume()
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(publications(), beforeLate); XCTAssertEqual(fresh.output.snapshot, afterReplay)
    XCTAssertTrue(host.disposed); XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    XCTAssertEqual(renderer.scheduledBytes, 0); XCTAssertFalse(renderer.hasPendingPlayback)
    XCTAssertTrue(factory.entries.allSatisfy { !$0.engine.isRunning && !$0.engine.attachedNodes.contains { $0 is AVAudioPlayerNode } })
    let data = try JSONSerialization.data(withJSONObject: ["candidate": candidate,
      "sessionId": session.sessionId, "outputsCreated": factory.entries.count,
      "initialModes": atEOF, "replayPlayedSubmissions": played, "replayRenderedSubmissions": rendered,
      "eofPositionMs": eofPosition, "foregroundPausedPositionMs": pausedPosition,
      "positionBeforeMs": position, "audioSampleBefore": audioTime, "audioSampleAfter": advancedAudioTime,
      "framesBeforeReplay": pausedFrames, "framesAfterReplay": registry.positivePublicFrames,
      "completed": completions(), "firstFrames": callbacks.frames.count,
      "ledgerAfterClose": ledger.snapshot.currentBytes,
      "publicationsBeforeLateCallback": beforeLate, "publicationsAfterLateCallback": publications(),
      "callbackObservation": "unobserved", "productionAdmission": false,
      "audioDiagnostics": factory.entries.map { $0.failureProbe.snapshot }], options: [.sortedKeys])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "decoded-eof-background-\(candidate)"; attachment.lifetime = .keepAlways; add(attachment)
  }

  @MainActor
  func testActualDecodedNaturalEOFFollowsNativeTailAndResourceRelease() async throws {
    try await verifyNaturalEOF(holdTail: false)
  }

  @MainActor
  func testActualDecodedEOFWaitsForHeldTailAndPausedResume() async throws {
    try await verifyNaturalEOF(holdTail: true)
  }

  @MainActor
  private func verifyNaturalEOF(holdTail: Bool) async throws {
    let probe = NaturalEOFProbe(hold: holdTail), factory = ReloadAudioFactory()
    factory.eofProbe = probe
    let ledger = YlManagedBufferLedger(), registry = ApplePublicationRegistry(), callbacks = AppleRecordingCallbacks()
    let host = YlApplePlayerHost(playerId: 741, suffix: "natural-eof-741",
      options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 50),
      services: registry.services(), callbacks: callbacks, bufferLedger: ledger,
      audioRendererFactory: factory, audioTerminalCandidateEnabled: true)
    var atCompletion: [String: Any]?
    callbacks.acknowledge = { [weak callbacks, weak factory] in
      guard atCompletion == nil, callbacks?.states.last?.status == .completed,
            let entry = factory?.entries.first, let renderer = entry.renderers.first else { return }
      atCompletion = ["uptime": ProcessInfo.processInfo.systemUptime,
        "audioOwnedBytes": renderer.scheduledBytes, "pending": renderer.hasPendingPlayback,
        "modes": entry.output.snapshot, "tail": probe.snapshot]
    }
    defer { callbacks.acknowledge = nil; host.close() }
    try host.attach(); try host.setVolume(volume: 0)
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("assets/test_media/format_matrix/mkv-avc-aac.mkv")
    var request = AppleHostFixture.request("natural-eof", url: fixture.path, format: .matroska, autoplay: true)
    request.source.kind = .file
    let session = try await host.load(request: request)
    let entry = try XCTUnwrap(factory.entries.first), renderer = try XCTUnwrap(entry.renderers.first)
    XCTAssertTrue(renderer.usesSubmissionAnchor)
    var late: (() -> Void)?
    if holdTail {
      try await AppleHostCharacterizations.waitFor({ probe.hasHeldCallback }, timeout: 10)
      XCTAssertEqual(entry.output.snapshot["playedSubmissions"], 1)
      XCTAssertEqual(entry.output.snapshot["playedCallbacks"], 1, "Tail was actually played natively before gating")
      try await Task.sleep(nanoseconds: 150_000_000)
      XCTAssertTrue(renderer.hasPendingPlayback)
      XCTAssertGreaterThan(renderer.scheduledBytes, 0)
      XCTAssertFalse(callbacks.states.contains { $0.status == .completed })
      try host.pause(command: .init(sessionId: session.sessionId))
      late = try XCTUnwrap(probe.release())
      try await AppleHostCharacterizations.waitFor({ !renderer.hasPendingPlayback })
      try await Task.sleep(nanoseconds: 150_000_000)
      XCTAssertEqual(renderer.scheduledBytes, 0)
      XCTAssertEqual(host.initialState.status, .paused)
      XCTAssertFalse(callbacks.states.contains { $0.status == .completed }, "Drain while paused must not invent completion")
      try await host.play(command: .init(sessionId: session.sessionId))
    }
    try await AppleHostCharacterizations.waitFor({ atCompletion != nil }, timeout: 10)
    let completed = try XCTUnwrap(atCompletion)
    let modes = try XCTUnwrap(completed["modes"] as? [String: Int])
    XCTAssertGreaterThan(modes["renderedSubmissions", default: 0], 1)
    XCTAssertEqual(modes["renderedCallbacks"], modes["renderedSubmissions"])
    XCTAssertEqual(modes["playedSubmissions"], 1)
    XCTAssertEqual(modes["playedCallbacks"], 1)
    XCTAssertEqual(completed["audioOwnedBytes"] as? Int, 0)
    XCTAssertEqual(completed["pending"] as? Bool, false)
    let tail = try XCTUnwrap(completed["tail"] as? [String: Any])
    let nativeTimes = try XCTUnwrap(tail["nativePlayedTimes"] as? [Double])
    let forwarded = try XCTUnwrap(tail["forwardedPlayedTimes"] as? [Double])
    XCTAssertEqual(nativeTimes.count, 1); XCTAssertEqual(forwarded.count, 1)
    XCTAssertLessThanOrEqual(try XCTUnwrap(nativeTimes.first), try XCTUnwrap(forwarded.first))
    XCTAssertLessThanOrEqual(try XCTUnwrap(forwarded.first), try XCTUnwrap(completed["uptime"] as? Double))
    XCTAssertEqual(callbacks.states.filter { $0.status == .completed }.count, 1)
    XCTAssertEqual(callbacks.frames.filter { $0.sessionId == session.sessionId }.count, 1)
    XCTAssertTrue(callbacks.failures.isEmpty)
    XCTAssertTrue(renderer.usesSubmissionAnchor)
    XCTAssertEqual(host.initialState.status, .completed)
    let afterCompletion = entry.output.snapshot
    late?(); late?()
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(callbacks.states.filter { $0.status == .completed }.count, 1)
    XCTAssertEqual(entry.output.snapshot, afterCompletion)
    XCTAssertFalse(renderer.hasPendingPlayback)
    XCTAssertEqual(renderer.scheduledBytes, 0)
    XCTAssertEqual(host.initialState.status, .completed)
    XCTAssertTrue(callbacks.failures.isEmpty)
    host.close()
    try await Task.sleep(nanoseconds: 150_000_000)
    func publicationCounts() -> [Int] {
      [callbacks.states.count, callbacks.deltas.count, callbacks.frames.count,
       callbacks.retries.count, callbacks.engines.count, callbacks.failures.count]
    }
    let closedPublications = publicationCounts()
    late?()
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(publicationCounts(), closedPublications, "Retired callback must not publish after close")
    XCTAssertTrue(host.disposed)
    XCTAssertEqual(renderer.scheduledBytes, 0)
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    XCTAssertFalse(renderer.hasPendingPlayback)
    XCTAssertFalse(entry.engine.isRunning)
    let data = try JSONSerialization.data(withJSONObject: ["holdTail": holdTail,
      "completion": completed, "completedPublications": callbacks.states.filter { $0.status == .completed }.count,
      "ledgerAfterClose": ledger.snapshot.currentBytes,
      "publicationsBeforeRetiredCallback": closedPublications, "publicationsAfterRetiredCallback": publicationCounts(),
      "audioDiagnostics": entry.failureProbe.snapshot], options: [.sortedKeys])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "decoded-natural-eof"; attachment.lifetime = .keepAlways; add(attachment)
  }

  @MainActor
  func testActualHostReloadRebuildsInvalidAudioAndFencesRetiredSession() async throws {
    try await verifyHostAudioReload(rejectFirstReload: false)
  }

  @MainActor
  func testActualHostRejectedAudioReloadStaysSafeAndLaterReloadRecovers() async throws {
    try await verifyHostAudioReload(rejectFirstReload: true)
  }

  @MainActor
  private func verifyHostAudioReload(rejectFirstReload: Bool) async throws {
    let factory = ReloadAudioFactory(), ledger = YlManagedBufferLedger()
    let registry = ApplePublicationRegistry(), callbacks = AppleRecordingCallbacks()
    let host = YlApplePlayerHost(playerId: 739, suffix: "audio-reload-739",
      options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 100),
      services: registry.services(), callbacks: callbacks, bufferLedger: ledger,
      audioRendererFactory: factory, audioTerminalCandidateEnabled: true)
    defer { host.close() }
    try host.attach(); try host.setVolume(volume: 0)
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("assets/test_media/format_matrix/continuous-avc-aac.mkv")
    func request(_ id: String, start: Int64 = 0) -> AppleLoadRequest {
      var value = AppleHostFixture.request(id, url: fixture.path,
        format: .matroska, autoplay: true, start: start)
      value.source.kind = .file
      return value
    }
    func loadExpected(_ value: AppleLoadRequest) async throws -> AppleLoadReply {
      do { return try await host.load(request: value) }
      catch {
        let failure = YlAppleSafeDiagnostics.failure(error, scope: .command)
        XCTFail("Explicit audio reload phase \(value.loadRequestId) failed with \(failure.code)")
        throw error
      }
    }
    let first = try await loadExpected(request("initial"))
    let retired = try XCTUnwrap(factory.entries.first)
    let renderer = try XCTUnwrap(retired.renderers.first)
    XCTAssertTrue(renderer.usesSubmissionAnchor)
    try await AppleHostCharacterizations.waitFor({
      retired.output.snapshot["renderedSubmissions", default: 0] > 0 &&
        (retired.output.renderedAudioTime?.sampleTime ?? 0) > 0 &&
        callbacks.frames.contains { $0.sessionId == first.sessionId }
    })
    let lateFailure = try XCTUnwrap(renderer.onOutputFailure)
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: retired.engine)
    try await AppleHostCharacterizations.waitFor({ callbacks.failures.count == 1 && !retired.engine.isRunning })
    XCTAssertEqual(callbacks.failures[0].sessionId, first.sessionId)
    XCTAssertEqual(callbacks.failures[0].failure.code, "render.audio_engine_failed")
    XCTAssertEqual(callbacks.failures[0].failure.category, .render)
    XCTAssertFalse(callbacks.failures[0].failure.retryable)
    XCTAssertTrue(callbacks.failures[0].failure.message.contains("reload the media"))
    XCTAssertEqual(host.initialState.status, .failed)
    XCTAssertThrowsError(try renderer.play())
    XCTAssertEqual(renderer.scheduledBytes, 0)
    XCTAssertNil(retired.output.renderedAudioTime)
    XCTAssertEqual(factory.entries.count, 1, "Failure must not automatically rebuild output")

    if rejectFirstReload {
      factory.invalidateNextPlay = true
      do {
        _ = try await host.load(request: request("rejected", start: 1000))
        XCTFail("A native output that cannot start must not commit")
      } catch let error as PigeonError {
        XCTAssertEqual(error.code, "render.audio_engine_failed")
        let failure = try XCTUnwrap(error.details as? AppleFailureMessage)
        XCTAssertEqual(failure.category, .render)
        XCTAssertFalse(failure.retryable)
        XCTAssertTrue(failure.message.contains("reload the media"))
      }
      XCTAssertEqual(host.sessionId, first.sessionId)
      XCTAssertEqual(factory.entries.count, 2, "Rejected Load must not silently reconstruct the failed prior graph")
      XCTAssertFalse(retired.engine.isRunning)
      XCTAssertFalse(factory.entries[1].engine.isRunning)
    }
    let next = try await loadExpected(request("reloaded", start: 1000))
    let fresh = try XCTUnwrap(factory.entries.last)
    XCTAssertFalse(fresh === retired)
    XCTAssertNotEqual(next.sessionId, first.sessionId)
    XCTAssertTrue(try XCTUnwrap(fresh.renderers.first).usesSubmissionAnchor)
    try await AppleHostCharacterizations.waitFor({
      fresh.output.snapshot["renderedSubmissions", default: 0] > 0 &&
        (fresh.output.renderedAudioTime?.sampleTime ?? 0) > 0 &&
        callbacks.frames.contains { $0.sessionId == next.sessionId } && host.initialState.timeline.positionMs >= 1000
    })
    let position = host.initialState.timeline.positionMs
    let nativeTime = try XCTUnwrap(fresh.output.renderedAudioTime).sampleTime
    let submissions = retired.output.snapshot
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: retired.engine)
    lateFailure(NativePlayerError(category: "render", code: "render.audio_engine_failed", message: "retired output"))
    do {
      try await host.play(command: .init(sessionId: first.sessionId))
      XCTFail("Old session command reached the replacement")
    } catch let error as PigeonError { XCTAssertEqual(error.code, "session.stale") }
    try await AppleHostCharacterizations.waitFor({ host.initialState.timeline.positionMs > position + 200 })
    XCTAssertGreaterThan(try XCTUnwrap(fresh.output.renderedAudioTime).sampleTime, nativeTime)
    XCTAssertEqual(callbacks.failures.count, 1)
    XCTAssertEqual(host.sessionId, next.sessionId)
    XCTAssertEqual(host.initialState.status, .playing)
    XCTAssertNil(host.initialState.failure)
    XCTAssertEqual(retired.output.snapshot["renderedSubmissions"], submissions["renderedSubmissions"])
    XCTAssertEqual(retired.output.snapshot["playedSubmissions"], submissions["playedSubmissions"])
    XCTAssertFalse(retired.engine.isRunning)
    XCTAssertTrue(fresh.engine.isRunning)
    let recoveredPosition = host.initialState.timeline.positionMs
    host.close()
    XCTAssertTrue(factory.entries.allSatisfy { !$0.engine.isRunning })
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    let data = try JSONSerialization.data(withJSONObject: [
      "rejectedFirstReload": rejectFirstReload, "outputsCreated": factory.entries.count,
      "distinctSession": first.sessionId != next.sessionId, "positionBeforeLateCallbackMs": position, "positionAfterLateCallbackMs": recoveredPosition,
      "ledgerAfterClose": ledger.snapshot.currentBytes,
      "audioDiagnostics": factory.entries.map { $0.failureProbe.snapshot }
    ], options: [.sortedKeys])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "explicit-audio-reload"; attachment.lifetime = .keepAlways; add(attachment)
  }

  func testActualTerminalAdapterGraphNotificationAndNativeStartFailure() throws {
    let graphProbe = AudioFailureProbe(), startProbe = AudioFailureProbe()
    let engine = AVAudioEngine(), output = IntegrationOutput(engine: AVAudioEngine(), failureProbe: startProbe)
    let driver = IntegrationOutput(engine: engine, failureProbe: graphProbe), ledger = YlManagedBufferLedger()
    let renderer = YlAudioRenderer(bufferScope: try ledger.makeScope(maxBytes: nil), converter: IntegrationPCM(), output: driver)
    renderer.setCompletionContext(terminalContext())
    try renderer.configure(stream: .init(codec: .aac, sampleRate: 48000, channelCount: 2, magicCookie: Data(), generation: 1))
    engine.mainMixerNode.outputVolume = 0
    let failed = expectation(description: "Native graph notification enters renderer failure chain")
    renderer.onOutputFailure = { graphProbe.record("rendererFailure", error: $0); XCTAssertEqual($0.code, "render.audio_engine_failed"); failed.fulfill() }
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    wait(for: [failed], timeout: 3)
    renderer.onOutputFailure = nil
    XCTAssertThrowsError(try renderer.play()) { XCTAssertEqual(($0 as? NativePlayerError)?.code, "render.audio_engine_failed") }
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    // This is an actual system adapter in an invalid native lifecycle, not a fake throw.
    let unavailable = YlAudioRenderer(converter: IntegrationPCM(), output: output)
    try unavailable.configure(stream: .init(codec: .aac, sampleRate: 48000, channelCount: 2, magicCookie: Data(), generation: 1))
    output.dispose()
    unavailable.onOutputFailure = { startProbe.record("rendererFailure", error: $0) }
    var startupRows: [[String: Any]] = []
    XCTAssertThrowsError(try startObservedPlayback(probe: startProbe, start: { try unavailable.play() },
      cleanup: { unavailable.dispose() }, observe: { phase in
        startupRows.append(["phase": phase, "audioDiagnostics": startProbe.snapshot])
      })) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "render.audio_engine_failed")
      let attachment = XCTAttachment(string: "category=render; code=render.audio_engine_failed; nativeOutputDisposed=true")
      attachment.lifetime = .keepAlways; self.add(attachment)
    }
    XCTAssertEqual(startupRows.compactMap { $0["phase"] as? String }, ["startupFailure", "disposed"])
    let savedStartup = try XCTUnwrap(startupRows.first?["audioDiagnostics"] as? [String: Any])
    let savedEvents = try XCTUnwrap(savedStartup["events"] as? [[String: Any]])
    XCTAssertEqual(savedEvents.last?["kind"] as? String, "startupFailure")
    XCTAssertEqual(savedEvents.last?["reason"] as? String, "startFailed")
    unavailable.dispose(); renderer.dispose()
    let graphEvents = try XCTUnwrap(graphProbe.snapshot["events"] as? [[String: Any]])
    let startEvents = try XCTUnwrap(startProbe.snapshot["events"] as? [[String: Any]])
    XCTAssertNotNil(graphEvents.first { $0["kind"] as? String == "configurationInvalidated" })
    XCTAssertFalse(graphEvents.contains { $0["kind"] as? String == "playFailed" })
    let graphFailure = try XCTUnwrap(graphEvents.first { $0["kind"] as? String == "rendererFailure" })
    let startFailure = try XCTUnwrap(startEvents.first { $0["kind"] as? String == "rendererFailure" })
    XCTAssertEqual(graphFailure["reason"] as? String, "configurationChanged")
    XCTAssertEqual(startFailure["reason"] as? String, "startFailed")
    XCTAssertNotEqual(graphFailure["message"] as? String, startFailure["message"] as? String)
    let notified = try XCTUnwrap(graphEvents.first { $0["kind"] as? String == "configurationInvalidated" })
    XCTAssertLessThan(try XCTUnwrap(notified["sequence"] as? Int), try XCTUnwrap(graphFailure["sequence"] as? Int))
    let failedStart = try XCTUnwrap(startEvents.first { $0["kind"] as? String == "playFailed" })
    XCTAssertLessThan(try XCTUnwrap(failedStart["sequence"] as? Int), try XCTUnwrap(startFailure["sequence"] as? Int))
    XCTAssertFalse(startEvents.contains { $0["kind"] as? String == "configurationInvalidated" })
    let data = try JSONSerialization.data(withJSONObject: ["configuration": graphProbe.snapshot, "start": startProbe.snapshot], options: [.sortedKeys])
    let detail = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    detail.name = "audio-failure-branches"; detail.lifetime = .keepAlways; add(detail)
  }

  func testAudioFailureProbeBoundsHistoryAndDoesNotPublishUntrustedErrorText() throws {
    let probe = AudioFailureProbe()
    for _ in 0..<40 { probe.record("playAttempt") }
    probe.record("playFailed", error: NSError(domain: "https://secret.invalid/token", code: -50,
      userInfo: [NSLocalizedDescriptionKey: "password-secret"]))
    probe.record("rendererFailure", error: NativePlayerError(category: "render", code: "render.audio_engine_failed",
      message: "https://secret.invalid/token", diagnostic: "password-secret"))
    let snapshot = probe.snapshot
    let events = try XCTUnwrap(snapshot["events"] as? [[String: Any]])
    XCTAssertEqual(snapshot["total"] as? Int, 42)
    XCTAssertEqual((snapshot["counts"] as? [String: Int])?["playAttempt"], 40)
    XCTAssertEqual(events.count, 32); XCTAssertEqual(events.first?["sequence"] as? Int, 11)
    XCTAssertEqual(events.last?["sequence"] as? Int, 42)
    XCTAssertEqual(events.last?["reason"] as? String, "unclassified")
    XCTAssertEqual(events.dropLast().last?["nativeDomain"] as? String, "other")
    XCTAssertEqual(events.dropLast().last?["nativeCode"] as? Int, -50)
    let text = String(decoding: try JSONSerialization.data(withJSONObject: snapshot), as: UTF8.self)
    XCTAssertFalse(text.contains("secret")); XCTAssertFalse(text.contains("password"))
  }

  @discardableResult
  private func runActualAdapter(count: Int, candidate: Bool, starvation: Bool = false,
                                pausedEOF: Bool = false, probeDirectory: String? = nil, resourceProbe: Bool = false,
                                captureAfterDrain: Bool = false) throws -> [String: Any] {
    let ledger = YlManagedBufferLedger(maxBytes: 196608), engine = AVAudioEngine()
    let output = IntegrationOutput(engine: engine), converter = IntegrationPCM(), markers = IntegrationMarkers()
    let renderer = YlAudioRenderer(maxScheduledDurationUs: 512016, maxScheduledBytes: 196608,
      bufferScope: try ledger.makeScope(maxBytes: 196608), converter: converter, output: output)
    renderer.setCompletionContext(terminalContext(enabled: candidate))
    try renderer.configure(stream: .init(codec: .aac, sampleRate: 48000, channelCount: 2, magicCookie: Data(), generation: 1))
    let player = try XCTUnwrap(engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
    engine.mainMixerNode.outputVolume = 0
    player.installTap(onBus: 0, bufferSize: 1024, format: converter.pcmFormat) { pcm, _ in markers.consume(pcm) }
    var tapInstalled = true
    defer { if tapInstalled { player.removeTap(onBus: 0) }; renderer.dispose() }
    let eventsLock = NSLock(); var failures: [String] = []; var anchors: [[Int64]] = []
    renderer.onOutputFailure = { error in eventsLock.withLock { failures.append(error.code) } }
    renderer.onFirstPCMSubmitted = { generation, pts in eventsLock.withLock { anchors.append([Int64(generation), pts]) } }
    var accepted = 0, finished = false, resumed = false
    var stalledAt: TimeInterval?
    let probeURL = probeDirectory.map { URL(fileURLWithPath: $0) }
    var nextSampleAt = ProcessInfo.processInfo.systemUptime + 2
    var recordedMidpoint = false
    var lostNativePlayback = false
    var resourcePhase = "configured"
    func probe(_ phase: String, waitForCollector: Bool = false) throws {
      guard let probeURL else { return }
      var info = task_vm_info_data_t()
      var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
      let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
          task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
        }
      }
      let row: [String: Any] = ["phase": phase, "uptime": ProcessInfo.processInfo.systemUptime,
        "pid": ProcessInfo.processInfo.processIdentifier, "generation": 1, "candidate": candidate,
        "accepted": accepted, "marker": markers.snapshot, "modes": output.snapshot,
        "captureAfterDrain": captureAfterDrain,
        "pending": renderer.hasPendingPlayback, "nativePlaying": player.isPlaying, "engineRunning": engine.isRunning,
        "ownedBytes": renderer.scheduledBytes,
        "ledgerBytes": ledger.snapshot.currentBytes, "ledgerPeak": ledger.snapshot.peakBytes,
        "mediaUs": renderer.renderedAudioTime?.sampleTime as Any? ?? NSNull(),
        "failures": eventsLock.withLock { failures }, "anchors": eventsLock.withLock { anchors },
        "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
        "rssBytes": status == KERN_SUCCESS ? info.resident_size as Any : NSNull(),
        "footprintBytes": status == KERN_SUCCESS ? info.phys_footprint as Any : NSNull()]
      let file = probeURL.appendingPathComponent("rows.jsonl")
      if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
      let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
      try handle.seekToEnd(); try handle.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10]))
      if waitForCollector {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        let ack = probeURL.appendingPathComponent(phase + ".ack")
        while !FileManager.default.fileExists(atPath: ack.path) && ProcessInfo.processInfo.systemUptime < deadline {
          RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ack.path), "Missing resource collector acknowledgement: \(phase)")
      }
    }
    try probe("configured", waitForCollector: resourceProbe)
    func pump(_ limit: Int) throws {
      while accepted < limit {
        var ordinal = Int64(accepted)
        let bytes = withUnsafeBytes(of: &ordinal) { Data($0) }
        let result = try autoreleasepool { try renderer.enqueue(packet: .init(data: bytes,
          ptsUs: Int64(accepted) * 1024 * 1_000_000 / 48000, durationUs: 21334, generation: 1)) }
        if result == .wouldExceedBytes || result == .wouldExceedDuration { break }
        XCTAssertTrue(result == .scheduled || result == .buffered); accepted += 1
      }
    }
    try pump(starvation ? 40 : count)
    try renderer.play()
    if pausedEOF {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
      renderer.pause(); renderer.finishInput(); finished = true
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
      XCTAssertTrue(renderer.hasPendingPlayback)
      try renderer.play()
    }
    let start = ProcessInfo.processInfo.systemUptime
    nextSampleAt = start + 2
    repeat {
      let now = ProcessInfo.processInfo.systemUptime
      if !lostNativePlayback && (!player.isPlaying || !engine.isRunning) {
        lostNativePlayback = true
        eventsLock.withLock { failures.append("probe.native_playback_stopped") }
      }
      if starvation && accepted == 40 && renderer.scheduledBytes <= 8192 && stalledAt == nil { stalledAt = now }
      if let stalledAt, now - stalledAt >= 0.3 { resumed = true }
      try pump(starvation && !resumed ? 40 : count)
      if resourceProbe && !captureAfterDrain && accepted >= count / 2 && !recordedMidpoint {
        recordedMidpoint = true; resourcePhase = "mid"; try probe(resourcePhase)
      }
      if now >= nextSampleAt { try probe("playing"); nextSampleAt = now + 5 }
      if accepted == count && !finished { renderer.finishInput(); finished = true }
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
    } while ProcessInfo.processInfo.systemUptime - start < Double(count * 1024) / 48000 + 10
      && (!finished || renderer.hasPendingPlayback || markers.snapshot["frames"]! < count * 1024)
    renderer.pause()
    try probe("drained", waitForCollector: resourceProbe)
    let row: [String: Any] = ["candidate": candidate, "buffers": count, "starvation": starvation,
      "pausedEOF": pausedEOF, "liveHeapCheckpointRequested": recordedMidpoint, "marker": markers.snapshot, "modes": output.snapshot,
      "anchors": eventsLock.withLock { anchors }, "failures": eventsLock.withLock { failures },
      "peakBytes": ledger.snapshot.peakBytes, "pending": renderer.hasPendingPlayback,
      "timerMaximumGapUs": renderer.tailObservationGapUs, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start]
    let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
    attachment.lifetime = .keepAlways; add(attachment)
    XCTAssertEqual(accepted, count); XCTAssertEqual(markers.snapshot["frames"], count * 1024)
    XCTAssertEqual(markers.snapshot["errors"], 0)
    if !starvation && !pausedEOF && !resourceProbe { XCTAssertEqual(markers.snapshot["interiorZeroFrames"], 0) }
    XCTAssertFalse(renderer.hasPendingPlayback); XCTAssertTrue(eventsLock.withLock { failures.isEmpty })
    XCTAssertLessThanOrEqual(ledger.snapshot.peakBytes, 196608)
    if candidate && !starvation && !resourceProbe {
      XCTAssertEqual(output.snapshot["playedSubmissions"], count == 0 ? 0 : 1)
      XCTAssertEqual(output.snapshot["renderedSubmissions"], max(0, count - 1))
    }
    if candidate && starvation { XCTAssertGreaterThan(output.snapshot["playedSubmissions"]!, 1) }
    player.removeTap(onBus: 0); tapInstalled = false
    renderer.dispose(); XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    try probe("disposed", waitForCollector: resourceProbe)
    if probeURL != nil { RunLoop.current.run(until: Date(timeIntervalSinceNow: 2)); try probe("disposedLater") }
    return row
  }

  private final class TerminalOutput: YlAudioOutputDriving {
    var supportsTerminalCompletion = true
    var volume: Float = 1
    var rate: Float = 1
    var renderedAudioTime: YlRenderedAudioTime?
    var modes: [YlAudioOutputCompletionMode] = []
    var timestamps: [Int64] = []
    var callbacks: [YlAudioOutputCallbacks] = []
    var onReset: (() -> Void)?
    var invalidation: (() -> Void)?
    var onInvalidationChange: (() -> Void)?
    func setInvalidationHandler(_ handler: (() -> Void)?) { invalidation = handler; onInvalidationChange?() }
    var synchronouslyComplete = false
    var onBuffer: ((YlScheduledAudioBuffer) -> Void)?
    var onSchedule: (() -> Void)?
    var playCount = 0
    func configure(sampleRate: Double, channelCount: Int) throws {}
    func schedule(_ buffer: YlScheduledAudioBuffer, completion: @escaping () -> Void) {
      onBuffer?(buffer)
      completion()
    }
    func schedule(_ buffer: YlScheduledAudioBuffer, mode: YlAudioOutputCompletionMode,
                  callbacks: YlAudioOutputCallbacks) {
      onBuffer?(buffer)
      modes.append(mode); timestamps.append(buffer.ptsUs); self.callbacks.append(callbacks)
      onSchedule?()
      if synchronouslyComplete {
        switch mode {
        case .renderedResource: callbacks.resourcesReleased()
        case .playedBack: callbacks.playedBack()
        }
      }
    }
    func play() throws { playCount += 1 }
    func pause() {}
    func reset() { onReset?() }
    func dispose() { reset() }
  }

  private func terminalRenderer(_ output: TerminalOutput, _ converter: LifetimePCMConverter,
    _ scope: YlManagedBufferScope, bytes: Int = 32768) throws -> YlAudioRenderer {
    let renderer = YlAudioRenderer(maxScheduledBytes: bytes, bufferScope: scope,
      converter: converter, output: output)
    renderer.setCompletionContext(terminalContext())
    try renderer.configure(stream: .init(codec: .aac, sampleRate: 48000,
      channelCount: 2, magicCookie: Data(), generation: 1))
    return renderer
  }

  private func enqueueTerminal(_ renderer: YlAudioRenderer, _ index: Int,
                               generation: UInt64 = 1) throws -> YlAudioEnqueueResult {
    try renderer.enqueue(packet: .init(data: Data(), ptsUs: Int64(index) * 21333,
      durationUs: 21333, generation: generation))
  }

  private func awaitTerminal(_ condition: @escaping () -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) {
    let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 3), .completed, file: file, line: line)
  }

  func testTerminalInitialPrerollTrimsSamplesAndKeepsAllocation() throws {
    for reserved in [false, true] {
      for (pts, removed, firstPTS) in [(Int64(-21000), 1008, Int64(0)), (-1, 1, 19)] {
        let ledger = YlManagedBufferLedger(), scope = try ledger.makeScope(maxBytes: nil)
        let converter = LifetimePCMConverter(), output = TerminalOutput()
        converter.markSamples = true; converter.reservedScope = reserved ? scope : nil
        var firstSamples: [[Float]] = [], lengths: [Int] = [], bytes: [Int] = [], durations: [Int64] = []
        output.onBuffer = { buffer in
          let pcm = buffer.payload as! AVAudioPCMBuffer
          lengths.append(Int(pcm.frameLength)); bytes.append(buffer.byteCount); durations.append(buffer.durationUs)
          if firstSamples.isEmpty { firstSamples = (0..<2).map { Array(UnsafeBufferPointer(start: pcm.floatChannelData![$0], count: Int(pcm.frameLength))) } }
        }
        let renderer = try terminalRenderer(output, converter, scope)
        defer { renderer.dispose() }
        XCTAssertEqual(try renderer.enqueue(packet: .init(data: Data(), ptsUs: pts, durationUs: 21333, generation: 1)), .buffered)
        XCTAssertTrue(output.modes.isEmpty); XCTAssertEqual(ledger.snapshot.currentBytes, 8192)
        _ = try enqueueTerminal(renderer, 0)
        XCTAssertEqual(output.modes, [.renderedResource]); XCTAssertEqual(output.timestamps, [firstPTS])
        XCTAssertEqual(lengths, [1024-removed]); XCTAssertEqual(bytes, [8192])
        XCTAssertEqual(durations, [Int64(1024-removed)*1_000_000/48000])
        for channel in 0..<2 { XCTAssertEqual(firstSamples[channel], (removed..<1024).map { Float(channel*10000+$0) }) }
        XCTAssertEqual(ledger.snapshot.currentBytes, 16384)
        output.callbacks[0].resourcesReleased(); awaitTerminal { ledger.snapshot.currentBytes == 8192 }
        renderer.finishInput(); XCTAssertEqual(output.modes, [.renderedResource,.playedBack])
        output.callbacks[1].playedBack(); awaitTerminal { !renderer.hasPendingPlayback }
        XCTAssertEqual(ledger.snapshot.currentBytes, 0)
      }
    }
  }

  func testTerminalFullyNegativePrerollDoesNotSubmitOrAnchor() throws {
    for pts in [Int64(-21333), -21334] {
      let ledger = YlManagedBufferLedger(), output = TerminalOutput(), converter = LifetimePCMConverter()
      let renderer = try terminalRenderer(output, converter, ledger.makeScope(maxBytes: nil))
      let anchorLock = NSLock(); var anchors: [Int64] = []
      renderer.onFirstPCMSubmitted = { _, pts in anchorLock.withLock { anchors.append(pts) } }
      XCTAssertEqual(try renderer.enqueue(packet: .init(data: Data(), ptsUs: pts, durationUs: 21333, generation: 1)), .buffered)
      XCTAssertTrue(output.modes.isEmpty); XCTAssertTrue(anchorLock.withLock { anchors.isEmpty })
      XCTAssertFalse(renderer.hasPendingPlayback); XCTAssertEqual(ledger.snapshot.currentBytes, 0)
      XCTAssertNil(converter.buffers[0].value)
      _ = try enqueueTerminal(renderer, 0); _ = try enqueueTerminal(renderer, 1)
      awaitTerminal { anchorLock.withLock { anchors == [0] } }
      XCTAssertEqual(output.modes, [.renderedResource])
      renderer.dispose(); XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    }
  }

  func testTerminalPrerollRejectsLaterAndOversizedNegativePrefix() throws {
    for priorPTS in [nil, Int64(0), Int64(-21333)] {
      let ledger = YlManagedBufferLedger(), output = TerminalOutput(), converter = LifetimePCMConverter()
      let renderer = try terminalRenderer(output, converter, ledger.makeScope(maxBytes: nil))
      if let priorPTS { _ = try renderer.enqueue(packet: .init(data: Data(), ptsUs: priorPTS, durationUs: 21333, generation: 1)) }
      let pts: Int64 = priorPTS == nil ? -21335 : -1
      _ = try renderer.enqueue(packet: .init(data: Data(), ptsUs: pts, durationUs: 21333, generation: 1))
      XCTAssertEqual(output.modes, priorPTS == 0 ? [.playedBack,.playedBack] : [.playedBack])
      renderer.reset(generation: 2)
      let priorCount = output.modes.count
      _ = try renderer.enqueue(packet: .init(data: Data(), ptsUs: -21333, durationUs: 21333, generation: 2))
      XCTAssertEqual(output.modes.count, priorCount)
      XCTAssertEqual(ledger.snapshot.currentBytes, 0)
      renderer.dispose(); XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    }
  }

  func testDisabledCandidatePreservesNegativePCM() throws {
    let converter = LifetimePCMConverter(), output = TerminalOutput()
    var pts: Int64?, frames: UInt32?
    output.onBuffer = { buffer in pts = buffer.ptsUs; frames = (buffer.payload as? AVAudioPCMBuffer)?.frameLength }
    let renderer = YlAudioRenderer(converter: converter, output: output)
    try renderer.configure(stream: .init(codec: .aac, sampleRate: 48000, channelCount: 2, magicCookie: Data(), generation: 1))
    _ = try renderer.enqueue(packet: .init(data: Data(), ptsUs: -21000, durationUs: 21333, generation: 1))
    XCTAssertEqual(pts, -21000); XCTAssertEqual(frames, 1024)
    renderer.dispose()
  }

  func testTerminalTimerSubmitsTailWithoutDisplayTicksAndCancelsOnPause() throws {
    let ledger = YlManagedBufferLedger(); let output = TerminalOutput()
    let renderer = try terminalRenderer(output, LifetimePCMConverter(), ledger.makeScope(maxBytes: nil))
    defer { renderer.dispose() }
    _ = try enqueueTerminal(renderer, 0)
    try renderer.play(); renderer.pause()
    let paused = expectation(description: "Pause holds the tail")
    paused.isInverted = true
    output.onSchedule = { paused.fulfill() }
    wait(for: [paused], timeout: 0.16)
    output.onSchedule = nil
    XCTAssertTrue(output.modes.isEmpty)
    let submitted = expectation(description: "Timer submits without display tick")
    let started = DispatchTime.now().uptimeNanoseconds
    output.onSchedule = {
      XCTAssertGreaterThanOrEqual(DispatchTime.now().uptimeNanoseconds - started, 100_000_000)
      submitted.fulfill()
    }
    try renderer.play()
    wait(for: [submitted], timeout: 3)
    renderer.pause() // Serializes with the timer before reading the fake output.
    XCTAssertEqual(output.modes, [.playedBack])
    XCTAssertGreaterThan(renderer.tailObservationGapUs, 0)
    let observation = XCTAttachment(string: "maximumTailObservationGapUs=\(renderer.tailObservationGapUs); targetIntervalUs=10000; thresholdUs=100000; noDisplayTicks=true")
    observation.lifetime = .keepAlways; add(observation)
    XCTAssertTrue(renderer.hasPendingPlayback)
    output.callbacks.first?.playedBack()
    awaitTerminal { !renderer.hasPendingPlayback }
  }

  func testTerminalEOFDuringPauseSubmitsWithoutStartingAndWaitsForPlayback() throws {
    let output = TerminalOutput(), ledger = YlManagedBufferLedger()
    let renderer = try terminalRenderer(output, LifetimePCMConverter(), ledger.makeScope(maxBytes: nil))
    defer { renderer.dispose() }
    _ = try enqueueTerminal(renderer, 0)
    try renderer.play(); renderer.pause()
    let starts = output.playCount
    renderer.finishInput()
    XCTAssertEqual(output.modes, [.playedBack]); XCTAssertEqual(output.playCount, starts)
    output.callbacks[0].resourcesReleased()
    XCTAssertTrue(renderer.hasPendingPlayback)
    try renderer.play()
    output.callbacks[0].playedBack()
    awaitTerminal { !renderer.hasPendingPlayback }
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }

  func testTerminalTimerDoesNotRetainRendererAndDisposalReleasesHeldPCM() throws {
    let output = TerminalOutput(), ledger = YlManagedBufferLedger()
    var renderer: YlAudioRenderer? = try terminalRenderer(output, LifetimePCMConverter(), ledger.makeScope(maxBytes: nil))
    weak var weakRenderer = renderer
    _ = try enqueueTerminal(renderer!, 0); try renderer!.play()
    renderer = nil
    XCTAssertNil(weakRenderer); XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    let unexpected = expectation(description: "Disposed timer cannot submit")
    unexpected.isInverted = true
    output.onSchedule = { unexpected.fulfill() }
    wait(for: [unexpected], timeout: 0.15)
  }

  func testTerminalInvalidationStopsBeforeReleaseAndCannotSilentlyPlayAgain() throws {
    let output = TerminalOutput(), ledger = YlManagedBufferLedger()
    let renderer = try terminalRenderer(output, LifetimePCMConverter(), ledger.makeScope(maxBytes: nil))
    defer { renderer.dispose() }
    _ = try enqueueTerminal(renderer, 0); _ = try enqueueTerminal(renderer, 1)
    let oldCallbacks = output.callbacks
    output.onInvalidationChange = { [weak renderer] in
      let read = DispatchSemaphore(value: 0)
      DispatchQueue.global().async { _ = renderer?.hasPendingPlayback; read.signal() }
      XCTAssertEqual(read.wait(timeout: .now() + 0.2), .success,
        "Output hooks must run outside the renderer state lock")
    }
    let stopped = expectation(description: "Invalid graph stopped with owners retained")
    output.onReset = {
      XCTAssertEqual(ledger.snapshot.currentBytes, 16384)
      stopped.fulfill()
    }
    let failed = expectation(description: "Invalid graph reports existing failure")
    renderer.onOutputFailure = { error in
      XCTAssertEqual(error.code, "render.audio_engine_failed")
      failed.fulfill()
    }
    try XCTUnwrap(output.invalidation)()
    wait(for: [stopped, failed], timeout: 3)
    output.onReset = nil
    renderer.onOutputFailure = nil
    XCTAssertEqual(output.modes, [.renderedResource], "Never submit held PCM on a broken graph")
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    XCTAssertThrowsError(try renderer.play()) { XCTAssertEqual(($0 as? NativePlayerError)?.code, "render.audio_engine_failed") }
    oldCallbacks.forEach { $0.resourcesReleased(); $0.playedBack() }
    XCTAssertFalse(renderer.hasPendingPlayback)
  }

  func testTerminalRendererHoldsTailAnchorsSubmissionAndWaitsForFence() throws {
    let ledger = YlManagedBufferLedger(); let scope = try ledger.makeScope(maxBytes: nil)
    let converter = LifetimePCMConverter(); let output = TerminalOutput()
    let renderer = try terminalRenderer(output, converter, scope)
    defer { renderer.dispose() }
    let anchored = expectation(description: "First actual PCM submitted")
    renderer.onFirstPCMSubmitted = { generation, pts in
      XCTAssertEqual(generation, 1); XCTAssertEqual(pts, 21333); anchored.fulfill()
    }
    XCTAssertTrue(renderer.usesSubmissionAnchor)
    XCTAssertEqual(try enqueueTerminal(renderer, 1), .buffered)
    XCTAssertEqual(output.timestamps, [])
    XCTAssertNil(renderer.renderedAudioTime)
    XCTAssertEqual(ledger.snapshot.currentBytes, 8192)
    XCTAssertTrue(renderer.hasPendingPlayback)
    XCTAssertEqual(try enqueueTerminal(renderer, 2), .scheduled)
    wait(for: [anchored], timeout: 3)
    XCTAssertEqual(output.timestamps, [21333])
    XCTAssertEqual(output.modes, [.renderedResource])
    renderer.finishInput()
    XCTAssertEqual(output.modes, [.renderedResource, .playedBack])
    XCTAssertEqual(try enqueueTerminal(renderer, 3), .staleGeneration)
    guard output.callbacks.count == 2 else { return XCTFail("Both real PCM submissions required") }
    output.callbacks[1].resourcesReleased() // Wrong type cannot retire the fence.
    output.callbacks[0].playedBack() // Wrong type cannot retire ordinary PCM.
    output.callbacks[0].resourcesReleased(); output.callbacks[0].resourcesReleased()
    awaitTerminal { renderer.scheduledBytes == 8192 }
    XCTAssertNil(converter.buffers[0].value)
    XCTAssertNotNil(converter.buffers[1].value)
    XCTAssertEqual(ledger.snapshot.currentBytes, 8192)
    XCTAssertTrue(renderer.hasPendingPlayback)
    output.callbacks[1].playedBack(); output.callbacks[1].playedBack()
    awaitTerminal { !renderer.hasPendingPlayback }
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    XCTAssertNil(converter.buffers[1].value)
  }

  func testTerminalRendererOutOfOrderFenceDoesNotHideOutstandingResources() throws {
    let ledger = YlManagedBufferLedger(); let output = TerminalOutput()
    let renderer = try terminalRenderer(output, LifetimePCMConverter(), ledger.makeScope(maxBytes: nil))
    defer { renderer.dispose() }
    _ = try enqueueTerminal(renderer, 0); _ = try enqueueTerminal(renderer, 1)
    renderer.finishInput()
    output.callbacks[1].playedBack()
    awaitTerminal { renderer.scheduledBytes == 8192 }
    XCTAssertTrue(renderer.hasPendingPlayback)
    output.callbacks[0].resourcesReleased()
    awaitTerminal { !renderer.hasPendingPlayback }
  }

  func testTerminalRendererPauseAndNodeTimeCannotCompletePlayback() throws {
    let ledger = YlManagedBufferLedger(); let output = TerminalOutput()
    output.renderedAudioTime = .init(sampleTime: 0, sampleRate: 1_000_000)
    let renderer = try terminalRenderer(output, LifetimePCMConverter(), ledger.makeScope(maxBytes: nil))
    defer { renderer.dispose() }
    _ = try enqueueTerminal(renderer, 0); _ = try enqueueTerminal(renderer, 1)
    renderer.finishInput(); try renderer.play()
    output.renderedAudioTime = .init(sampleTime: 42666, sampleRate: 1_000_000)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 42666)
    XCTAssertTrue(renderer.hasPendingPlayback)
    renderer.pause()
    output.renderedAudioTime = .init(sampleTime: 999999, sampleRate: 1_000_000)
    output.callbacks[0].resourcesReleased()
    awaitTerminal { renderer.scheduledBytes == 8192 }
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 42666)
    XCTAssertTrue(renderer.hasPendingPlayback)
    output.callbacks[1].playedBack()
    awaitTerminal { !renderer.hasPendingPlayback }
  }

  func testTerminalRendererCapacityFallbackAndEOFAlreadyPlayed() throws {
    let ledger = YlManagedBufferLedger(); let output = TerminalOutput()
    let renderer = try terminalRenderer(output, LifetimePCMConverter(), ledger.makeScope(maxBytes: nil), bytes: 8192)
    defer { renderer.dispose() }
    XCTAssertEqual(try enqueueTerminal(renderer, 0), .buffered)
    XCTAssertEqual(try enqueueTerminal(renderer, 1), .wouldExceedBytes)
    XCTAssertEqual(output.modes, [.playedBack])
    XCTAssertEqual(ledger.snapshot.currentBytes, 8192)
    output.callbacks[0].playedBack()
    awaitTerminal { renderer.scheduledBytes == 0 }
    XCTAssertEqual(try enqueueTerminal(renderer, 1), .scheduled)
    XCTAssertEqual(output.modes, [.playedBack, .playedBack])
    output.callbacks[1].playedBack()
    awaitTerminal { !renderer.hasPendingPlayback }
    renderer.finishInput()
    XCTAssertFalse(renderer.hasPendingPlayback)
  }

  func testTerminalRendererEmptySingleAndTimedFallback() throws {
    let ledger = YlManagedBufferLedger(); let output = TerminalOutput()
    let renderer = try terminalRenderer(output, LifetimePCMConverter(), ledger.makeScope(maxBytes: nil))
    defer { renderer.dispose() }
    renderer.finishInput(); XCTAssertFalse(renderer.hasPendingPlayback)
    renderer.reset(generation: 2)
    XCTAssertEqual(try enqueueTerminal(renderer, 0, generation: 2), .buffered)
    renderer.observeTailWait(playing: true, nowUs: 0)
    renderer.observeTailWait(playing: true, nowUs: 99999)
    XCTAssertTrue(output.modes.isEmpty)
    renderer.observeTailWait(playing: true, nowUs: 100000)
    XCTAssertEqual(output.modes, [.playedBack])
    renderer.finishInput(); XCTAssertTrue(renderer.hasPendingPlayback)
    output.callbacks[0].playedBack()
    awaitTerminal { !renderer.hasPendingPlayback }
  }

  func testTerminalRendererStopRetainsPCMUntilOutputStopsAndIsolatesOldCallbacks() throws {
    let ledger = YlManagedBufferLedger(); let output = TerminalOutput()
    let converter = LifetimePCMConverter()
    let renderer = try terminalRenderer(output, converter, ledger.makeScope(maxBytes: nil))
    _ = try enqueueTerminal(renderer, 0); _ = try enqueueTerminal(renderer, 1)
    let old = output.callbacks[0]
    output.onReset = {
      XCTAssertEqual(ledger.snapshot.currentBytes, 16384)
      XCTAssertNotNil(converter.buffers[0].value)
      old.resourcesReleased() // Must return without waiting for operations.
    }
    renderer.reset(generation: 2)
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    XCTAssertEqual(try enqueueTerminal(renderer, 0, generation: 2), .buffered)
    old.playedBack(); old.resourcesReleased()
    output.onReset = nil
    renderer.finishInput()
    output.callbacks.last!.playedBack()
    awaitTerminal { !renderer.hasPendingPlayback }
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    renderer.dispose()
  }

  func testTerminalRendererFormatChangeFallsBackWithoutLosingPCM() throws {
    for duration: Int64 in [0, 21333] {
      let ledger = YlManagedBufferLedger(); let output = TerminalOutput()
      let converter = LifetimePCMConverter()
      let renderer = try terminalRenderer(output, converter, ledger.makeScope(maxBytes: nil))
      defer { renderer.dispose() }
      _ = try enqueueTerminal(renderer, 0)
      converter.outputDuration = duration
      converter.outputFrames = duration == 0 ? 1024 : 2048
      XCTAssertEqual(try enqueueTerminal(renderer, 1), .scheduled)
      XCTAssertEqual(output.timestamps, [0, 21333])
      XCTAssertEqual(output.modes, [.playedBack, .playedBack])
      renderer.finishInput()
      output.callbacks[0].playedBack(); output.callbacks[1].playedBack()
      awaitTerminal { !renderer.hasPendingPlayback }
    }
  }

  func testTerminalRendererAdoptsConverterReservationWithoutDoubleCharging() throws {
    let ledger = YlManagedBufferLedger(); let scope = try ledger.makeScope(maxBytes: 8192)
    let converter = LifetimePCMConverter(); converter.reservedScope = scope
    let output = TerminalOutput(); let renderer = try terminalRenderer(output, converter, scope)
    defer { renderer.dispose() }
    XCTAssertEqual(try enqueueTerminal(renderer, 0), .buffered)
    XCTAssertEqual(ledger.snapshot.currentBytes, 8192)
    XCTAssertEqual(ledger.snapshot.peakBytes, 8192)
    renderer.finishInput(); output.callbacks[0].playedBack()
    awaitTerminal { !renderer.hasPendingPlayback }
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }

  func testTerminalRendererSynchronousCallbacksCanReenterControls() throws {
    let ledger = YlManagedBufferLedger(); let output = TerminalOutput()
    output.synchronouslyComplete = true
    let renderer = try terminalRenderer(output, LifetimePCMConverter(), ledger.makeScope(maxBytes: nil))
    defer { renderer.dispose() }
    let anchored = expectation(description: "Anchor delivered outside renderer locks")
    renderer.onFirstPCMSubmitted = { _, _ in renderer.pause(); anchored.fulfill() }
    _ = try enqueueTerminal(renderer, 0); _ = try enqueueTerminal(renderer, 1)
    renderer.finishInput()
    wait(for: [anchored], timeout: 3)
    awaitTerminal { !renderer.hasPendingPlayback }
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }


  func testTerminalRendererHeldPCMDoesNotCountAsSubmittedAudio() throws {
    let ledger = YlManagedBufferLedger(); let output = TerminalOutput()
    let renderer = try terminalRenderer(output, LifetimePCMConverter(), ledger.makeScope(maxBytes: nil))
    defer { renderer.dispose() }
    _ = try enqueueTerminal(renderer, 0)
    try renderer.play()
    XCTAssertNil(renderer.renderedAudioTime)
    XCTAssertEqual(renderer.underrunCount, 1)
    XCTAssertTrue(output.timestamps.isEmpty)
    renderer.finishInput()
    XCTAssertEqual(output.modes, [.playedBack])
    output.callbacks[0].playedBack()
    awaitTerminal { !renderer.hasPendingPlayback }
  }

  func testTerminalRendererRejectsBoundedTimelineAndUnsupportedOutput() throws {
    for bounded in [false, true] {
      let ledger = YlManagedBufferLedger(); let scope = try ledger.makeScope(maxBytes: nil)
      let output = TerminalOutput(); output.supportsTerminalCompletion = bounded
      if bounded {
        scope.configureTimeline(try .init(minDurationMs: 0, maxDurationMs: 500, maxBytes: 4 * 1024 * 1024))
      }
      let renderer = try terminalRenderer(output, LifetimePCMConverter(), scope)
      defer { renderer.dispose() }
      XCTAssertFalse(renderer.usesSubmissionAnchor)
    }
  }

  func testTerminalRendererReentrantPauseCancelsAutomaticRestart() throws {
    let ledger = YlManagedBufferLedger(); let output = TerminalOutput()
    let renderer = try terminalRenderer(output, LifetimePCMConverter(), ledger.makeScope(maxBytes: nil))
    defer { renderer.dispose() }
    try renderer.play()
    XCTAssertEqual(output.playCount, 1)
    _ = try enqueueTerminal(renderer, 0)
    output.onSchedule = { renderer.pause() }
    _ = try enqueueTerminal(renderer, 1)
    XCTAssertEqual(output.playCount, 1, "A completed pause must cancel the candidate automatic restart")
    XCTAssertTrue(renderer.hasPendingPlayback)
    XCTAssertEqual(ledger.snapshot.currentBytes, 16384, "Pause retains both owned PCM buffers")
    output.onSchedule = nil
    try renderer.play()
    XCTAssertEqual(output.playCount, 2, "Only explicit resume can start output again")
  }

  func testTerminalRendererReentrantResetCannotRestartStaleOutput() throws {
    let ledger = YlManagedBufferLedger(); let output = TerminalOutput()
    let renderer = try terminalRenderer(output, LifetimePCMConverter(), ledger.makeScope(maxBytes: nil))
    defer { renderer.dispose() }
    try renderer.play()
    XCTAssertEqual(output.playCount, 1)
    _ = try enqueueTerminal(renderer, 0)
    output.onSchedule = { renderer.reset(generation: 2) }
    _ = try enqueueTerminal(renderer, 1)
    XCTAssertEqual(output.playCount, 1, "The old submission cannot restart output after reset")
    XCTAssertFalse(renderer.hasPendingPlayback)
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }

  func testTerminalRendererPauseResetsTailWaitAndRateFallbackIsOneWay() throws {
    let ledger = YlManagedBufferLedger(); let output = TerminalOutput()
    let renderer = try terminalRenderer(output, LifetimePCMConverter(), ledger.makeScope(maxBytes: nil))
    defer { renderer.dispose() }
    _ = try enqueueTerminal(renderer, 0)
    renderer.observeTailWait(playing: true, nowUs: 0)
    renderer.pause()
    renderer.observeTailWait(playing: true, nowUs: 100000)
    XCTAssertTrue(output.modes.isEmpty)
    renderer.setRate(2)
    XCTAssertEqual(output.modes, [.playedBack])
    renderer.setRate(1)
    _ = try enqueueTerminal(renderer, 1)
    XCTAssertEqual(output.modes, [.playedBack, .playedBack])
    renderer.finishInput()
    output.callbacks.forEach { $0.playedBack() }
    awaitTerminal { !renderer.hasPendingPlayback }
  }

  func testTerminalRendererFormatAndTimestampMatrixFallsBack() throws {
    let formats = [
      AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!,
      AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!,
      AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!,
      AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: false)!
    ]
    for format in formats {
      let ledger = YlManagedBufferLedger(); let output = TerminalOutput()
      let converter = LifetimePCMConverter()
      let renderer = try terminalRenderer(output, converter, ledger.makeScope(maxBytes: nil))
      _ = try enqueueTerminal(renderer, 0)
      converter.format = format
      _ = try enqueueTerminal(renderer, 1)
      XCTAssertEqual(output.modes, [.playedBack, .playedBack])
      renderer.dispose()
      XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    }
    for pts in [Int64.min, Int64(-21335), Int64.max] {
      let ledger = YlManagedBufferLedger(); let output = TerminalOutput()
      let renderer = try terminalRenderer(output, LifetimePCMConverter(), ledger.makeScope(maxBytes: nil))
      _ = try renderer.enqueue(packet: .init(data: Data(), ptsUs: pts, durationUs: 21333, generation: 1))
      XCTAssertEqual(output.modes, [.playedBack])
      renderer.dispose()
    }
  }

  func testTerminalRendererRealConverterKeepsOneReservation() throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("assets/test_media/benchmark_sdr.mkv")
    var context: YLFMediaContextRef?; var info = YLFMediaInfo()
    XCTAssertEqual(fixture.withUnsafeFileSystemRepresentation { ylf_open_local($0, &context, &info) }, Int32(YLFResultOK))
    let opened = try XCTUnwrap(context)
    defer { ylf_close(&context) }
    var audio: YLFStreamInfo?
    for index in 0..<info.stream_count {
      var stream = YLFStreamInfo()
      if ylf_copy_stream_info(opened, index, &stream) == 0,
         Int(stream.kind) == YLFStreamAudio, Int(stream.codec) == YLFCodecAAC { audio = stream; break }
    }
    let stream = try XCTUnwrap(audio)
    XCTAssertEqual(stream.sample_rate, 48000); XCTAssertEqual(stream.channel_count, 2)
    var cookie = [UInt8](repeating: 0, count: ylf_stream_codec_config_size(opened, stream.index))
    XCTAssertEqual(ylf_copy_stream_codec_config(opened, stream.index, &cookie, cookie.count), 0)
    let ledger = YlManagedBufferLedger(); let scope = try ledger.makeScope(maxBytes: nil)
    let output = TerminalOutput(); let converter = YlAppleCompressedAudioConverter()
    let renderer = YlAudioRenderer(bufferScope: scope, converter: converter, output: output)
    defer { renderer.dispose() }
    renderer.setCompletionContext(terminalContext())
    try renderer.configure(stream: .init(codec: .aac, sampleRate: 48000,
      channelCount: 2, magicCookie: Data(cookie), generation: 1))
    for _ in 0..<256 {
      var packet: YLFPacketRef?
      guard ylf_read_packet(opened, &packet) == Int32(YLFResultOK), let item = packet else { break }
      defer { ylf_packet_release(&packet) }
      guard ylf_packet_stream_index(item) == stream.index, let bytes = ylf_packet_data(item) else { continue }
      _ = try renderer.enqueue(packet: .init(data: Data(bytes: bytes, count: ylf_packet_size(item)),
        ptsUs: ylf_packet_pts_us(item), durationUs: ylf_packet_duration_us(item), generation: 1))
      if renderer.scheduledBytes > 0 { break }
    }
    XCTAssertTrue(renderer.usesSubmissionAnchor)
    XCTAssertEqual(renderer.scheduledBytes, 8192)
    XCTAssertEqual(ledger.snapshot.categories[.scheduledAudio], 8192)
    XCTAssertTrue(output.modes.isEmpty, "Real converter output is held and charged once")
    renderer.finishInput()
    guard let completed = output.callbacks.first else { return XCTFail("Missing terminal PCM") }
    completed.playedBack()
    awaitTerminal { !renderer.hasPendingPlayback }
    XCTAssertEqual(ledger.snapshot.categories[.scheduledAudio] ?? 0, 0)
  }

  private final class WeakCompletionPayload {
    weak var value: NSObject?
    init(_ value: NSObject) { self.value = value }
  }

  func testCompletionGroupDropsUndeliveredPayloadIndependently() {
    var group: YlAudioCompletionGroup? = YlAudioCompletionGroup()
    var first: NSObject? = NSObject()
    var second: NSObject? = NSObject()
    weak var firstWeak = first
    weak var secondWeak = second
    var firstCompletion: (() -> Void)? = group!.makeCompletion { [value = first!] in
      withExtendedLifetime(value) {}
    }
    let secondCompletion = group!.makeCompletion { [value = second!] in
      withExtendedLifetime(value) {}
    }
    first = nil
    second = nil
    group = nil // Escaped callbacks keep only their own work alive.
    XCTAssertNotNil(firstWeak)
    XCTAssertNotNil(secondWeak)
    withExtendedLifetime(firstCompletion) {}
    firstCompletion = nil
    XCTAssertNil(firstWeak)
    XCTAssertNotNil(secondWeak)
    secondCompletion()
    XCTAssertNil(secondWeak)
    secondCompletion()
  }

  func testCompletionGroupConcurrentDuplicateDeliveryCanReenter() {
    let group = YlAudioCompletionGroup()
    let counterLock = NSLock()
    var deliveries = 0
    let completion = group.makeCompletion {
      counterLock.lock()
      deliveries += 1
      counterLock.unlock()
      let nested = group.makeCompletion {
        counterLock.lock()
        deliveries += 1
        counterLock.unlock()
      }
      nested()
      nested()
    }
    let finished = expectation(description: "Concurrent delivery finishes without lock reentry deadlock")
    DispatchQueue.global().async {
      DispatchQueue.concurrentPerform(iterations: 200) { _ in completion() }
      finished.fulfill()
    }
    wait(for: [finished], timeout: 5)
    counterLock.lock()
    let actual = deliveries
    counterLock.unlock()
    XCTAssertEqual(actual, 2)
  }

  func testCompletionGroupRetiresBodiesWhileAllCallbacksStayAlive() {
    let group = YlAudioCompletionGroup()
    var callbacks: [() -> Void] = []
    var references: [WeakCompletionPayload] = []
    for _ in 0..<1000 {
      let value = NSObject()
      references.append(WeakCompletionPayload(value))
      callbacks.append(group.makeCompletion { withExtendedLifetime(value) {} })
    }
    XCTAssertEqual(references.filter { $0.value != nil }.count, 1000)
    for callback in callbacks { callback() }
    XCTAssertEqual(references.filter { $0.value != nil }.count, 0)
    for callback in callbacks { callback() }
    withExtendedLifetime(callbacks) {}
  }

  func testPlayedSystemAudioReleasesPCMAndLedgerWhileOutputRemainsAlive() throws {
    let ledger = YlManagedBufferLedger()
    let scope = try ledger.makeScope(maxBytes: nil)
    let converter = LifetimePCMConverter()
    let output = YlSystemAudioOutput()
    let renderer = YlAudioRenderer(bufferScope: scope, converter: converter, output: output)
    defer { renderer.dispose() }
    try renderer.configure(stream: .init(codec: .aac, sampleRate: 48000,
      channelCount: 2, magicCookie: Data(), generation: 1))
    for index in 0..<20 {
      try autoreleasepool {
        XCTAssertEqual(try renderer.enqueue(packet: .init(data: Data(),
          ptsUs: Int64(index) * 21333, durationUs: 21333, generation: 1)), .scheduled)
      }
    }
    XCTAssertEqual(ledger.snapshot.currentBytes, 20 * 8192)
    try renderer.play()
    let deadline = Date(timeIntervalSinceNow: 4)
    while renderer.scheduledDurationUs > 0 && Date() < deadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    XCTAssertEqual(renderer.scheduledDurationUs, 0, "Real system completion callbacks must run")
    // Keep the output and its node alive; stop/dispose must not be required
    // to release PCM that has already completed playback.
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    XCTAssertEqual(converter.buffers.filter { $0.value != nil }.count, 0)
    withExtendedLifetime(output) {}
  }

  func testRetainedAudioCompletionReleasesPayloadAndCannotCompleteAnotherBuffer() throws {
    let ledger = YlManagedBufferLedger()
    let converter = LifetimePCMConverter()
    let output = TestAudioOutput()
    let renderer = YlAudioRenderer(bufferScope: try ledger.makeScope(maxBytes: nil),
      converter: converter, output: output)
    defer { renderer.dispose() }
    try renderer.configure(stream: .init(codec: .aac, sampleRate: 48000,
      channelCount: 2, magicCookie: Data(), generation: 1))
    XCTAssertEqual(try renderer.enqueue(packet: .init(data: Data(), ptsUs: 0,
      durationUs: 21333, generation: 1)), .scheduled)
    let first = output.retainedCompletion(at: 0)
    XCTAssertNotNil(converter.buffers[0].value)
    XCTAssertEqual(ledger.snapshot.currentBytes, 8192)
    first()
    XCTAssertNil(converter.buffers[0].value)
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    XCTAssertEqual(try renderer.enqueue(packet: .init(data: Data(), ptsUs: 21333,
      durationUs: 21333, generation: 1)), .scheduled)
    first() // The system may retain a callback; our completion must be one-shot.
    XCTAssertEqual(renderer.scheduledDurationUs, 21333)
    XCTAssertEqual(renderer.scheduledBytes, 8192)
    XCTAssertEqual(ledger.snapshot.currentBytes, 8192)
    output.retainedCompletion(at: 1)()
    XCTAssertNil(converter.buffers[1].value)
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }

  func testStaleAudioCompletionReleasesOnlyItsOwnPayloadAfterFlush() throws {
    let ledger = YlManagedBufferLedger()
    let converter = LifetimePCMConverter()
    let output = TestAudioOutput()
    let renderer = YlAudioRenderer(bufferScope: try ledger.makeScope(maxBytes: nil),
      converter: converter, output: output)
    defer { renderer.dispose() }
    try renderer.configure(stream: .init(codec: .aac, sampleRate: 48000,
      channelCount: 2, magicCookie: Data(), generation: 1))
    XCTAssertEqual(try renderer.enqueue(packet: .init(data: Data(), ptsUs: 0,
      durationUs: 21333, generation: 1)), .scheduled)
    renderer.flush()
    // A delayed output still owns its pending completion; flushing counters
    // is not permission to release memory that completion still retains.
    XCTAssertEqual(ledger.snapshot.currentBytes, 8192)
    XCTAssertEqual(try renderer.enqueue(packet: .init(data: Data(), ptsUs: 500000,
      durationUs: 21333, generation: 1)), .scheduled)
    XCTAssertEqual(ledger.snapshot.currentBytes, 16384)
    output.retainedCompletion(at: 0)()
    XCTAssertNil(converter.buffers[0].value)
    XCTAssertEqual(ledger.snapshot.currentBytes, 8192)
    XCTAssertEqual(renderer.scheduledBytes, 8192)
    XCTAssertEqual(renderer.scheduledDurationUs, 21333)
    renderer.dispose()
    output.retainedCompletion(at: 1)()
    XCTAssertNil(converter.buffers[1].value)
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }

  func testRenderedClockAtEndDoesNotDrainPendingPlayback() throws {
    let output = TestAudioOutput()
    let renderer = YlAudioRenderer(converter: TestAudioConverter(), output: output)
    defer { renderer.dispose() }
    output.renderedAudioTime = .init(sampleTime: 0, sampleRate: 48000)
    try renderer.configure(stream: .init(codec: .aac, sampleRate: 48000,
      channelCount: 2, magicCookie: Data(), generation: 1))
    XCTAssertEqual(try renderer.enqueue(packet: .init(data: Data(), ptsUs: 0,
      durationUs: 250000, generation: 1)), .scheduled)
    try renderer.play()
    renderer.finishInput()
    output.renderedAudioTime = .init(sampleTime: 48000, sampleRate: 48000)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 250000)
    XCTAssertTrue(renderer.hasPendingPlayback, "Rendered position is not an output completion")
    XCTAssertEqual(renderer.scheduledDurationUs, 250000)
    output.completeNextBuffer()
    XCTAssertFalse(renderer.hasPendingPlayback)
    XCTAssertNil(renderer.renderedAudioTime, "Finished input may leave the audio clock only after drain")
  }

  func testPausedPlaybackCompletionReleasesCapacityWithoutAdvancingPosition() throws {
    let output = TestAudioOutput()
    let renderer = YlAudioRenderer(converter: TestAudioConverter(), output: output)
    defer { renderer.dispose() }
    output.renderedAudioTime = .init(sampleTime: 0, sampleRate: 48000)
    try renderer.configure(stream: .init(codec: .aac, sampleRate: 48000,
      channelCount: 2, magicCookie: Data(), generation: 1))
    XCTAssertEqual(try renderer.enqueue(packet: .init(data: Data(), ptsUs: 0,
      durationUs: 250000, generation: 1)), .scheduled)
    try renderer.play()
    output.renderedAudioTime = .init(sampleTime: 4800, sampleRate: 48000)
    renderer.pause()
    renderer.setRate(2)
    output.renderedAudioTime = nil
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 100000)
    XCTAssertTrue(renderer.hasPendingPlayback)
    output.completeNextBuffer()
    XCTAssertFalse(renderer.hasPendingPlayback)
    XCTAssertEqual(renderer.scheduledBytes, 0)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 100000,
      "In-flight completion during pause must not move the media position")
  }

  func testZeroDurationStillRequiresCurrentGenerationPlaybackCompletion() throws {
    let output = TestAudioOutput()
    let converter = TestAudioConverter()
    converter.durationUs = 0
    let renderer = YlAudioRenderer(converter: converter, output: output)
    defer { renderer.dispose() }
    try renderer.configure(stream: .init(codec: .aac, sampleRate: 48000,
      channelCount: 2, magicCookie: Data(), generation: 1))
    XCTAssertEqual(try renderer.enqueue(packet: .init(data: Data(), ptsUs: 0,
      durationUs: 0, generation: 1)), .scheduled)
    XCTAssertEqual(renderer.scheduledDurationUs, 0)
    XCTAssertTrue(renderer.hasPendingPlayback, "Duration statistics cannot prove output drain")
    let stale = output.retainedCompletion(at: 0)
    renderer.flush()
    XCTAssertFalse(renderer.hasPendingPlayback)
    XCTAssertEqual(try renderer.enqueue(packet: .init(data: Data(), ptsUs: 100000,
      durationUs: 0, generation: 1)), .scheduled)
    stale()
    XCTAssertTrue(renderer.hasPendingPlayback, "Old completion must not drain the new generation")
    output.retainedCompletion(at: 1)()
    XCTAssertFalse(renderer.hasPendingPlayback)
  }

  func testResourceRetirementDoesNotCompletePlaybackOrReleaseTimingBudget() throws {
    let ledger = YlManagedBufferLedger()
    let scope = try ledger.makeScope(maxBytes: nil)
    scope.configureTimeline(try YlBoundedBufferPlan(minDurationMs: 0, maxDurationMs: 500, maxBytes: 16 * 1024 * 1024))
    let converter = LifetimePCMConverter()
    let output = SplitAudioOutput()
    let renderer = YlAudioRenderer(bufferScope: scope, converter: converter, output: output)
    defer { renderer.dispose() }
    try renderer.configure(stream: .init(codec: .aac, sampleRate: 48000,
      channelCount: 2, magicCookie: Data(), generation: 1))
    XCTAssertEqual(try renderer.enqueue(packet: .init(data: Data(), ptsUs: 0,
      durationUs: 21333, generation: 1)), .scheduled)
    try renderer.play()
    let underruns = renderer.underrunCount
    XCTAssertEqual(scope.bufferedDurationUs, 21333)
    output.callbacks[0].resourcesReleased()
    output.callbacks[0].resourcesReleased()
    XCTAssertEqual(scope.bufferedDurationUs, 21333)
    XCTAssertNil(converter.buffers[0].value, "Payload must not remain in playback-only metadata")
    XCTAssertEqual(renderer.scheduledBytes, 0)
    XCTAssertEqual(renderer.scheduledDurationUs, 21333)
    XCTAssertTrue(renderer.hasPendingPlayback)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 0)
    XCTAssertEqual(renderer.underrunCount, underruns)
    XCTAssertEqual(ledger.snapshot.currentBytes, 8192,
      "Conservative budget reservation must outlive early payload retirement")
    output.callbacks[0].playedBack()
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    XCTAssertEqual(scope.bufferedDurationUs, 0)
    XCTAssertEqual(renderer.scheduledDurationUs, 0)
    XCTAssertFalse(renderer.hasPendingPlayback)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 21333)
    output.callbacks[0].playedBack()
    XCTAssertEqual(renderer.underrunCount, underruns + 1)
  }

  func testSplitCompletionKeepsOldGenerationIsolatedAndDisposesOwnPayload() throws {
    let ledger = YlManagedBufferLedger()
    let converter = LifetimePCMConverter()
    let output = SplitAudioOutput()
    let renderer = YlAudioRenderer(bufferScope: try ledger.makeScope(maxBytes: nil),
      converter: converter, output: output)
    try renderer.configure(stream: .init(codec: .aac, sampleRate: 48000,
      channelCount: 2, magicCookie: Data(), generation: 1))
    XCTAssertEqual(try renderer.enqueue(packet: .init(data: Data(), ptsUs: 0,
      durationUs: 21333, generation: 1)), .scheduled)
    renderer.flush()
    XCTAssertEqual(try renderer.enqueue(packet: .init(data: Data(), ptsUs: 500000,
      durationUs: 21333, generation: 1)), .scheduled)
    output.callbacks[0].resourcesReleased()
    XCTAssertNil(converter.buffers[0].value)
    XCTAssertEqual(renderer.scheduledBytes, 8192)
    XCTAssertEqual(ledger.snapshot.currentBytes, 16384)
    output.callbacks[0].playedBack()
    XCTAssertEqual(ledger.snapshot.currentBytes, 8192)
    XCTAssertTrue(renderer.hasPendingPlayback)
    XCTAssertEqual(renderer.scheduledDurationUs, 21333)
    renderer.dispose()
    output.callbacks[1].playedBack() // Complete directly, without a resource notification.
    XCTAssertNil(converter.buffers[1].value)
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    output.callbacks[1].resourcesReleased()
    XCTAssertFalse(renderer.hasPendingPlayback)
  }

  func testSplitResourceRetirementWhilePausedDoesNotAdvanceMediaTime() throws {
    let output = SplitAudioOutput()
    let renderer = YlAudioRenderer(converter: TestAudioConverter(), output: output)
    defer { renderer.dispose() }
    output.renderedAudioTime = .init(sampleTime: 0, sampleRate: 48000)
    try renderer.configure(stream: .init(codec: .aac, sampleRate: 48000,
      channelCount: 2, magicCookie: Data(), generation: 1))
    XCTAssertEqual(try renderer.enqueue(packet: .init(data: Data(), ptsUs: 0,
      durationUs: 250000, generation: 1)), .scheduled)
    try renderer.play()
    output.renderedAudioTime = .init(sampleTime: 4800, sampleRate: 48000)
    renderer.pause(); renderer.setRate(2); output.renderedAudioTime = nil
    output.callbacks[0].resourcesReleased()
    XCTAssertTrue(renderer.hasPendingPlayback)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 100000)
    output.callbacks[0].playedBack()
    XCTAssertFalse(renderer.hasPendingPlayback)
    XCTAssertEqual(renderer.renderedAudioTime?.sampleTime, 100000)
  }

  func testSplitCompletionConcurrentDuplicatesAndReentryAreOneShot() {
    let group = YlAudioCompletionGroup()
    let countLock = NSLock()
    var resources = 0; var playback = 0; var reentries = 0
    let callbacks = group.makeCallbacks(releaseResources: {
      countLock.lock(); resources += 1; countLock.unlock()
      group.makeCompletion { countLock.lock(); reentries += 1; countLock.unlock() }()
    }, completePlayback: {
      countLock.lock(); playback += 1; countLock.unlock()
    })
    let finished = expectation(description: "Concurrent split completions finish")
    DispatchQueue.global().async {
      DispatchQueue.concurrentPerform(iterations: 200) { index in
        if index.isMultiple(of: 2) { callbacks.resourcesReleased() }
        else { callbacks.playedBack() }
      }
      finished.fulfill()
    }
    wait(for: [finished], timeout: 5)
    countLock.lock(); let actual = [resources, playback, reentries]; countLock.unlock()
    XCTAssertEqual(actual, [1, 1, 1])
  }

  func testDroppingSplitCallbacksReleasesOnlyTheirOwnUndeliveredPayload() {
    let group = YlAudioCompletionGroup()
    var first: NSObject? = NSObject(); var second: NSObject? = NSObject()
    weak var firstWeak = first; weak var secondWeak = second
    var callbacks: YlAudioOutputCallbacks? = group.makeCallbacks(
      releaseResources: { [value = first!] in withExtendedLifetime(value) {} },
      completePlayback: {})
    let other = group.makeCallbacks(
      releaseResources: { [value = second!] in withExtendedLifetime(value) {} },
      completePlayback: {})
    first = nil; second = nil
    XCTAssertNotNil(firstWeak); XCTAssertNotNil(secondWeak)
    withExtendedLifetime(callbacks) {}
    callbacks = nil
    XCTAssertNil(firstWeak); XCTAssertNotNil(secondWeak)
    other.playedBack()
    XCTAssertNil(secondWeak)
  }

  private final class SplitAudioOutput: YlAudioOutputDriving {
    var volume: Float = 1
    var rate: Float = 1
    var renderedAudioTime: YlRenderedAudioTime?
    var callbacks: [YlAudioOutputCallbacks] = []
    func configure(sampleRate: Double, channelCount: Int) throws {}
    func schedule(_ buffer: YlScheduledAudioBuffer, completion: @escaping () -> Void) {
      XCTFail("Renderer must submit distinct resource and playback callbacks")
    }
    func schedule(_ buffer: YlScheduledAudioBuffer, callbacks: YlAudioOutputCallbacks) {
      self.callbacks.append(callbacks)
    }
    func play() throws {}
    func pause() {}
    func reset() {}
    func dispose() {}
  }

  private final class WeakPCM {
    weak var value: AVAudioPCMBuffer?
    init(_ value: AVAudioPCMBuffer) { self.value = value }
  }
  private final class LifetimePCMConverter: YlAudioPacketConverting {
    var reservedScope: YlManagedBufferScope?
    var reservesOutputBuffers: Bool { reservedScope != nil }
    var markSamples = false
    var outputFrames: AVAudioFrameCount = 1024
    var outputDuration: Int64 = 21333
    var format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
      channels: 2, interleaved: YlAudioFormatPolicy.usesInterleavedPCM)!
    var buffers: [WeakPCM] = []
    var pcmFormat: AVAudioFormat? { format }
    func configure(stream: YlAudioStreamConfiguration) throws {}
    func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate {
      .init(durationUs: outputDuration, byteCount: Int(outputFrames) * 8)
    }
    func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer? {
      let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputFrames)!
      pcm.frameLength = outputFrames
      for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
        if let bytes = buffer.mData { memset(bytes, 0, Int(buffer.mDataByteSize)) }
      }
      if markSamples, let channels = pcm.floatChannelData {
        for channel in 0..<2 { for frame in 0..<Int(outputFrames) { channels[channel][frame] = Float(channel*10000+frame) } }
      }
      buffers.append(WeakPCM(pcm))
      let token = try reservedScope?.require(category: .scheduledAudio, bytes: Int(outputFrames) * 8)
      _ = token?.carryTiming(ptsUs: packet.ptsUs, durationUs: outputDuration)
      return .init(reservation: token, payload: pcm, ptsUs: packet.ptsUs, durationUs: outputDuration,
        byteCount: Int(outputFrames) * 8, generation: packet.generation)
    }
  }

  func testOpusTrimmingPrerollResetAndSafeFailure() throws {
    let converter = YlAppleCompressedAudioConverter()
    let head = Data([79,112,117,115,72,101,97,100,1,2,56,1,128,187,0,0,0,0,0])
    try converter.configure(stream: .init(codec: .opus, sampleRate: 48000,
      channelCount: 2, magicCookie: head, generation: 9))
    let silence = Data([0xfc, 0xff, 0xfe])
    let first = YlCompressedAudioPacket(data: silence, ptsUs: -6500,
      durationUs: Int64.max, generation: 9, skipSamples: 312)
    let estimate = converter.estimateOutput(for: first)
    XCTAssertEqual(estimate.byteCount, 5760 * 8)
    XCTAssertEqual(estimate.durationUs, 120000)
    let trimmed = try XCTUnwrap(converter.convert(packet: first))
    XCTAssertEqual(trimmed.ptsUs, 0)
    XCTAssertEqual(trimmed.durationUs, 13500)
    XCTAssertEqual((trimmed.payload as? AVAudioPCMBuffer)?.frameLength, 648)
    XCTAssertEqual(trimmed.generation, 9)
    converter.reset()
    XCTAssertNil(try converter.convert(packet: .init(data: silence, ptsUs: 1000000,
      durationUs: 20000, generation: 9, presentationStartUs: 1030000)))
    let cut = try XCTUnwrap(converter.convert(packet: .init(data: silence, ptsUs: 1020000,
      durationUs: 20000, generation: 9, discardSamples: 48, presentationStartUs: 1030000)))
    XCTAssertEqual(cut.ptsUs, 1030000)
    XCTAssertEqual(cut.durationUs, 9000)
    XCTAssertEqual((cut.payload as? AVAudioPCMBuffer)?.frameLength, 432)
    converter.reset()
    let reset = try XCTUnwrap(converter.convert(packet: first))
    XCTAssertEqual((reset.payload as? AVAudioPCMBuffer)?.frameLength, 648)
    XCTAssertThrowsError(try converter.convert(packet: .init(data: Data([0xff,0x3f]),
      ptsUs: 0, durationUs: 20000, generation: 9))) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "decoder.audio_opus_failed")
    }
    for channels in [0,3] {
      XCTAssertThrowsError(try converter.configure(stream: .init(codec: .opus,
        sampleRate: 48000, channelCount: channels, magicCookie: head, generation: 9)))
    }
  }

  func testFLACDecodesExactMono16AndStereo24SamplesIncludingShortFinalPacketAndReset() throws {
    // Owned integer ramps, 1000 frames at 48 kHz. Host FFmpeg 8.0.1 FLAC,
    // -frame_size 576; expected PCM is independently computed below.
    let fixtures: [(Int, Int, String, [(Int, String)])] = [
      (16, 1, "AkACQAACEwAClQu4APAAAAPoTudV7k7wxTEl3pHrSkX4Fg==", [(576, "//gqCADmQIrQ5z+pFQ2ZLlypMiRfddbZXXVTIKFHFFOV3X2zZGTGNc95BJJRZhhpx54gqJEkTKFCpYuXMGTJo2cOHTfP35AQkJERkhISkxOTlBSUlRlZYWFpcXl5gYmJkZmhoamxubmcHJydHZ4eHp8fn4gEIhEQjEgkOikYjkckEkkkolkwmE0nE8nlAolI6kUyoVCqViuVywWS0Wi2XC4XS8Xzr5gMJiMRjMhkMpmM5nNBpNRqNZsO2G03G83nA4nI5HM6HQ6nY7nc8Hk70ej2fD4fT8fz+IAgiEIQhiIIgiiMhDkORBEkURRFkYRhGkcR5HkgSJJEkSaEoShKksS5LkwTJNE0TZOE4TpPE+T5QIUJRFEUZSFIUpTFOU5UFSVRVFWVhWFahXFeV5YFiWRZFmWhaFqWxbluXBcl0XSF2XheF6Xxfl+YBgmEYRhmIYhimMY5joZBkmUZRlmYZhmmcZ5nmgaJpGkaZqGohqmsa5rmwbJtG0bZuG4bpvG+b5wHCcSHEcZyHIcpzHOc50HSdR1HWdh2Hadx3od54HieR5Hmeh6Hqex7nufB8n0fR9n4n+P6/z/v+QAgJAiBEDIIQQgpBiDkHIQQlKFEKIWQwhhDSHEPIeRAiJEiJETIoRQipFkouRcjBGSNEaI2RwjhHSPEfI+SAkJIiREjZJIkkSSpJkk6ScAAAACTfArgUwJ4E8CWBHAhgQwH4DsBsxYk880skl7VrT/7cnMVmchCmOcQUYYcIXjrz75AiSJEyhQqWLlzBkrRo2cOHTx8+ICIkJCYoKCosZOTlBSVFRWWFhaXF5eYGJkZGZmhoamxubnBydHR2eHh6fH5+IDoJCIRDIhEIpGI5HJBJJRKJZMJhNBLVQ=="), (424, "//h6CAEBp8VA1LDnP4oN/T2+Pr8/kAgkIhkQiEUjEckEklEsmE0nE8oFEpFMqFUrFcsFktFsuF0vF8wGExGMyGUzGc0Gk1Gs2I7Xc73g8Xk83o9Xs93w+X0+34/X8/yAIEgiDIQhSGIciCJIoiyMI0jiOI8kCRJIkyUJUliXJgmSaJsnCdJ4nygQoSiKMpClKYpyoKkqirKwrSuK8sCxLIsy0LUti3LguS6LsvC9L4vzAMEwjDMQxTGMcyDJMoyzMM0zjPNA0TSNM1DVQ1jXNg2TZNo2zcN03jfOA4TiOM5DlOY5zoOk6jrOw7TuO88DxPI8z0PU9j3Pg+T6Ps/D9P4/xACBEEIMQghRDCHEQIlKFELIYQ0hxDyIERIkRMihFSLEXIwRkjRGyOEdI8R8kBISREjJGSQkpJiTkoJSSolZLCWkuJeTAmJMiZk0JqTYm5OCck6J2Twnq6fKfqgKgqhKhqiKiqjKjqkKkqlKlqmKmqnKnqoKoqpKpqqKqqrKrqsKsqtKtquKuqvKvqwAAAAAAAAAAn9ibiZiZiXiViTiRiPiNiLiJiHiFiDiBh/h9Z7eXd1c3FvbWtpZ2VjYV9dW1lXVVNRT01LSUdFQ0H/99+e/Xnx37denPlx4b923Zr1aa43210zyyxwwRSTUVWXYZabcdefIESRMoVLFzBk0bOHTx8QERITFBUWFxgZGgABr")]),
      (24, 2, "AkACQAADnwAEzQu4A3AAAAPoBAnqjMe7WPsv7qc4O7XlIA==", [(576, "//gqHADlToXuAIYM74Yr3oZKzYZpvIaIq4anmobGieYtjJLmtdrdCbSduaJHftugZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWTpjEh5jjdpkCZZkhVJlAQ5lfMpl+IZmdEOYtjZLktdrdCbSduaJHftugZSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJS6Ks="), (424, "//h6HAEBp/pOy4fAy6avy8Wey+SNzAN8zCJrzEFazGBJ5i2Dkwq1kt2Js8264kW+3SBnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJyTt5eR959Nt6cJd67FN7aA9748t8X4d820OYtu5JUtlrdEbLdv+I2Pu+gZOTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTtk6")]),
    ]
    for (bits, channels, encodedCookie, packets) in fixtures {
      let converter = YlAppleCompressedAudioConverter()
      let cookie = try XCTUnwrap(Data(base64Encoded: encodedCookie))
      let stream = YlAudioStreamConfiguration(codec: .flac, sampleRate: 48_000,
        channelCount: channels, magicCookie: cookie, generation: 3)
      try converter.configure(stream: stream)
      for _ in 0..<2 {
        var sampleIndex = 0
        for (frames, encoded) in packets {
          let packet = YlCompressedAudioPacket(data: try XCTUnwrap(Data(base64Encoded: encoded)),
            ptsUs: Int64(sampleIndex) * 1_000_000 / 48_000,
            durationUs: Int64.max, generation: 3)
          let estimate = converter.estimateOutput(for: packet)
          XCTAssertLessThanOrEqual(estimate.byteCount, 577 * channels * 4)
          XCTAssertLessThanOrEqual(estimate.durationUs, 12_000)
          let result = try XCTUnwrap(converter.convert(packet: packet))
          let pcm = try XCTUnwrap(result.payload as? AVAudioPCMBuffer)
          XCTAssertEqual(Int(pcm.frameLength), frames)
          XCTAssertEqual(pcm.frameCapacity, UInt32(frames))
          XCTAssertEqual(result.ptsUs, packet.ptsUs)
          XCTAssertEqual(result.generation, 3)
          XCTAssertEqual(result.byteCount, frames * channels * 4)
          let samples = try XCTUnwrap(pcm.floatChannelData)
          for frame in 0..<frames {
            for channel in 0..<channels {
              let index = sampleIndex + frame
              let integer = bits == 16 ? (index * 137) % 60000 - 30000
                : (index * 7919 + channel * 1234567) % 16000000 - 8000000
              let expected = Float(integer) / (bits == 16 ? 32768 : 8388608)
              let actual = pcm.format.isInterleaved ? samples[0][frame * channels + channel] : samples[channel][frame]
              XCTAssertEqual(actual, expected, accuracy: 0.0000001)
            }
          }
          sampleIndex += frames
        }
        XCTAssertEqual(sampleIndex, 1000)
        converter.reset()
      }
      for badPacket in [Data(), Data([0xff, 0xf8, 0x70, 0x08, 0, 0xff, 0xff, 0]),
                        Data([0xff, 0xf8, 0x70, 0x08, 0xff, 0, 0])] {
        XCTAssertThrowsError(try converter.convert(packet: YlCompressedAudioPacket(
          data: badPacket, ptsUs: 0, durationUs: 0, generation: 3)))
      }
      for badCookie in [Data(), cookie.dropLast(), cookie + Data([0])] {
        XCTAssertThrowsError(try converter.configure(stream: YlAudioStreamConfiguration(
          codec: .flac, sampleRate: 48_000, channelCount: channels,
          magicCookie: Data(badCookie), generation: 3)))
      }
      for (rate, count) in [(44_100.0, channels), (48_000.0, 6)] {
        XCTAssertThrowsError(try converter.configure(stream: YlAudioStreamConfiguration(
          codec: .flac, sampleRate: rate, channelCount: count, magicCookie: cookie, generation: 3)))
      }
      for offset in [0, 1, 10, 11, 12, 13] {
        var invalid = cookie
        invalid[offset] = offset == 13 ? (invalid[offset] ^ 0x10) : 0xff
        XCTAssertNil(YlFLACConfiguration(stream: YlAudioStreamConfiguration(
          codec: .flac, sampleRate: 48_000, channelCount: channels, magicCookie: invalid, generation: 3)),
          "Mutated STREAMINFO offset \(offset)")
      }
    }
  }


  func testDolbySurroundConvertsCenterWithoutChangingSpeakerOrderAndResets() throws {
    // Synthetic center-only 440 Hz tones, AC-3 / E-AC-3, 48 kHz 5.1(side).
    let fixtures: [(YlAudioCodec, String)] = [
      (.ac3, "C3f6xhRA6/hAPv4Afw8PCEBAQfw8PD+Hh4fw8PDVXVeG+/51fPnz58+fPnz4g0Tx/IkOu+fPnz4/51fPnz58+fPnz4/51fPnz58+fPnz4/51fPnz58+fPnz4/51y/whAgQIECBIAAAAAG+fPG2222228ePHju8gVWXWXW0rDfDTPR8M4sx2lal4f/pdJCaKBoiN2DioVUAAAAN8+fNtttttt48ePHdwAAAA3z582222223jx48d3AAAADfPm2222228ePHju4AAAAbwHwEACob58/fPgAAAABvn0BttttttvHjx47uvbR1l1l1lxrdIHOadej48Vip8s9VcIz9czAvfSwR9Gp1eAAAAG+fPm2222228ePHju4AAAAb58+bbbbbbbx48eO7gAAABvnzbbbbbbePHjx3cAAAAN4D4AAAAAAAAN8+eNtttttt48ePHd8A8AWk2k2kymAmm2kPR9drPCizv0ErSxEToRIEVGQRUxAAAAAA3z582222223jx48d3AAAADfPnzbbbbbbePHjx3cAAAAN8+bbbbbbbx48eO7gAAABvAfAAAAAAAABvnz9ttttttvHjx47ulwnMususustpukDXoV+eOIUBOLYFXsgrgZ00KFy2AvUKqAAAAG+fPm2222228ePHju4AAAAb58+bbbbbbbx48eO7gAAABvnzbbbbbbePHjx3cAAAAN4D4CABUN8+fV3wAAAAA3z5+2222223jx48d3dty6y4040404mc1oVsvxzFw15WXZSZoxdFhftW0i+Kq82sAAAADfPm2222228ePHju4AAAAb58+bbbbbbbx48eO7gAAABvnz5ttttttvHjx47uAAAAGD4AAAAAAAAN8+eNtttttt48ePHd6o9kXE2oyoyo6cBNAki8f4j2WWoJtGZ7wuwXqKUIwyJKxAAAAAA3z5ttttttvHjx47uAAAAG+fPm2222228ePHju4AAAAb58+bbbbbbbx48eO7gAAABgAAAAAAAAAAAAAAAAAAAAAAF2m"),
      (.eac3, "C3cBfz+HwAAgkAAAAgAAAAQYHwB+Hh4BAQEH4eHh+Hh4fh4eFV4b7/nV8+fPnz58+fPiDRPH8iQ6758+fPj/nV8+fPnz58+fPj/nV8+fPnz58+fPj/nV8+fPnz58+fPj/nUAAAAAG+fPn7bbbbbePHjx4XXL9y/em9uHmHmHmXWXWPhnFmO0rUvD/9LpITP0DREbsBxaMqsCpAAAADfPnz5tttttvHjx48AAAADfPnz5tttttvHjx48AAAADfPnzbbbbbePHjx4AAAAG8AVDfPn758AAAABvnz56222223jx48ee1LXSlz9ze3N6dHmHmHmXa9Hx4rFT5Z6q4Rn65mAXvpYIvY2K2coFVIAAAAN8+fPm222228ePHjwAAAAN8+fPm222228ePHjwAAAAN8+fNttttt48ePG4AAAAbwAAAAABvnz58222223jx48eIQA2jMBjMM7szqwNgNiLST0fXazwos79BK0sRE6FEgRUZAhXipqBSwAAAAAN8+fPm222228ePHjwAAAAN8+fPm222228ePHjwAAAAN8+fNttttt48ePG4AAAAbwAAAAABvnz5+222223jx48eZ9pH6TV4muDa3N8w8w8w6wr88cQoCcWwKvZBXAzmaFC5bAF49o0sQKkAAAAN8+fPm222228ePHjwAAAAN8+fPm222228ePHjwAAAAN8+fNttttt48ePG4AAAAbwBUN8+fV3wAAAAG+fPnrbbbbbePHjx4Dj9y/cvnR6dHp0eWXWXWXbZfjmLhrysuykzRi6LIv2raRfhWKWjWtakAAAAN8+fPm222228ePHjwAAAAN8+fPm222228ePHjwAAAAN8+fNttttt48ePG4AAAAbwAAAAABvnz5+222223jx48eHQL2l8Ji8QqtDq0O4i4i5FJF4/xHsstQTaMz3hdhL1FKEUKSOyagUsAAAAADfPnz5tttttvHjx48AAAADfPnz5tttttvHjx48AAAADfPnzbbbbbePHjxuAAAAG8AAAAAAAE9R")
    ]
    for (codec, encoded) in fixtures {
      let converter = YlAppleCompressedAudioConverter()
      try converter.configure(stream: YlAudioStreamConfiguration(
        codec: codec, sampleRate: 48_000, channelCount: 6,
        magicCookie: Data(), generation: 1, channelMask: 0x60f
      ))
      let data = try XCTUnwrap(Data(base64Encoded: encoded))
      for _ in 0..<2 {
        var decoded: YlScheduledAudioBuffer?
        for index in 0..<4 {
          decoded = try converter.convert(packet: YlCompressedAudioPacket(
            data: data, ptsUs: Int64(index) * 32_000, durationUs: 32_000, generation: 1))
          if decoded != nil { break }
        }
        let buffer = try XCTUnwrap(decoded)
        let pcm = try XCTUnwrap(buffer.payload as? AVAudioPCMBuffer)
        XCTAssertGreaterThan(pcm.frameLength, 0)
        XCTAssertEqual(pcm.format.channelCount, 6)
        let samples = try XCTUnwrap(pcm.floatChannelData)
        var energy = [Double](repeating: 0, count: 6)
        for frame in 0..<Int(pcm.frameLength) {
          for channel in 0..<6 {
            let value = pcm.format.isInterleaved ? samples[0][frame * 6 + channel] : samples[channel][frame]
            energy[channel] += Double(value * value)
          }
        }
        XCTAssertGreaterThan(energy[2], 1, "Center signal must remain in the center channel")
        for channel in [0, 1, 3, 4, 5] { XCTAssertLessThan(energy[channel], energy[2] * 0.001) }
        XCTAssertEqual(buffer.byteCount, Int(pcm.frameLength) * 6 * MemoryLayout<Float>.size)
        converter.reset()
      }
    }
  }

  func testDolbyAudioRejectsMissingOrMismatchedSpeakerLayouts() {
    for codec: YlAudioCodec in [.ac3, .eac3] {
      for mask: UInt64 in [0, 3, 0x8000000000000000] {
        let converter = YlAppleCompressedAudioConverter()
        XCTAssertThrowsError(try converter.configure(stream: YlAudioStreamConfiguration(
          codec: codec, sampleRate: 48_000, channelCount: 6,
          magicCookie: Data(), generation: 1, channelMask: mask)))
      }
    }
  }

  func testDolbySurroundSystemOutputCanSwitchToAAC() throws {
    let renderer = YlAudioRenderer()
    defer { renderer.dispose() }
    for codec: YlAudioCodec in [.ac3, .eac3, .aac] {
      try renderer.configure(stream: YlAudioStreamConfiguration(
        codec: codec, sampleRate: 48_000, channelCount: 6,
        magicCookie: codec == .aac ? Data([0x11, 0xb0]) : Data(),
        generation: 1, channelMask: 0x60f))
    }
  }


  func testAACSurroundRejectsMissingOrMismatchedChannelConfiguration() {
    for cookie in [Data(), Data([0x11]), Data([0x11, 0x90])] {
      let converter = YlAppleCompressedAudioConverter()
      XCTAssertThrowsError(try converter.configure(stream: YlAudioStreamConfiguration(
        codec: .aac, sampleRate: 48_000, channelCount: 6,
        magicCookie: cookie, generation: 1
      )))
    }
  }

  func testAACSurroundConvertsAllSixChannelsWithExplicitLayout() throws {
    let converter = YlAppleCompressedAudioConverter()
    try converter.configure(stream: YlAudioStreamConfiguration(
      codec: .aac, sampleRate: 48_000, channelCount: 6,
      magicCookie: Data([0x11, 0xb0]), generation: 1
    ))
    // Synthetic AAC-LC 5.1 silence, generated from anullsrc (48 kHz).
    let data = Data([0x01, 0x18, 0x20, 0x01, 0x08, 0x80, 0x23, 0x04, 0x60,
                     0x23, 0x10, 0x04, 0x60, 0x8c, 0x0c, 0x23, 0x00, 0x00, 0xe0])
    var decoded: YlScheduledAudioBuffer?
    for index in 0..<4 {
      decoded = try converter.convert(packet: YlCompressedAudioPacket(
        data: data, ptsUs: Int64(index) * 21_333, durationUs: 21_333, generation: 1
      ))
      if decoded != nil { break }
    }
    let buffer = try XCTUnwrap(decoded)
    let pcm = try XCTUnwrap(buffer.payload as? AVAudioPCMBuffer)
    XCTAssertEqual(pcm.frameLength, 1024)
    XCTAssertEqual(pcm.format.channelCount, 6)
    XCTAssertEqual(pcm.format.channelLayout?.layoutTag, kAudioChannelLayoutTag_AAC_5_1)
    XCTAssertEqual(buffer.byteCount, 1024 * 6 * MemoryLayout<Float>.size)
  }

  func testAACSurroundConfiguresTheSystemOutputAndCanReconfigureStereo() throws {
    let renderer = YlAudioRenderer()
    defer { renderer.dispose() }
    try renderer.configure(stream: YlAudioStreamConfiguration(
      codec: .aac, sampleRate: 48_000, channelCount: 6,
      magicCookie: Data([0x11, 0xb0]), generation: 1
    ))
    try renderer.configure(stream: YlAudioStreamConfiguration(
      codec: .aac, sampleRate: 44_100, channelCount: 2,
      magicCookie: Data([0x12, 0x10]), generation: 2
    ))
  }

  private final class TestAudioConverter: YlAudioPacketConverting {
    var durationUs: Int64 = 250_000
    func configure(stream: YlAudioStreamConfiguration) throws {}

    func estimateOutput(
      for packet: YlCompressedAudioPacket
    ) -> YlAudioBufferEstimate {
      YlAudioBufferEstimate(durationUs: durationUs, byteCount: 1_000)
    }

    func convert(
      packet: YlCompressedAudioPacket
    ) throws -> YlScheduledAudioBuffer? {
      YlScheduledAudioBuffer(
        payload: NSObject(),
        ptsUs: packet.ptsUs,
        durationUs: durationUs,
        byteCount: 1_000,
        generation: packet.generation
      )
    }
  }


  private final class TestAudioOutput: YlAudioOutputDriving {
    var volume: Float = 1
    var rate: Float = 1
    var renderedAudioTime: YlRenderedAudioTime? = nil
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

    func retainedCompletion(at index: Int) -> () -> Void { completions[index] }

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

    XCTAssertEqual(tracks[0].codec, "AAC")
    XCTAssertEqual(tracks[1].codec, "MP3")
    XCTAssertEqual(tracks[1].isSelected, true)
  }

}
