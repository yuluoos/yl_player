import XCTest
import AVFoundation
import Network
@testable import yl_player_apple

@MainActor
final class AppleHostFixture {
  let output = AppleTestTexture()
  let callbacks = AppleRecordingCallbacks()
  let av = AVPlayer()
  let host: YlApplePlayerHost
  init(commandCoordinator: YlAsyncCommandCoordinator = YlAsyncCommandCoordinator(),
       beforeFallbackConstruction: ((YlPlaybackBackend) throws -> Void)? = nil,
       slotCompatibility: YlAppleCompatibility? = nil,
       bufferLedger: YlManagedBufferLedger = YlManagedBufferLedger(),
       videoSessionFactory: YlVTSessionFactory? = nil,
       hardwareEvidenceStage: YlHardwareEvidencePreparation = .init(),
       audioOwnership: YlPlayerAudioOwnership? = nil) {
    host = YlApplePlayerHost(playerId: 91, suffix: "fixture-91",
      options: .init(decoderPolicy: .systemDefault, audioPolicy: audioOwnership == nil ? .appManaged : .pluginManagedMediaPlayback, positionUpdateIntervalMs: 100),
      services: .init(platform: .current, textureOutput: output,
        makeDisplayDriver: { AppleClockDisplay(onTick: $0) }), callbacks: callbacks, avPlayer: av, commandCoordinator: commandCoordinator,
      beforeFallbackConstruction: beforeFallbackConstruction, slotCompatibility: slotCompatibility, bufferLedger: bufferLedger,
      videoSessionFactory: videoSessionFactory, hardwareEvidenceStage: hardwareEvidenceStage, audioOwnership: audioOwnership)
  }
  static func request(_ id: String, url: String = "https://example.test/media.mp4",
      format: AppleMediaFormat = .mp4, autoplay: Bool = false, start: Int64? = nil,
      buffer: AppleBufferKind = .automatic, width: Int64? = nil) -> AppleLoadRequest {
    .init(loadRequestId: id, source: .init(kind: .network, locator: url, intent: .onDemand, format: format),
      options: .init(autoplay: autoplay, startPositionMs: start,
        bufferStrategy: .init(kind: buffer), videoConstraints: .init(maxWidth: width)))
  }
  func load(_ request: AppleLoadRequest) async throws -> AppleLoadReply {
    do { return try await host.load(request: request) }
    catch let error as PigeonError { throw NSError(domain: error.code, code: 1) }
  }
  func settle() async { for _ in 0..<12 { await Task.yield() } }
}

/// Each transferred XCTest method calls a production typed-host assertion body.
/// Shared bodies preserve identical iOS/macOS invariants without a copied owner.
@MainActor
enum AppleHostCharacterizations {
  static func volumeAndOptions(_ test: XCTestCase) async throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.setVolume(volume: 0.2)
    var firstRequest = AppleHostFixture.request("a", start: 1000, buffer: .lowLatency, width: 640)
    firstRequest.options.videoConstraints.maxHeight = 360
    let first = try await f.host.load(request: firstRequest)
    let item = try XCTUnwrap(f.av.currentItem)
    XCTAssertEqual(f.av.volume, 0.2, accuracy: 0.001)
    XCTAssertEqual(item.preferredForwardBufferDuration, 2)
    XCTAssertFalse(f.av.automaticallyWaitsToMinimizeStalling)
    XCTAssertEqual(item.preferredMaximumResolution.width, 640)
    do { _ = try await f.host.load(request: AppleHostFixture.request("bad", url: "", autoplay: true, start: 9000, buffer: .smoothPlayback, width: 1280)); XCTFail("Invalid candidate committed") } catch {}
    XCTAssertEqual(f.host.sessionId, first.sessionId)
    XCTAssertTrue(f.av.currentItem === item)
    XCTAssertEqual(item.preferredForwardBufferDuration, 2)
    XCTAssertFalse(f.av.automaticallyWaitsToMinimizeStalling)
    XCTAssertEqual(item.preferredMaximumResolution.width, 640)
    XCTAssertEqual(f.av.volume, 0.2, accuracy: 0.001)
    try await f.host.stop()
    _ = try await f.host.load(request: AppleHostFixture.request("next", buffer: .smoothPlayback))
    XCTAssertEqual(f.av.volume, 0.2, accuracy: 0.001)
    XCTAssertEqual(f.av.currentItem?.preferredMaximumResolution, .zero)
    XCTAssertEqual(f.av.currentItem?.preferredForwardBufferDuration, 30)
    XCTAssertTrue(f.av.automaticallyWaitsToMinimizeStalling)
  }

  static func persistedQuality(_ test: XCTestCase) async throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    let loaded = try await f.host.load(request: AppleHostFixture.request("a"))
    try f.host.setVideoConstraints(command: .init(sessionId: loaded.sessionId,
      constraints: .init(maxHeight: 720)))
    XCTAssertEqual(f.av.currentItem?.preferredMaximumResolution.height, 720)
    f.host.suspend(); f.host.resume()
    await f.settle()
    XCTAssertEqual(f.av.currentItem?.preferredMaximumResolution.height, 720)
  }

  static func generations(_ test: XCTestCase) async throws {
    let first = YlBackendGeneration.next(), second = YlBackendGeneration.next()
    XCTAssertGreaterThan(second, first)
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    let a = try await f.host.load(request: AppleHostFixture.request("a"))
    await f.settle()
    let revision = f.callbacks.states.last?.revision ?? 0
    let sequence = f.callbacks.states.last?.sequence ?? 0
    let b = try await f.host.load(request: AppleHostFixture.request("b"))
    await f.settle()
    XCTAssertNotEqual(a.sessionId, b.sessionId)
    XCTAssertEqual(f.callbacks.states.last?.sessionId, b.sessionId)
    XCTAssertGreaterThan(f.callbacks.states.last?.revision ?? 0, revision)
    XCTAssertGreaterThan(f.callbacks.states.last?.sequence ?? 0, sequence)
    XCTAssertThrowsError(try f.host.pause(command: .init(sessionId: a.sessionId)))
  }

  static func fullState(_ test: XCTestCase) async throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    let id = YlAppleSessionIdentity(sessionId: "apple-7-s9", loadRequestId: "request-9")
    let value = f.host.encode(.init(identity: id, revision: 9, sequence: 10,
      snapshot: .characterizationReady, failure: nil))
    XCTAssertEqual(value.sessionId, id.sessionId)
    XCTAssertEqual(value.loadRequestId, id.loadRequestId)
    XCTAssertEqual(value.revision, 9)
    XCTAssertEqual(value.sequence, 10)
    XCTAssertEqual(value.status, .ready)
    XCTAssertEqual(value.decoderMode, .unknown)
    // The generated record owns the shape; schema version is negotiated by Create.
    let registry = YlApplePlayerRegistry(makeServices: { _ in YlAppleRegistryTests.services() },
      makeCallbacks: { _ in AppleRecordingCallbacks() }, installHost: { _, _ in })
    defer { registry.detach() }
    let created = try registry.create(request: .init(schemaMajor: 2,
      options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 500)))
    XCTAssertEqual(created.schemaMajor, 2)
    XCTAssertEqual(created.spiMajor, 2)
    XCTAssertFalse(created.channelSuffix.isEmpty)
    XCTAssertNotNil(registry.host(for: created.channelSuffix))
  }

  static func delta(_ test: XCTestCase) async throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    let id = YlAppleSessionIdentity(sessionId: "apple-9-s42", loadRequestId: "request")
    f.host.send(.delta(.init(identity: id, revision: 42, sequence: 43, occurredAtMs: 100),
      previousRevision: 41, .init(positionMs: 1000, bufferedPositionMs: 3000,
        isAtLiveEdge: false, liveOffsetMs: 2000, metrics: .init(droppedVideoFrames: 2))))
    await f.settle()
    let value = try XCTUnwrap(f.callbacks.deltas.last)
    XCTAssertEqual(value.sessionId, id.sessionId)
    XCTAssertEqual(value.previousRevision, 41)
    XCTAssertEqual(value.revision, 42)
    XCTAssertEqual(value.sequence, 43)
    XCTAssertEqual(value.positionMs, 1000)
    XCTAssertEqual(value.bufferedPositionMs, 3000)
    XCTAssertEqual(value.liveOffsetMs, 2000)
    XCTAssertEqual(value.metrics?.droppedVideoFrames, 2)
    XCTAssertFalse(Mirror(reflecting: value).children.contains { $0.label == "capabilities" })
  }

  static func metrics(_ test: XCTestCase) async throws {
    let metrics = YlBackendStateEncoder.fallbackMetrics(openDurationMs: 20,
      firstFrameDurationMs: 40, bufferedDurationMs: 100, bufferedBytes: 4096,
      droppedVideoFrames: 7, audioUnderruns: 1, reconnectCount: 2)
    let typed = YlApplePlayerHost.metrics(metrics)
    XCTAssertEqual(typed.droppedVideoFrames, 7)
    XCTAssertEqual(typed.loadToReadyMs, 20)
    XCTAssertEqual(typed.loadToFirstFrameMs, 40)
    XCTAssertEqual(typed.managedBufferedDurationMs, 100)
    XCTAssertEqual(typed.managedBufferedBytes, 4096)
    XCTAssertEqual(typed.audioUnderruns, 1)
    XCTAssertEqual(typed.reconnectCount, 2)
    XCTAssertFalse(Mirror(reflecting: typed).children.contains { $0.label == "droppedFrames" })
  }

  static func capabilities(_ test: XCTestCase, hevc: Bool = true) async throws {
    let native = YlBackendStateEncoder.capabilities(hardwareH264: true, hardwareHevc: hevc)
    let typed = YlApplePlayerRegistry.capabilities(native, platform: .current)
    XCTAssertEqual(typed.hardwareVideoCodecs, hevc ? ["video/avc", "video/hevc"] : ["video/avc"])
    XCTAssertEqual(typed.maxConcurrentVideoDecoders, 1)
    XCTAssertEqual(Set(native.supportedFormats), Set(["automatic", "hls", "httpFlv", "mp4", "mov", "matroska", "flv"]))
    let f = AppleHostFixture(); defer { f.host.close() }
    for format: AppleMediaFormat in [.automatic, .hls, .mp4, .mov, .matroska, .flv] {
      var request = AppleHostFixture.request("assessment", format: format)
      if format == .flv { request.source.intent = .live }
      let reply = try f.host.assess(request: .init(source: request.source, options: request.options))
      XCTAssertNotEqual(reply.outcome, .incompatible, "Legacy supported format \(format) must remain routable")
    }
  }

  static func channels(_ test: XCTestCase) async throws {
    var installed = [String]()
    var callbackSuffixes = [String]()
    let registry = YlApplePlayerRegistry(makeServices: { _ in YlAppleRegistryTests.services() },
      makeCallbacks: { suffix in callbackSuffixes.append(suffix); return AppleRecordingCallbacks() },
      installHost: { suffix, host in if host != nil { installed.append(suffix) } })
    defer { registry.detach() }
    let request = AppleCreateRequest(schemaMajor: 2,
      options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 500))
    let a = try registry.create(request: request), b = try registry.create(request: request)
    XCTAssertNotEqual(a.channelSuffix, b.channelSuffix)
    XCTAssertEqual(installed, [a.channelSuffix, b.channelSuffix])
    XCTAssertEqual(callbackSuffixes, installed)
    XCTAssertNotNil(registry.host(for: a.channelSuffix))
    XCTAssertNotNil(registry.host(for: b.channelSuffix))
  }
}

/// A real HTTP preparation can be held after its request arrives. This controls
/// input availability without replacing the native reader/preparation pipeline.
final class AppleHeldMediaServer {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "yl.test.task7.held-http")
  private var waiting = [NWConnection]()
  private var released = false
  var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/candidate.mkv")! }
  init(onRequest: @escaping () -> Void) throws {
    listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      connection.start(queue: self.queue)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
        guard let self, data != nil else { connection.cancel(); return }
        onRequest()
        if self.released { self.reject(connection) }
        else { self.waiting.append(connection) }
      }
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
      listener.cancel(); throw NSError(domain: "AppleHeldMediaServer", code: 1)
    }
  }
  private func reject(_ connection: NWConnection) {
    connection.send(content: Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
      completion: .contentProcessed { _ in connection.cancel() })
  }
  func releaseFailure() {
    queue.async {
      self.released = true
      self.waiting.forEach(self.reject)
      self.waiting.removeAll()
    }
  }
  func close() {
    listener.cancel()
    queue.async { self.waiting.forEach { $0.cancel() }; self.waiting.removeAll() }
  }
}

@MainActor
extension AppleHostCharacterizations {
  static func cancelCandidate(_ test: XCTestCase) async throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    let active = try await f.host.load(request: AppleHostFixture.request("active-a"))
    let item = try XCTUnwrap(f.av.currentItem)
    let bEntered = test.expectation(description: "B enters actual preparation")
    let cEntered = test.expectation(description: "C enters actual preparation")
    let b = try AppleHeldMediaServer { bEntered.fulfill() }
    let c = try AppleHeldMediaServer { cEntered.fulfill() }
    defer { b.close(); c.close() }
    let pendingB = Task { try await f.host.load(request: AppleHostFixture.request("b", url: b.url.absoluteString, format: .matroska)) }
    await test.fulfillment(of: [bEntered], timeout: 5)
    var cSettled = false
    let pendingC = Task { () throws -> AppleLoadReply in
      defer { cSettled = true }
      return try await f.host.load(request: AppleHostFixture.request("c", url: c.url.absoluteString, format: .matroska))
    }
    await test.fulfillment(of: [cEntered], timeout: 5)
    do { _ = try await pendingB.value; XCTFail("Superseded B committed") } catch {}
    b.releaseFailure()
    await f.settle()
    XCTAssertFalse(cSettled, "Stale B settlement must not reject current C")
    XCTAssertEqual(f.host.sessionId, active.sessionId)
    c.releaseFailure()
    do { _ = try await pendingC.value; XCTFail("Controlled C precommit failure committed") } catch {}
    XCTAssertEqual(f.host.sessionId, active.sessionId)
    XCTAssertTrue(f.av.currentItem === item)
    XCTAssertTrue(f.host.isActive)

    let staleEntered = test.expectation(description: "stale preparation entered")
    let stale = try AppleHeldMediaServer { staleEntered.fulfill() }
    defer { stale.close() }
    let staleTask = Task { try await f.host.load(request: AppleHostFixture.request("stale", url: stale.url.absoluteString, format: .matroska)) }
    await test.fulfillment(of: [staleEntered], timeout: 5)
    let surviving = try await f.host.load(request: AppleHostFixture.request("surviving"))
    stale.releaseFailure()
    do { _ = try await staleTask.value; XCTFail("Stale candidate committed") } catch {}
    await f.settle()
    XCTAssertEqual(f.host.sessionId, surviving.sessionId, "Current candidate commits despite stale cancellation/completion")
    XCTAssertNotEqual(surviving.sessionId, active.sessionId)
  }

  static func stopPending(_ test: XCTestCase) async throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    let entered = test.expectation(description: "pending preparation entered")
    let server = try AppleHeldMediaServer { entered.fulfill() }
    defer { server.close() }
    let pending = Task { try await f.host.load(request: AppleHostFixture.request("pending", url: server.url.absoluteString, format: .matroska)) }
    await test.fulfillment(of: [entered], timeout: 5)
    await f.settle()
    f.callbacks.states.removeAll()
    try await f.host.stop()
    do { _ = try await pending.value; XCTFail("Stopped preparation committed") } catch {}
    await f.settle()
    XCTAssertEqual(f.callbacks.states.count, 1)
    let idle = try XCTUnwrap(f.callbacks.states.last)
    XCTAssertEqual(idle.status, .idle)
    XCTAssertEqual(idle.timeline.positionMs, 0)
    XCTAssertTrue(idle.audioTracks.isEmpty)
    XCTAssertNil(idle.failure)
    XCTAssertNil(idle.sessionId)
    XCTAssertTrue(f.output.frames.isEmpty)
    XCTAssertEqual(f.output.textureId, 81)
    XCTAssertEqual(f.output.disposals, 0)
    f.host.resume(); f.host.refreshState()
    await f.settle()
    XCTAssertEqual(f.callbacks.states.last?.status, .idle)
    let fresh = try await f.host.load(request: AppleHostFixture.request("fresh"))
    server.releaseFailure()
    await f.settle()
    XCTAssertEqual(f.host.sessionId, fresh.sessionId)
    XCTAssertEqual(f.output.textureId, 81)
    XCTAssertEqual(f.output.disposals, 0)
  }
}

@MainActor
extension AppleHostCharacterizations {
  static func fixtureMedia() throws -> Data {
    #if os(iOS)
    let url = try XCTUnwrap(Bundle(for: AppleHostFixture.self).url(forResource: "h264_aac", withExtension: "mkv"))
    #else
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("assets/test_media/network_seek_h264_aac.mkv")
    #endif
    return try Data(contentsOf: url)
  }
  static func waitFor(_ predicate: () -> Bool, timeout: TimeInterval = 5) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(predicate(), "Expected native condition before deadline")
  }
  static func activeReplacement(_ test: XCTestCase) async throws {
    let server = try ReactivationMediaServer(data: fixtureMedia()); defer { server.close() }
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    let a = try await f.load( AppleHostFixture.request("a", url: server.url.absoluteString, format: .matroska, autoplay: true))
    XCTAssertTrue(f.host.isActive)
    try await Task.sleep(nanoseconds: 200_000_000)
    let b = try await f.load( AppleHostFixture.request("b", url: server.url.absoluteString, format: .matroska, autoplay: true))
    await f.settle()
    XCTAssertTrue(f.host.isActive)
    XCTAssertEqual(f.output.textureId, 81)
    XCTAssertEqual(f.output.disposals, 0)
    XCTAssertNotEqual(a.sessionId, b.sessionId)
    XCTAssertEqual(f.callbacks.states.last?.loadRequestId, "b")
    XCTAssertEqual(f.callbacks.states.last?.engine, .managedFallback)
    try await waitFor({ f.host.initialState.timeline.positionMs > 100 })
  }
  static func reactivation(_ test: XCTestCase) async throws {
    let server = try ReactivationMediaServer(data: fixtureMedia()); defer { server.close() }
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    let loaded: AppleLoadReply
    do {
      loaded = try await f.load(AppleHostFixture.request("a", url: server.url.absoluteString,
        format: .matroska, autoplay: true, start: 500, width: 640))
    } catch {
      #if os(iOS)
      // Original iOS host case's sole hardware condition, restored by Ruling21.
      if (error as NSError).domain == "decoder.video_hardware_unavailable" {
        throw XCTSkip("Simulator VideoToolbox unavailable; no hardware playback claim")
      }
      #endif
      throw error
    }
    try await Task.sleep(nanoseconds: 200_000_000)
    try f.host.pause(command: .init(sessionId: loaded.sessionId))
    f.host.refreshState()
    XCTAssertGreaterThanOrEqual(f.host.initialState.timeline.positionMs, 450)
    try f.host.setVideoConstraints(command: .init(sessionId: loaded.sessionId, constraints: .init(maxWidth: 800)))
    try f.host.setVolume(volume: 0.2)
    try f.host.setPlaybackSpeed(command: .init(sessionId: loaded.sessionId, speed: 2))
    try f.host.seekTo(command: .init(sessionId: loaded.sessionId, positionMs: 700))
    try await waitFor({ f.host.initialState.timeline.positionMs >= 650 })
    let track = try XCTUnwrap(f.host.initialState.audioTracks.last?.id)
    try await f.host.selectAudioTrack(command: .init(sessionId: loaded.sessionId, trackId: track))
    do { _ = try await f.load( AppleHostFixture.request("bad", url: "", autoplay: true, start: 9000, width: 1)); XCTFail("Invalid candidate committed") } catch {}
    XCTAssertGreaterThanOrEqual(f.host.initialState.timeline.positionMs, 650)
    XCTAssertEqual(f.host.acceptedVideoConstraints.maxWidth, 800)
    f.host.suspend(); f.host.resume()
    try await waitFor({ f.host.isActive && [.paused, .ready].contains(f.host.initialState.status) })
    try await Task.sleep(nanoseconds: 200_000_000)
    let state = f.host.initialState
    XCTAssertEqual(state.sessionId, loaded.sessionId)
    XCTAssertEqual(f.host.acceptedVideoConstraints.maxWidth, 800)
    XCTAssertTrue([.paused, .ready].contains(state.status))
    XCTAssertGreaterThanOrEqual(state.timeline.positionMs, 650)
    XCTAssertEqual(state.audioTracks.first { $0.isSelected }?.id, track)
    try await Task.sleep(nanoseconds: 200_000_000)
    let paused = f.host.initialState.timeline.positionMs
    XCTAssertEqual(paused, state.timeline.positionMs, accuracy: 50)
    try await f.host.play(command: .init(sessionId: loaded.sessionId))
    var minimum = paused
    try await waitFor({
      minimum = min(minimum, f.host.initialState.timeline.positionMs)
      return f.host.initialState.timeline.positionMs > paused + 100
    })
    let baseline = f.host.initialState.timeline.positionMs
    XCTAssertGreaterThanOrEqual(minimum, 650)
    XCTAssertGreaterThan(baseline, paused + 100)
    try await Task.sleep(nanoseconds: 200_000_000)
    f.host.refreshState()
    XCTAssertGreaterThan(f.host.initialState.timeline.positionMs - baseline, 280)
  }
}

@MainActor
final class YlAppleBoundaryTests: XCTestCase {
  func testInputValidationPrecedesReplacementAndRejectsUnrepresentableTimeline() async throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    let a = try await f.host.load(request: AppleHostFixture.request("a"))
    let item = try XCTUnwrap(f.av.currentItem)
    let huge = AppleHostFixture.request("huge", start: Int64.max)
    XCTAssertEqual(try f.host.assess(request: .init(source: huge.source, options: huge.options)).outcome, .incompatible)
    XCTAssertThrowsError(try f.host.seekTo(command: .init(sessionId: a.sessionId, positionMs: Int64.max)))
    XCTAssertThrowsError(try f.host.setPlaybackSpeed(command: .init(sessionId: a.sessionId, speed: .nan)))
    XCTAssertThrowsError(try f.host.setVolume(volume: .infinity))
    var invalid = AppleHostFixture.request("invalid")
    invalid.source.request = .init(headers: ["If-Range": "owned"], credentials: [:])
    do { _ = try await f.host.load(request: invalid); XCTFail("Owned request header accepted") } catch {}
    invalid.source.request = .init(headers: ["X-Display": "ok"], credentials: ["x-display": "duplicate"])
    do { _ = try await f.host.load(request: invalid); XCTFail("Case-insensitive duplicate accepted") } catch {}
    invalid.source.request = .init(headers: [:], credentials: ["X-Identity": "line\nbreak"])
    do { _ = try await f.host.load(request: invalid); XCTFail("Invalid credential header accepted") } catch {}
    XCTAssertEqual(f.host.sessionId, a.sessionId)
    XCTAssertTrue(f.av.currentItem === item)
  }

  func testSemanticCommandRejectionCompletesFutureWithoutFailingHealthySession() async throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    let a = try await f.host.load(request: AppleHostFixture.request("a"))
    let item = f.av.currentItem
    do { try await f.host.seekToLiveEdge(command: .init(sessionId: a.sessionId)); XCTFail("Nonlive command accepted") } catch {}
    do { try await f.host.selectAudioTrack(command: .init(sessionId: a.sessionId, trackId: "missing")); XCTFail("Missing track accepted") } catch {}
    XCTAssertEqual(f.host.sessionId, a.sessionId)
    XCTAssertNil(f.host.initialState.failure)
    XCTAssertTrue(f.av.currentItem === item)
    try f.host.pause(command: .init(sessionId: a.sessionId))
    #if os(macOS)
    let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("assets/test_media")
    let server = try ReactivationMediaServer(
      data: Data(contentsOf: assets.appendingPathComponent("h264_aac.mkv")),
      supportsRanges: false)
    defer { server.close() }
    let sequential = AppleHostFixture(); defer { sequential.host.close() }
    let loaded = try await sequential.host.load(request: AppleHostFixture.request(
      "sequential", url: server.url.absoluteString, format: .matroska))
    try await AppleHostCharacterizations.waitFor {
      sequential.host.initialState.sessionId == loaded.sessionId
        && sequential.host.initialState.engine == .managedFallback
        && sequential.host.initialState.status == .ready
    }
    let before = sequential.host.initialState
    do {
      try sequential.host.seekTo(command: .init(sessionId: loaded.sessionId, positionMs: 900))
      XCTFail("Sequential fallback seek accepted")
    } catch let error as PigeonError {
      XCTAssertEqual(error.code, "network.range_not_supported")
      XCTAssertEqual((error.details as? AppleFailureMessage)?.category, .network)
    }
    let after = sequential.host.initialState
    XCTAssertEqual(after.sessionId, before.sessionId)
    XCTAssertEqual(after.revision, before.revision)
    XCTAssertEqual(after.timeline.positionMs, before.timeline.positionMs)
    XCTAssertNil(after.failure)
    #endif
  }
}

final class AppleRequestGate {
  private let lock = NSLock()
  private let releaseSignal = DispatchSemaphore(value: 0)
  private var armed = false
  private var requests = [String]()
  var onHeld: (() -> Void)?
  func arm() { lock.lock(); armed = true; lock.unlock() }
  func release() { releaseSignal.signal() }
  func observe(_ request: String) {
    lock.lock()
    requests.append(request)
    let hold = armed
    armed = false
    lock.unlock()
    if hold { onHeld?(); _ = releaseSignal.wait(timeout: .now() + 10) }
  }
  var observed: [String] { lock.lock(); defer { lock.unlock() }; return requests }
}
