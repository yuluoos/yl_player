import XCTest
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif
import CoreVideo
import AVFoundation
import Network
@testable import yl_player_apple

final class YlAppleSessionTests: XCTestCase {
  func testImmutableRequestAndSessionIdentityStartsAtZero() {
    let reducer = YlAppleStateReducer(playerId: 7, clock: { 42 })
    XCTAssertEqual(reducer.revision, 0)
    XCTAssertEqual(reducer.sequence, 0)
    let identity = reducer.makeIdentity(loadRequestId: "request-a")
    XCTAssertEqual(identity.sessionId, "apple-7-s1")
    XCTAssertEqual(identity.loadRequestId, "request-a")
    XCTAssertNotEqual(reducer.makeIdentity(loadRequestId: "request-b"), identity)
  }

  func testNegativeMeasuredLiveOffsetIsZeroAndUnknownRemainsNil() {
    XCTAssertEqual(YlAppleTimeline.liveOffset(-4), 0)
    XCTAssertNil(YlAppleTimeline.liveOffset(nil))
  }

  func testDeltaRetainsTimelineForLaterSemanticSnapshots() {
    let reducer = YlAppleStateReducer(playerId: 7, clock: { 42 })
    let id = reducer.makeIdentity(loadRequestId: "request")
    reducer.commit(id)
    reducer.accept(.init(generation: 1, event: .state(.characterizationReady)), identity: id)
    let revision = reducer.revision
    reducer.accept(.init(generation: 1, event: .delta(.init(positionMs: 120,
      bufferedPositionMs: 240, isAtLiveEdge: true, liveOffsetMs: -2,
      metrics: .init(bufferedBytes: 80)))), identity: id)
    XCTAssertEqual(reducer.revision, revision + 1)
    reducer.projectPaused()
    XCTAssertEqual(reducer.state.snapshot?.positionMs, 120)
    XCTAssertEqual(reducer.state.snapshot?.bufferedPositionMs, 240)
    XCTAssertEqual(reducer.state.snapshot?.metrics.bufferedBytes, 80)
    XCTAssertEqual(reducer.state.snapshot?.status, "paused")
  }

  func testReadyPrecedesFirstFrameAndEvidenceSurvivesRecovery() {
    var now: Int64 = 100
    let reducer = YlAppleStateReducer(playerId: 7, clock: { now })
    let id = reducer.makeIdentity(loadRequestId: "request")
    var statuses = [String]()
    var frames = [YlAppleEventMetadata]()
    var failures = [YlAppleEventMetadata]()
    reducer.onOutput = { output in
      switch output {
      case .state(let state): statuses.append(state.snapshot?.status ?? "loading")
      case .firstFrame(let event): frames.append(event)
      case .failed(let event, _): failures.append(event)
      default: break
      }
    }
    reducer.commit(id)
    var snapshot = YlNativeState.characterizationReady
    snapshot.status = "buffering"
    reducer.accept(.init(generation: 1, event: .state(snapshot)), identity: id)
    reducer.accept(.init(generation: 1, event: .firstFrame(width: 1, height: 1)), identity: id)
    XCTAssertTrue(frames.isEmpty)
    XCTAssertFalse(statuses.contains("buffering"), "READY must precede public buffering")
    XCTAssertNil(reducer.state.snapshot?.metrics.openDurationMs)
    now = 120
    reducer.publicFrame(identity: id)
    XCTAssertTrue(frames.isEmpty, "A public frame does not invent READY")
    snapshot.status = "playing"
    snapshot.metrics.openDurationMs = 15
    reducer.accept(.init(generation: 1, event: .state(snapshot)), identity: id)
    XCTAssertEqual(Array(statuses.suffix(3)), ["ready", "playing", "playing"])
    XCTAssertEqual(frames.count, 1)
    now = 180
    snapshot.metrics = .init()
    reducer.accept(.init(generation: 2, event: .state(snapshot)), identity: id)
    reducer.publicFrame(identity: id)
    XCTAssertEqual(frames.count, 1)
    XCTAssertEqual(reducer.state.snapshot?.metrics.openDurationMs, 20)
    XCTAssertEqual(reducer.state.snapshot?.metrics.firstFrameDurationMs, 20)
    let error = NativePlayerError(category: "decoder", code: "decoder.failed", message: "failure")
    reducer.accept(.init(generation: 2, event: .failure(error)), identity: id)
    reducer.accept(.init(generation: 2, event: .failure(error)), identity: id)
    XCTAssertEqual(failures.count, 1)
    XCTAssertEqual(failures.first?.occurredAtMs, 180)
    XCTAssertGreaterThan(failures.first!.sequence, frames.first!.sequence)
    reducer.stop()
    reducer.accept(.init(generation: 2, event: .state(snapshot)), identity: id)
    XCTAssertNil(reducer.identity)
  }

  func testPrivateReservedFailureCategoriesMapExplicitly() {
    XCTAssertEqual(YlAppleFailureMapper.category("protocol"), .protocolFailure)
    XCTAssertEqual(YlAppleFailureMapper.category("internal"), .internalFailure)
  }
}

final class YlAppleTypedBackendTests: XCTestCase {
  @MainActor
  func testPartialOrAbsentGeometryCannotInventPublicMeasurements() {
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    XCTAssertNil(fixture.host.initialState.geometry)
    for engine: YlNativeEngine in [.avPlayer, .managedFallback] {
      let measured = YlNativeState(status: "ready", positionMs: 0, durationMs: nil,
        bufferedPositionMs: 0, isLive: false, isSeekable: true,
        isAtLiveEdge: false, liveOffsetMs: nil, dvrStartMs: nil, dvrEndMs: nil,
        videoWidth: 1280, videoHeight: 720, engine: engine,
        isHardwareDecoding: false, decoderName: nil, audioTracks: [], videoTracks: [],
        metrics: .init(), error: nil)
      let value = fixture.host.encode(.init(identity: .init(sessionId: "s", loadRequestId: "r"),
        revision: 1, sequence: 1, snapshot: measured, failure: nil))
      XCTAssertNil(value.geometry, "Width/height alone do not measure encoded size, clean aperture, PAR or rotation")
      XCTAssertEqual(measured.videoWidth, 1280)
      XCTAssertEqual(measured.videoHeight, 720)
    }
  }

  func testTypedStateRetainsMeasuredMetadataWithoutTransportEnvelope() {
    let state = YlNativeState(status: "playing", positionMs: 1000, durationMs: 8000,
      bufferedPositionMs: 2500, isLive: false, isSeekable: true,
      isAtLiveEdge: false, liveOffsetMs: nil, dvrStartMs: nil, dvrEndMs: nil,
      videoWidth: 1280, videoHeight: 720, engine: .managedFallback,
      isHardwareDecoding: true, decoderName: "VideoToolbox",
      audioTracks: [YlNativeTrack(id: "audio-1", kind: .audio, isSelected: true)],
      videoTracks: [], metrics: YlNativeMetrics(bufferedBytes: 4096), error: nil)
    guard case let .state(observed) = YlNativeBackendEvent.state(state) else {
      return XCTFail("Full state must remain a typed snapshot")
    }
    XCTAssertEqual(observed.status, "playing")
    XCTAssertEqual(observed.positionMs, 1000)
    XCTAssertEqual(observed.durationMs, 8000)
    XCTAssertEqual(observed.videoWidth, 1280)
    XCTAssertEqual(observed.audioTracks.first?.id, "audio-1")
    XCTAssertEqual(observed.metrics.bufferedBytes, 4096)
    XCTAssertNil(observed.error)
  }
}

@MainActor
final class YlAppleRegistryTests: XCTestCase {
  private final class Lifecycle: YlLifecycleDriving {
    var onSuspend: (() -> Void)?
    var onResume: (() -> Void)?
    var onTerminate: (() -> Void)?
    var onMemoryWarning: (() -> Void)?
    func start() {}
    func stop() {}
    func sendMemoryWarning() { onMemoryWarning?() }
  }

  func testInvalidCreateDoesNotAllocateTexture() throws {
    var allocations = 0
    let registry = YlApplePlayerRegistry(makeServices: { _ in
      allocations += 1
      return Self.services()
    }, makeCallbacks: { _ in AppleRecordingCallbacks() }, installHost: { _, _ in })
    defer { registry.detach() }
    XCTAssertThrowsError(try registry.create(request: AppleCreateRequest(schemaMajor: 2,
      options: ApplePlayerOptionsMessage(decoderPolicy: .systemDefault,
        audioPolicy: .appManaged, positionUpdateIntervalMs: 0))))
    XCTAssertEqual(allocations, 0)
    let reply = try registry.create(request: AppleCreateRequest(schemaMajor: 2,
      options: ApplePlayerOptionsMessage(decoderPolicy: .systemDefault,
        audioPolicy: .appManaged, positionUpdateIntervalMs: 5000)))
    XCTAssertEqual(allocations, 1)
    XCTAssertEqual(reply.initialState.status, .idle)
    XCTAssertEqual(reply.initialState.revision, 0)
    XCTAssertEqual(reply.initialState.sequence, 0)
    XCTAssertNotEqual(reply.channelSuffix, "")
    XCTAssertEqual(registry.host(for: reply.channelSuffix)?.positionUpdateIntervalMs, 5000)
  }

  func testLifecycleMemoryWarningReachesActiveHostThroughSharedProtocol() async throws {
    let lifecycle = Lifecycle()
    let output = AppleTestTexture()
    let registry = YlApplePlayerRegistry(makeServices: { _ in
      YlPlatformServices(platform: .current, textureOutput: output,
        makeDisplayDriver: { _ in AppleTestDisplay() })
    }, makeCallbacks: { _ in AppleRecordingCallbacks() }, installHost: { _, _ in },
      lifecycle: lifecycle)
    defer { registry.detach() }
    let created = try registry.create(request: .init(schemaMajor: 2,
      options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged,
        positionUpdateIntervalMs: 500)))
    let host = try XCTUnwrap(registry.host(for: created.channelSuffix))
    let loaded = try await host.load(request: AppleHostFixture.request("memory"))
    XCTAssertTrue(host.isActive)

    lifecycle.sendMemoryWarning()

    XCTAssertFalse(host.isActive)
    XCTAssertEqual(host.sessionId, loaded.sessionId)
    XCTAssertEqual(host.initialState.status, .paused)
    XCTAssertNil(host.initialState.failure)
    XCTAssertEqual(output.disposals, 0)
  }

  static func services() -> YlPlatformServices {
    YlPlatformServices(platform: .current, textureOutput: AppleTestTexture(),
      makeDisplayDriver: { _ in AppleTestDisplay() })
  }
}

final class AppleTestTexture: YlTextureOutput {
  let textureId: Int64 = 81
  var frames = [CVPixelBuffer]()
  var clears = 0
  var disposals = 0
  func publish(_ pixelBuffer: CVPixelBuffer?) { if let pixelBuffer { frames.append(pixelBuffer) } }
  func resize(width: Int, height: Int) {}
  func clear() { clears += 1 }
  func dispose() { disposals += 1 }
}
final class AppleTestDisplay: YlDisplayDriving {
  var isPaused = true
  func invalidate() {}
}
final class AppleRecordingCallbacks: ApplePlayerFlutterApiProtocol {
  var states = [AppleStateMessage]()
  var deltas = [AppleStateDeltaMessage]()
  var frames = [AppleFirstFrameMessage]()
  var retries = [AppleRetryScheduledMessage]()
  var engines = [AppleEngineChangedMessage]()
  var failures = [ApplePlaybackFailedMessage]()
  var order = [String]()
  var acknowledge: (() async throws -> Void)?
  func onState(state: AppleStateMessage) async throws { states.append(state); order.append("state"); try await acknowledge?() }
  func onStateDelta(delta: AppleStateDeltaMessage) async throws { deltas.append(delta); order.append("delta"); try await acknowledge?() }
  func onFirstFrame(event: AppleFirstFrameMessage) async throws { frames.append(event); order.append("frame"); try await acknowledge?() }
  func onRetryScheduled(event: AppleRetryScheduledMessage) async throws { retries.append(event); order.append("retry"); try await acknowledge?() }
  func onEngineChanged(event: AppleEngineChangedMessage) async throws { engines.append(event); order.append("engine"); try await acknowledge?() }
  func onPlaybackFailed(event: ApplePlaybackFailedMessage) async throws { failures.append(event); order.append("failed"); try await acknowledge?() }
}
final class AppleClockDisplay: YlDisplayDriving {
  var isPaused = true
  private var timer: Timer?
  init(onTick: @escaping () -> Void) {
    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
      if self?.isPaused == false { onTick() }
    }
  }
  func invalidate() { timer?.invalidate(); timer = nil }
  deinit { invalidate() }
}

@MainActor
final class YlAppleLeaseTests: XCTestCase {
  func testPrivateFrameCommitAndRetiredClearRespectHostOwnership() throws {
    let output = AppleTestTexture()
    var observed = [YlAppleSessionIdentity]()
    let owner = YlAppleTextureOwner(output: output, onFrame: { observed.append($0) })
    let a = YlAppleSessionIdentity(sessionId: "a", loadRequestId: "a")
    let b = YlAppleSessionIdentity(sessionId: "b", loadRequestId: "b")
    let old = owner.makeLease(identity: a)
    owner.commit(old)
    let candidate = owner.makeLease(identity: b)
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA,
      nil, &buffer), kCVReturnSuccess)
    let frame = try XCTUnwrap(buffer)
    candidate.publish(frame)
    XCTAssertTrue(output.frames.isEmpty)
    XCTAssertTrue(observed.isEmpty)
    owner.commit(candidate)
    XCTAssertEqual(output.frames.count, 1)
    XCTAssertEqual(observed, [b])
    candidate.publish(frame)
    XCTAssertEqual(output.frames.count, 2)
    old.clear()
    old.dispose()
    old.publish(frame)
    XCTAssertEqual(output.clears, 0)
    XCTAssertEqual(output.frames.count, 2)
    XCTAssertEqual(output.disposals, 0)
    owner.stop()
    XCTAssertEqual(output.clears, 1)
    owner.dispose()
    owner.dispose()
    XCTAssertEqual(output.disposals, 1)
  }
}

@MainActor
final class YlAppleOutboundTests: XCTestCase {
  func testAcknowledgementBlocksFollowingCallsAndFailureClosesQueue() async {
    let queue = YlAppleOutboundQueue(acknowledgementTimeout: 1)
    var order = [String]()
    var acknowledgement: CheckedContinuation<Void, Never>?
    let first = expectation(description: "first callback entered")
    let last = expectation(description: "second callback entered")
    let closed = expectation(description: "failed acknowledgement closes")
    queue.onFailure = { closed.fulfill() }
    queue.enqueue {
      order.append("state")
      await withCheckedContinuation { acknowledgement = $0; first.fulfill() }
    }
    queue.enqueue { order.append("frame"); last.fulfill(); throw URLError(.cancelled) }
    queue.enqueue { order.append("late") }
    await fulfillment(of: [first], timeout: 1)
    XCTAssertEqual(order, ["state"])
    acknowledgement?.resume()
    await fulfillment(of: [last, closed], timeout: 1)
    queue.enqueue { order.append("after-close") }
    await Task.yield()
    XCTAssertEqual(order, ["state", "frame"])
  }

  func testHungAcknowledgementHasBoundedCleanup() async {
    let queue = YlAppleOutboundQueue(acknowledgementTimeout: 0.03)
    let closed = expectation(description: "deadline closes queue")
    var acknowledgement: CheckedContinuation<Void, Never>?
    var later = false
    queue.onFailure = { closed.fulfill() }
    queue.enqueue { await withCheckedContinuation { acknowledgement = $0 } }
    queue.enqueue { later = true }
    await fulfillment(of: [closed], timeout: 1)
    acknowledgement?.resume()
    await Task.yield()
    XCTAssertFalse(later)
  }
}

@MainActor
final class YlAppleHostDeliveryTests: XCTestCase {
  func testGeneratedCallbacksSendOnPlatformThreadAfterAsyncHops() async throws {
    let delivered = expectation(description: "all generated callbacks reached messenger")
    delivered.expectedFulfillmentCount = 8
    let messenger = AppleThreadRecordingMessenger(delivered: delivered)
    let callbacks = YlPlayerApplePlugin.makeCallbacks(messenger: messenger, suffix: "thread-regression")
    let host = YlApplePlayerHost(playerId: 93, suffix: "thread-regression",
      options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 250),
      services: YlAppleRegistryTests.services(), callbacks: callbacks)
    defer { host.close() }
    try host.attach()
    let id = YlAppleSessionIdentity(sessionId: "session", loadRequestId: "request")
    let meta = YlAppleEventMetadata(identity: id, revision: 2, sequence: 3, occurredAtMs: 10)
    host.send(.state(.init(identity: id, revision: 1, sequence: 1, snapshot: .characterizationReady, failure: nil)))
    host.send(.delta(.init(identity: id, revision: 2, sequence: 2, occurredAtMs: 10), previousRevision: 1,
      .init(positionMs: 1, bufferedPositionMs: 2, isAtLiveEdge: false, liveOffsetMs: nil, metrics: .init())))
    host.send(.firstFrame(meta))
    let error = NativePlayerError(category: "network", code: "network.failed", message: "failed")
    host.send(.retry(meta, attempt: 1, delayMs: 20, error))
    host.send(.engineChanged(meta, previous: .avPlayer, current: .managedFallback))
    host.send(.state(.init(identity: id, revision: 3, sequence: 6, snapshot: .characterizationReady, failure: error)))
    host.send(.failed(meta, error))
    await fulfillment(of: [delivered], timeout: 5)
    let records = messenger.records
    XCTAssertEqual(records.map(\.method), ["onState", "onState", "onStateDelta", "onFirstFrame",
      "onRetryScheduled", "onEngineChanged", "onState", "onPlaybackFailed"])
    XCTAssertTrue(records.allSatisfy(\.isMainThread), "Actual Pigeon messenger sends must use the platform thread: \(records)")
    XCTAssertTrue(records.allSatisfy { $0.channel.hasSuffix(".thread-regression") })
    XCTAssertTrue(records.allSatisfy { $0.argumentCount == 1 })
  }

  func testSixGeneratedCallbackMethodsShareAcknowledgedHostFIFO() async throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    let entered = expectation(description: "initial callback entered")
    var gate: CheckedContinuation<Void, Never>?
    var initial = true
    f.callbacks.acknowledge = {
      if initial { initial = false; await withCheckedContinuation { gate = $0; entered.fulfill() } }
    }
    try f.host.attach()
    let id = YlAppleSessionIdentity(sessionId: "session", loadRequestId: "request")
    let meta = YlAppleEventMetadata(identity: id, revision: 2, sequence: 3, occurredAtMs: 10)
    f.host.send(.state(.init(identity: id, revision: 1, sequence: 1, snapshot: .characterizationReady, failure: nil)))
    f.host.send(.delta(.init(identity: id, revision: 2, sequence: 2, occurredAtMs: 10), previousRevision: 1,
      .init(positionMs: 1, bufferedPositionMs: 2, isAtLiveEdge: false, liveOffsetMs: nil, metrics: .init())))
    f.host.send(.firstFrame(meta))
    let error = NativePlayerError(category: "network", code: "network.failed", message: "private", diagnostic: "https://private.test?secret")
    f.host.send(.retry(.init(identity: id, revision: 2, sequence: 4, occurredAtMs: 11), attempt: 1, delayMs: 20, error))
    f.host.send(.engineChanged(.init(identity: id, revision: 2, sequence: 5, occurredAtMs: 12), previous: .avPlayer, current: .managedFallback))
    f.host.send(.state(.init(identity: id, revision: 3, sequence: 6, snapshot: .characterizationReady, failure: error)))
    f.host.send(.failed(.init(identity: id, revision: 3, sequence: 7, occurredAtMs: 13), error))
    await fulfillment(of: [entered], timeout: 1)
    XCTAssertEqual(f.callbacks.order, ["state"])
    gate?.resume()
    try await AppleHostCharacterizations.waitFor({ f.callbacks.order.count == 8 })
    XCTAssertEqual(f.callbacks.order, ["state", "state", "delta", "frame", "retry", "engine", "state", "failed"])
    XCTAssertEqual(f.callbacks.frames.first?.sequence, 3)
    XCTAssertEqual(f.callbacks.failures.first?.sequence, 7)
    XCTAssertEqual(f.callbacks.failures.first?.occurredAtMs, 13)
    XCTAssertEqual(f.callbacks.failures.first?.failure.scope, .session)
    XCTAssertFalse(f.callbacks.failures.first?.failure.message.contains("private") ?? true)
  }

  func testFailedAcknowledgementDisposesHostAndUninstallsSuffixExactlyOnce() async throws {
    let textures = ApplePublicationRegistry()
    let callbacks = AppleRecordingCallbacks()
    callbacks.acknowledge = { throw URLError(.cannotDecodeContentData) }
    var removed = [String]()
    let registry = YlApplePlayerRegistry(makeServices: { _ in textures.services() },
      makeCallbacks: { _ in callbacks }, installHost: { suffix, host in if host == nil { removed.append(suffix) } })
    defer { registry.detach() }
    let created = try registry.create(request: .init(schemaMajor: 2,
      options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 100)))
    let host = try XCTUnwrap(registry.host(for: created.channelSuffix))
    XCTAssertTrue(callbacks.states.isEmpty, "Create stays silent until attach")
    try host.attach()
    try await AppleHostCharacterizations.waitFor({ host.disposed })
    XCTAssertNil(registry.host(for: created.channelSuffix))
    XCTAssertEqual(removed, [created.channelSuffix])
    XCTAssertEqual(textures.registrations, 1)
    XCTAssertEqual(textures.unregistered, [created.textureId])
    host.close(); registry.detach()
    XCTAssertEqual(textures.unregistered.count, 1)
    XCTAssertEqual(removed.count, 1)
  }
}

@MainActor
final class YlAppleHlsIntentTests: XCTestCase {
  func testUnknownInspectionStrippingSurvivesHlsRefinement() async throws {
    let server = try HlsIntentServer(); defer { server.close() }
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    var request = AppleHostFixture.request("unknown", url: server.origin.appendingPathComponent("unknown").absoluteString, format: .automatic)
    request.source.request = .init(headers: [:], credentials: ["X-Intent": "secret"])
    _ = try await fixture.load(request)
    XCTAssertEqual(server.credentials(path: "/unknown"), [true, false],
      "HLS root refinement must inherit stripping from the owned inspection request")
  }

  func testRedirectHistorySurvivesRealSessionReconstructionAndFreshLoadResetsIntent() async throws {
    let server = try HlsIntentServer()
    defer { server.close() }
    let f = AppleHostFixture()
    defer { f.host.close() }
    func request(_ id: String) -> AppleLoadRequest {
      var value = AppleHostFixture.request(id, url: server.origin.appendingPathComponent("master.m3u8").absoluteString, format: .hls)
      value.source.request = AppleHttpRequestMessage(headers: [:], credentials: ["X-Intent": "secret"])
      return value
    }
    func loader() throws -> YlHlsResourceLoader {
      let asset = try XCTUnwrap(f.av.currentItem?.asset as? AVURLAsset)
      return try XCTUnwrap(asset.resourceLoader.delegate as? YlHlsResourceLoader)
    }
    func fetch(_ url: URL, using loader: YlHlsResourceLoader) async throws -> Data {
      let request = HlsIntentRequest(url)
      loader.startLoading(request)
      try await AppleHostCharacterizations.waitFor { request.finished }
      if let error = request.error { throw error }
      if let redirect = request.redirect {
        return try await URLSession.shared.data(for: redirect).0
      }
      return request.data
    }
    func inspectChildren(_ loader: YlHlsResourceLoader) async throws {
      let root = try await fetch(loader.encodedAssetURL(), using: loader)
      let childLine = try XCTUnwrap(String(decoding: root, as: UTF8.self).split(separator: "\n").first { !$0.hasPrefix("#") })
      let child = try await fetch(XCTUnwrap(URL(string: String(childLine))), using: loader)
      let mediaLine = try XCTUnwrap(String(decoding: child, as: UTF8.self).split(separator: "\n").first { !$0.hasPrefix("#") })
      _ = try await URLSession.shared.data(from: XCTUnwrap(URL(string: String(mediaLine))))
      // This resource has no stripped ancestor and must keep its independent intent.
      _ = try await fetch(YlHlsURLCodec.encode(server.origin.appendingPathComponent("unrelated.key"), kind: .key), using: loader)
      // The media proxy must remember its own redirect across reconstruction too.
      _ = try await fetch(YlHlsURLCodec.encode(server.origin.appendingPathComponent("redirect.ts"), kind: .media), using: loader)
    }
    let first = try await f.load(request("first"))
    let original = try loader()
    try await inspectChildren(original)
    f.host.suspend()
    f.host.resume()
    try await AppleHostCharacterizations.waitFor { f.host.isActive && f.av.currentItem != nil }
    let restored = try loader()
    XCTAssertFalse(original === restored)
    XCTAssertEqual(f.host.sessionId, first.sessionId)
    try await inspectChildren(restored)
    XCTAssertEqual(server.credentials(path: "/master.m3u8"), [true, false], "Original resource must stay stripped on same-session reopen")
    XCTAssertFalse(server.credentials(path: "/child.m3u8").isEmpty)
    XCTAssertTrue(server.credentials(path: "/child.m3u8").allSatisfy { !$0 })
    XCTAssertFalse(server.credentials(path: "/segment.ts").isEmpty)
    XCTAssertTrue(server.credentials(path: "/segment.ts").allSatisfy { !$0 })
    XCTAssertEqual(server.credentials(path: "/unrelated.key"), [true, true])
    XCTAssertEqual(server.credentials(path: "/redirect.ts"), [true, false])
    let fresh = try await f.load(request("fresh"))
    XCTAssertNotEqual(fresh.sessionId, first.sessionId)
    let freshLoader = try loader()
    XCTAssertThrowsError(try original.preflight(cancellationToken: YlOpenCancellationToken()))
    // Retired work cannot authorize or strip the new user Load's resource.
    let lateURL = server.origin.appendingPathComponent("late.key")
    let retired = HlsIntentRequest(try YlHlsURLCodec.encode(lateURL, kind: .key, credentialsStripped: true))
    original.startLoading(retired)
    XCTAssertTrue(retired.finished)
    XCTAssertEqual(retired.error?.code, "network.cancelled")
    _ = try await fetch(YlHlsURLCodec.encode(lateURL, kind: .key), using: freshLoader)
    XCTAssertEqual(server.credentials(path: "/late.key"), [true])
    _ = try await fetch(YlHlsURLCodec.encode(server.origin.appendingPathComponent("redirect.ts"), kind: .media), using: freshLoader)
    XCTAssertEqual(server.credentials(path: "/master.m3u8"), [true, false, true])
    XCTAssertEqual(server.credentials(path: "/redirect.ts"), [true, false, true])
  }
}

private final class HlsIntentRequest: YlHlsLoadingRequest {
  let url: URL
  var requestedOffset: Int64 { 0 }
  var currentOffset: Int64 { 0 }
  var requestedLength: Int { 0 }
  var requestsAllDataToEnd: Bool { true }
  private let lock = NSLock()
  private var complete = false
  var finished: Bool { lock.lock(); defer { lock.unlock() }; return complete }
  var data = Data()
  var error: NativePlayerError?
  var redirect: URLRequest?
  init(_ url: URL) { self.url = url }
  func setContentInformation(contentType: String?, contentLength: Int64, byteRangeAccessSupported: Bool) {}
  func respond(with data: Data) { self.data.append(data) }
  func redirect(to request: URLRequest) { redirect = request }
  func finishLoading() { lock.lock(); complete = true; lock.unlock() }
  func finishLoading(with error: NativePlayerError) { self.error = error; finishLoading() }
}

private final class HlsIntentServer {
  private let source: NWListener
  private let other: NWListener
  private let queue = DispatchQueue(label: "yl.test.hls.intent")
  private let lock = NSLock()
  private var log = [(String, Bool)]()
  let origin: URL
  init() throws {
    source = try NWListener(using: .tcp, on: .any)
    other = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    for listener in [source, other] {
      listener.newConnectionHandler = { $0.cancel() }
      listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
      listener.start(queue: queue)
    }
    guard ready.wait(timeout: .now() + 5) == .success,
          ready.wait(timeout: .now() + 5) == .success,
          let port = source.port, let otherPort = other.port else { throw NSError(domain: "HlsIntentServer", code: 1) }
    origin = URL(string: "http://127.0.0.1:\(port.rawValue)")!
    let foreign = "http://127.0.0.1:\(otherPort.rawValue)"
    for (listener, isSource) in [(source, true), (other, false)] {
      listener.newConnectionHandler = { [weak self] connection in
        connection.start(queue: DispatchQueue.global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] bytes, _, _, _ in
          guard let self, let bytes, !bytes.isEmpty else { connection.cancel(); return }
          let text = String(decoding: bytes, as: UTF8.self)
          let path = text.split(separator: " ").dropFirst().first.map(String.init) ?? ""
          let authorized = text.lowercased().contains("x-intent: secret")
          if isSource { self.lock.lock(); self.log.append((path, authorized)); self.lock.unlock() }
          let redirect = isSource && ["/master.m3u8", "/unknown", "/redirect.ts"].contains(path)
          let body: String
          if path == "/master.m3u8" || path == "/unknown" { body = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\n\(self.origin)/child.m3u8\n" }
          else if path == "/child.m3u8" { body = "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\n\(self.origin)/segment.ts\n#EXT-X-ENDLIST\n" }
          else { body = "0123456789abcdef" }
          let data = Data(body.utf8)
          let headers = "HTTP/1.1 \(redirect ? "302 Found" : "200 OK")\r\n" + (redirect ? "Location: \(foreign)\(path)\r\n" : "") + "Content-Type: \(path.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : "application/octet-stream")\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
          connection.send(content: Data(headers.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
        }
      }
    }
  }
  func credentials(path: String) -> [Bool] { lock.lock(); defer { lock.unlock() }; return log.filter { $0.0 == path }.map { $0.1 } }
  func close() { source.cancel(); other.cancel() }
}

@MainActor
extension YlAppleSessionTests {
  func testAssessmentDefaultRouteMatrixAndStableEvidence() throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    for kind in [AppleSourceKind.file, .network] {
      for format in [AppleMediaFormat.hls, .mp4, .mov] {
        var request = AppleHostFixture.request("matrix")
        request.source.kind = kind
        request.source.locator = kind == .file ? "/tmp/unreachable.media" : "https://unreachable.invalid/media"
        request.source.format = format
        let assessment = try f.host.assess(request: .init(source: request.source, options: request.options))
        XCTAssertEqual(assessment.outcome, .compatible)
        XCTAssertEqual(assessment.candidateEngine, .avPlayer)
        XCTAssertEqual(Set(assessment.satisfiedRequirements), ["network.platformDefault", "buffer.automatic", "decoder.systemDefault"])
        XCTAssertTrue(assessment.limitations.contains("decoder.modeUnknown"))
        XCTAssertEqual(assessment.limitations.contains("network.systemStackOpaque"), kind == .network)
      }
    }
    var unknown = AppleHostFixture.request("unknown", url: "https://unreachable.invalid/media", format: .automatic)
    XCTAssertEqual(try f.host.assess(request: .init(source: unknown.source, options: unknown.options)).outcome, .requiresInspection)
    unknown.source.kind = .content
    unknown.source.locator = "content://media/external/video/1"
    XCTAssertEqual(try f.host.assess(request: .init(source: unknown.source, options: unknown.options)).rejection?.code, "source.invalid")
  }

  func testAssessmentRejectsUnsupportedContainerAndLoadKeepsCommittedSession() async throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    let current = try await f.host.load(request: AppleHostFixture.request("current"))
    for format in [AppleMediaFormat.avi, .mpegTs, .mpegPs] {
      let request = AppleHostFixture.request("unsupported", format: format)
      let assessment = try f.host.assess(request: .init(source: request.source, options: request.options))
      XCTAssertEqual(assessment.outcome, .incompatible)
      XCTAssertEqual(assessment.rejection?.code, "container.unsupported")
      do { _ = try await f.host.load(request: request); XCTFail("Unsupported container committed") }
      catch let error as PigeonError { XCTAssertEqual(error.code, assessment.rejection?.code) }
      XCTAssertEqual(f.host.sessionId, current.sessionId)
    }
  }
}

@MainActor
extension YlAppleSessionTests {
  func testManagedUnsupportedLoadDoesNotOpenUpstreamOrReplaceSession() async throws {
    let lock = NSLock()
    var requests = 0
    let server = try ReactivationMediaServer(data: Data([1]), onRequest: { _ in
      lock.lock(); requests += 1; lock.unlock()
    })
    defer { server.close() }
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    let committed = try await fixture.host.load(request: AppleHostFixture.request("initial"))
    for format in [AppleMediaFormat.hls, .mp4, .mov, .avi, .mpegTs, .mpegPs] {
      var request = AppleHostFixture.request("strict", url: server.url.absoluteString, format: format)
      request.source.networkPolicy = .init(kind: .managed, connectTimeoutMs: 1000, readTimeoutMs: 1000,
        maxRetries: 1, baseRetryDelayMs: 1, maxRetryDelayMs: 2, maxRedirects: 2)
      do { _ = try await fixture.host.load(request: request); XCTFail("Unsupported managed Load committed") }
      catch let error as PigeonError { XCTAssertEqual(error.code, "policy.unsupported") }
      XCTAssertEqual(fixture.host.sessionId, committed.sessionId)
    }
    XCTAssertEqual(lock.withLock { requests }, 0)
  }

  func testTypedInputPreservesRequestedNetworkBoundsForEnforcedManagedRoute() throws {
    var request = AppleHostFixture.request("network-policy", format: .matroska)
    request.source.networkPolicy = AppleNetworkPolicyMessage(kind: .managed,
      connectTimeoutMs: 70_000, readTimeoutMs: 80_000, maxRetries: 21,
      baseRetryDelayMs: 90_000, maxRetryDelayMs: 100_000, maxRedirects: 22)
    let recipe = try YlAppleNativeInput.load(source: request.source, options: request.options,
      defaults: ApplePlayerOptionsMessage(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 250),
      loadRequestId: request.loadRequestId)
    let settings = try XCTUnwrap(recipe.source.networkConfiguration)
    XCTAssertEqual(settings.connectTimeoutMs, 70_000)
    XCTAssertEqual(settings.readTimeoutMs, 80_000)
    XCTAssertEqual(settings.maxRetries, 21)
    XCTAssertEqual(settings.baseRetryDelayMs, 90_000)
    XCTAssertEqual(settings.maxRetryDelayMs, 100_000)
    XCTAssertEqual(settings.maxRedirects, 22)
    let assessed = YlEngineRouter.assess(recipe.source)
    XCTAssertEqual(assessed.outcome, .requiresInspection)
    XCTAssertTrue(assessed.satisfiedRequirements.contains(.networkManaged))
  }

  func testUnknownLocalSourceLoadRefinesSameAssessmentBeforeCommit() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("#EXTM3U\n#EXT-X-ENDLIST\n".utf8).write(to: file)
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    var request = AppleHostFixture.request("inspected", format: .automatic)
    request.source.kind = .file; request.source.locator = file.path
    XCTAssertEqual(try fixture.host.assess(request: .init(source: request.source, options: request.options)).outcome, .requiresInspection)
    let committed = try await fixture.host.load(request: request)
    XCTAssertEqual(fixture.host.sessionId, committed.sessionId)
  }
}

final class YlEngineAssessmentTests: XCTestCase {
  private let enforcing = YlRoutingAvailability(managedNetwork: true, boundedBuffer: true, hardwareEvidence: true)

  func testCompletePolicyRouteMatrixEnablesEnforcedManagedBufferAndHardwareRoutes() {
    for kind: YlSourceKind in [.file, .network] {
      for format: YlSourceFormat in [.hls, .mp4, .mov, .matroska, .flv, .webm, .avi, .mpegTs, .mpegPs] {
        for policy in 0..<4 {
          var source = YlAppleSourceDescriptor(uri: kind == .file ? "file:///tmp/missing" : "https://unreachable.invalid/missing",
            kind: kind, formatHint: format)
          var options = YlAppleLoadOptions()
          if policy == 1 { source.networkPolicy = .managed }
          if policy == 2 { options.bufferStrategy = .bounded; options.minDurationMs = 100; options.maxDurationMs = 500; options.maxManagedBytes = 16 * 1024 * 1024 }
          if policy == 3 { options.decoderPolicy = .hardwareRequired }
          source.loadOptions = options
          let production = YlEngineRouter.assess(source)
          if (policy > 0) && (format == .matroska || (format == .flv && kind == .network)) {
            XCTAssertEqual(production.outcome, .requiresInspection)
            if policy != 3 { XCTAssertTrue(production.satisfiedRequirements.contains(policy == 1 ? .networkManaged : .bufferBounded)) }
            else { XCTAssertFalse(production.satisfiedRequirements.contains(.decoderHardwareRequired)) }
            if policy == 2 { XCTAssertTrue(production.limitations.contains(.bufferOsMemoryExcluded)) }
          } else if policy > 0 {
            XCTAssertEqual(production.rejection?.code, "policy.unsupported", "\(kind) \(format) \(policy)")
          }
          let assessed = YlEngineRouter.assess(source, availability: enforcing)
          let fallback = format == .matroska || (format == .flv && kind == .network)
          let av = [.hls, .mp4, .mov].contains(format)
          if fallback {
            XCTAssertEqual(assessed.outcome, .requiresInspection)
            XCTAssertEqual(assessed.engine, .managedFallback)
            XCTAssertTrue(assessed.limitations.contains(.codecRequiresInspection))
            XCTAssertFalse(assessed.satisfiedRequirements.contains(.decoderHardwareRequired))
          } else if av && policy == 0 {
            XCTAssertEqual(assessed.outcome, .compatible)
            XCTAssertEqual(assessed.engine, .avPlayer)
            XCTAssertTrue(assessed.limitations.contains(.decoderModeUnknown))
          } else {
            XCTAssertEqual(assessed.outcome, .incompatible)
            XCTAssertNil(assessed.candidate)
          }
        }
      }
    }
  }

  func testCustomCredentialsAndOrdinaryHeadersRequireControlledRoutes() {
    for metadata in 0..<2 {
      for format: YlSourceFormat in [.hls, .mp4, .mov, .matroska, .flv] {
        var source = YlAppleSourceDescriptor(uri: "https://unreachable.invalid/media", kind: .network, formatHint: format)
        if metadata == 0 { source.headers = ["X-Client": "ordinary"] }
        else { source.credentials = ["X-Custom-Secret": "private"] }
        let result = YlEngineRouter.assess(source)
        if format == .hls { XCTAssertEqual(result.candidate, .headeredHls) }
        else if [.mp4, .mov].contains(format) { XCTAssertEqual(result.rejection?.code, "container.headers_require_fallback") }
        else { XCTAssertEqual(result.engine, .managedFallback) }
      }
    }
    let live = YlAppleSourceDescriptor(uri: "https://example.test/live.mkv", kind: .network, intent: .live)
    XCTAssertEqual(YlEngineRouter.assess(live).rejection?.code, "container.network_mkv_live_unsupported")
  }

  func testInspectedCodecAndHardwareEvidenceAreRequiredBeforeGuarantee() {
    var source = YlAppleSourceDescriptor(uri: "file:///tmp/missing.mkv", kind: .file)
    source.loadOptions = YlAppleLoadOptions(decoderPolicy: .hardwareRequired)
    for hasVideo in [true, false] {
      for hardware in [nil, false, true] as [Bool?] {
        let evidence = YlSourceInspection(format: .matroska, demuxerSupported: true,
          codecsSupported: true, hasVideo: hasVideo, hardwareAccelerated: hardware)
        let result = YlEngineRouter.assess(source, availability: enforcing, inspection: evidence)
        if hasVideo && hardware != true {
          XCTAssertEqual(result.rejection?.code, "decoder.unavailable")
        } else {
          XCTAssertEqual(result.outcome, .compatible)
          XCTAssertTrue(result.satisfiedRequirements.contains(.decoderHardwareRequired))
        }
      }
    }
    for supportedDemuxer in [true, false] {
      let result = YlEngineRouter.assess(source, availability: enforcing,
        inspection: .init(format: .matroska, demuxerSupported: supportedDemuxer,
          codecsSupported: false, hasVideo: false, hardwareAccelerated: nil))
      XCTAssertEqual(result.rejection?.code, supportedDemuxer ? "decoder.unsupported" : "container.unsupported")
    }
  }

  func testUnknownFormatInspectionIsBoundedAndRefinedPolicyStillRejects() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("#EXTM3U\n#EXT-X-ENDLIST\n".utf8).write(to: file)
    var source = YlAppleSourceDescriptor(uri: file.absoluteString, kind: .file)
    XCTAssertEqual(YlEngineRouter.assess(source).candidate, .inspect)
    let inspected = try YlSourceInspector.inspect(source, configuration: .init(map: [:]), token: .init())
    XCTAssertEqual(inspected.formatHint, .hls)
    XCTAssertEqual(YlEngineRouter.assess(inspected).candidate, .avPlayer)
    source.loadOptions = YlAppleLoadOptions(bufferStrategy: .bounded, maxManagedBytes: 1024)
    let strict = try YlSourceInspector.inspect(source, configuration: .init(map: [:]), token: .init())
    XCTAssertEqual(YlEngineRouter.assess(strict, availability: enforcing).rejection?.code, "policy.unsupported")
    var beyond = Data(repeating: 0, count: YlSourceInspector.maximumBytes)
    beyond.append(Data("#EXTM3U".utf8)); try beyond.write(to: file)
    XCTAssertThrowsError(try YlSourceInspector.inspect(source, configuration: .init(map: [:]), token: .init()))
    let cancelled = YlOpenCancellationToken(); cancelled.cancel()
    XCTAssertThrowsError(try YlSourceInspector.inspect(source, configuration: .init(map: [:]), token: cancelled))
    XCTAssertEqual(YlSourceInspector.format(Data([0x1a, 0x45, 0xdf, 0xa3])), .automatic)
  }
}

@MainActor
extension YlAppleSessionTests {
  func testBoundedAndRetiredHlsHostRejectionsPreserveCommittedPlayback() async throws {
    let ledger = YlManagedBufferLedger()
    let f = AppleHostFixture(bufferLedger: ledger); defer { f.host.close() }
    let accepted = try await f.host.load(request: AppleHostFixture.request("active", autoplay: true))
    let item = try XCTUnwrap(f.av.currentItem)
    let intent = f.host.playbackIntent
    let lease = try ledger.acquireOpaqueHlsRetention()
    var bounded = AppleHostFixture.request("bounded", url: "https://unreachable.invalid/movie.mkv", format: .matroska, buffer: .bounded)
    bounded.options.bufferStrategy.minDurationMs = 100
    bounded.options.bufferStrategy.maxDurationMs = 500
    bounded.options.bufferStrategy.maxManagedBytes = 16 * 1024 * 1024
    do { _ = try await f.host.load(request: bounded); XCTFail("Opaque payload overlapped bounded preparation") }
    catch let error as PigeonError { XCTAssertEqual(error.code, "policy.unsupported") }
    XCTAssertEqual(f.host.sessionId, accepted.sessionId)
    XCTAssertTrue(f.av.currentItem === item)
    XCTAssertEqual(f.host.playbackIntent, intent)
    withExtendedLifetime(lease) {}
  }
  func testBoundedScopeRejectsHlsBeforeNetworkPreparationAndKeepsCurrentItem() async throws {
    let ledger = YlManagedBufferLedger()
    let f = AppleHostFixture(bufferLedger: ledger); defer { f.host.close() }
    let accepted = try await f.host.load(request: AppleHostFixture.request("active", autoplay: true))
    let item = try XCTUnwrap(f.av.currentItem), intent = f.host.playbackIntent
    let scope = try ledger.makeScope(maxBytes: 16 * 1024 * 1024)
    var hls = AppleHostFixture.request("hls", url: "https://unreachable.invalid/master.m3u8", format: .hls)
    hls.source.request = AppleHttpRequestMessage(headers: ["X-Test": "ordinary"], credentials: [:])
    do { _ = try await f.host.load(request: hls); XCTFail("HLS prepared while bounded payload remained") }
    catch let error as PigeonError { XCTAssertEqual(error.code, "policy.unsupported") }
    XCTAssertEqual(f.host.sessionId, accepted.sessionId)
    XCTAssertTrue(f.av.currentItem === item)
    XCTAssertEqual(f.host.playbackIntent, intent)
    withExtendedLifetime(scope) {}
  }
}

extension YlEngineAssessmentTests {
  func testBoundedPlanRequiresCompleteValidDurationsAndSoleByteBoundary() {
    var source = YlAppleSourceDescriptor(uri: "https://example.test/movie.mkv", kind: .network)
    source.loadOptions = YlAppleLoadOptions(bufferStrategy: .bounded, minDurationMs: 100,
      maxDurationMs: 500, maxManagedBytes: 16 * 1024 * 1024)
    let supported = YlEngineRouter.assess(source)
    XCTAssertEqual(supported.engine, .managedFallback)
    XCTAssertTrue(supported.satisfiedRequirements.contains(.bufferBounded))
    XCTAssertTrue(supported.limitations.contains(.bufferOsMemoryExcluded))
    for format in [YlSourceFormat.hls, .mp4, .mov] {
      var system = source; system.formatHint = format
      XCTAssertEqual(YlEngineRouter.assess(system).rejection?.code, "policy.unsupported")
    }
    source.loadOptions?.maxManagedBytes = 1
    XCTAssertEqual(YlEngineRouter.assess(source).rejection?.code, "policy.unsupported")
    source.loadOptions?.maxManagedBytes = 16 * 1024 * 1024
    source.loadOptions?.maxDurationMs = 10
    XCTAssertEqual(YlEngineRouter.assess(source).rejection?.code, "policy.unsupported")
    source.loadOptions?.minDurationMs = nil
    XCTAssertEqual(YlEngineRouter.assess(source).rejection?.code, "policy.unsupported")
  }
}


@MainActor
final class YlAudioOwnershipTests: XCTestCase {
  final class Driver: YlAudioSessionDriving {
    var onInterruption: ((YlAudioInterruption) -> Void)?
    var calls = [String]()
    var failActivation = false
    func configureMediaPlayback() throws { calls.append("configure") }
    func activate() throws {
      calls.append("activate")
      if failActivation { throw NSError(domain: "activation", code: 1) }
    }
    func deactivateNotifyingOthers() throws { calls.append("deactivate.notifyOthers") }
  }
  private var server: RollbackHlsServer?
  private func request(_ id: String) throws -> AppleLoadRequest {
    if server == nil {
      let bundle = Bundle(for: Self.self)
      let instance = try RollbackHlsServer(
        key: Data(contentsOf: XCTUnwrap(bundle.url(forResource: "hls_key", withExtension: "bin"))),
        segment: Data(contentsOf: XCTUnwrap(bundle.url(forResource: "hls_encrypted_segment0", withExtension: "ts"))))
      server = instance
      addTeardownBlock { instance.close() }
    }
    return AppleHostFixture.request(id, url: server!.url.absoluteString, format: .hls)
  }
  func registry(_ coordinator: YlAudioOwnershipCoordinator) -> YlApplePlayerRegistry {
    YlApplePlayerRegistry(makeServices: { _ in YlAppleRegistryTests.services() },
      makeCallbacks: { _ in AppleRecordingCallbacks() }, installHost: { _, _ in }, audioOwnership: coordinator)
  }
  func create(_ registry: YlApplePlayerRegistry, managed: Bool = true) throws -> YlApplePlayerHost {
    let reply = try registry.create(request: .init(schemaMajor: 2,
      options: .init(decoderPolicy: .systemDefault, audioPolicy: managed ? .pluginManagedMediaPlayback : .appManaged, positionUpdateIntervalMs: 100)))
    return try XCTUnwrap(registry.host(for: reply.channelSuffix))
  }
  func testPluginManagedPlayersInSeparateRegistriesAreSupported() async throws {
    let driver = Driver()
    let shared = YlAudioOwnershipCoordinator(driver: driver)
    let first = registry(shared), second = registry(shared)
    defer { first.detach(); second.detach() }
    let a = try create(first), b = try create(second)
    XCTAssertEqual(a.playerId, b.playerId, "Registry identity separates equal local Player IDs")
    let loadedA = try await a.load(request: request("a"))
    let loadedB = try await b.load(request: request("b"))
    XCTAssertTrue(driver.calls.isEmpty, "Create/load do not acquire")
    try await a.play(command: .init(sessionId: loadedA.sessionId))
    XCTAssertEqual(driver.calls, ["configure", "activate"])
    try await b.play(command: .init(sessionId: loadedB.sessionId))
    XCTAssertEqual(shared.ownerCount, 2)
    XCTAssertEqual(driver.calls, ["configure", "activate"])
    let c = try create(first)
    let loadedC = try await c.load(request: request("same-registry"))
    try await c.play(command: .init(sessionId: loadedC.sessionId))
    try a.pause(command: .init(sessionId: loadedA.sessionId))
    XCTAssertEqual(shared.ownerCount, 3)
    XCTAssertEqual(driver.calls, ["configure", "activate"])
    first.detach(); first.detach()
    XCTAssertEqual(shared.ownerCount, 1)
    XCTAssertEqual(driver.calls, ["configure", "activate"])
    try await b.stop()
    XCTAssertEqual(shared.ownerCount, 0)
    second.detach()
    XCTAssertEqual(driver.calls, ["configure", "activate", "deactivate.notifyOthers"])
  }
  func testAppManagedCompleteLifecycleMakesZeroDriverCalls() async throws {
    let driver = Driver()
    let coordinator = YlAudioOwnershipCoordinator(driver: driver)
    let r = registry(coordinator); defer { r.detach() }
    let host = try create(r, managed: false)
    let loaded = try await host.load(request: request("app"))
    try await host.play(command: .init(sessionId: loaded.sessionId))
    try host.pause(command: .init(sessionId: loaded.sessionId))
    try await host.stop(); host.close(); r.detach()
    XCTAssertTrue(driver.calls.isEmpty)
    XCTAssertEqual(coordinator.ownerCount, 0)
  }
  func testFailedActivationRejectsPlayWithoutOwnershipOrPlaybackIntent() async throws {
    let driver = Driver(); driver.failActivation = true
    let coordinator = YlAudioOwnershipCoordinator(driver: driver), av = AVPlayer()
    let owner = YlPlayerAudioOwnership(coordinator: coordinator, key: .init(registry: UUID(), player: "same"))
    let host = YlApplePlayerHost(playerId: 1, suffix: "failure",
      options: .init(decoderPolicy: .systemDefault, audioPolicy: .pluginManagedMediaPlayback, positionUpdateIntervalMs: 100),
      services: YlAppleRegistryTests.services(), callbacks: AppleRecordingCallbacks(), avPlayer: av, audioOwnership: owner)
    defer { host.close() }
    let load = try await host.load(request: request("a"))
    do { try await host.play(command: .init(sessionId: load.sessionId)); XCTFail("Activation must fail") } catch {}
    XCTAssertEqual(coordinator.ownerCount, 0)
    XCTAssertEqual(av.rate, 0)
    XCTAssertFalse(host.playbackIntent)
    XCTAssertEqual(driver.calls, ["configure", "activate"])
    driver.failActivation = false
    try await host.play(command: .init(sessionId: load.sessionId))
    XCTAssertEqual(coordinator.ownerCount, 1)
    host.close()
    XCTAssertEqual(driver.calls.last, "deactivate.notifyOthers")
  }
  func testSamePlayerReplacementAndFailedPreparationKeepOwnedLease() async throws {
    let driver = Driver()
    let coordinator = YlAudioOwnershipCoordinator(driver: driver)
    let r = registry(coordinator); defer { r.detach() }
    let host = try create(r)
    let a = try await host.load(request: request("a"))
    try await host.play(command: .init(sessionId: a.sessionId))
    var rejected = AppleHostFixture.request("unsupported", format: .mp4)
    rejected.options.bufferStrategy = .init(kind: .bounded, minDurationMs: 100, maxDurationMs: 500, maxManagedBytes: 16 * 1024 * 1024)
    do { _ = try await host.load(request: rejected); XCTFail("Unsupported preparation must fail") } catch {}
    XCTAssertEqual(host.sessionId, a.sessionId)
    XCTAssertTrue(host.playbackIntent)
    _ = try await host.load(request: request("replacement"))
    XCTAssertEqual(coordinator.ownerCount, 1)
    XCTAssertEqual(driver.calls, ["configure", "activate"])
  }
  func testRetiredSessionPermitCannotAcquireOrReleaseNewSessionLease() throws {
    let driver = Driver()
    let shared = YlAudioOwnershipCoordinator(driver: driver)
    let owner = YlPlayerAudioOwnership(coordinator: shared, key: .init(registry: UUID(), player: "one"))
    let old = owner.beginSession(); try owner.acquire(old.token)
    let replacement = owner.beginSession(); try owner.acquire(replacement.token)
    XCTAssertThrowsError(try owner.acquire(old.token))
    owner.release(ifCurrent: old.token)
    XCTAssertEqual(shared.ownerCount, 1)
    owner.release(ifCurrent: replacement.token)
    owner.release(ifCurrent: replacement.token)
    XCTAssertEqual(driver.calls, ["configure", "activate", "deactivate.notifyOthers"])
  }
  func testFailedCandidateRollsBackOnlyItsOwnNewAcquisition() throws {
    let driver = Driver()
    let coordinator = YlAudioOwnershipCoordinator(driver: driver)
    let owner = YlPlayerAudioOwnership(coordinator: coordinator, key: .init(registry: UUID(), player: "one"))
    let candidate = owner.beginSession(); try owner.acquire(candidate.token); owner.rollback(candidate)
    XCTAssertEqual(coordinator.ownerCount, 0)
    let old = owner.beginSession(); try owner.acquire(old.token)
    let failed = owner.beginSession(); owner.rollback(failed)
    try owner.acquire(old.token)
    XCTAssertEqual(coordinator.ownerCount, 1)
    XCTAssertEqual(driver.calls.filter { $0 == "deactivate.notifyOthers" }.count, 1)
    owner.stop(); XCTAssertEqual(coordinator.ownerCount, 0)
  }
  func testInterruptionResumesOnlyPriorIntentAndCannotReviveStoppedPlayer() async throws {
    let driver = Driver()
    let shared = YlAudioOwnershipCoordinator(driver: driver)
    let first = registry(shared), second = registry(shared)
    defer { first.detach(); second.detach() }
    let a = try create(first), b = try create(second)
    let aLoad = try await a.load(request: request("playing"))
    _ = try await b.load(request: request("paused"))
    try await a.play(command: .init(sessionId: aLoad.sessionId))
    driver.onInterruption?(.began)
    XCTAssertFalse(a.isActive)
    driver.onInterruption?(.ended(shouldResume: true))
    try await AppleHostCharacterizations.waitFor({ a.isActive && a.playbackIntent })
    XCTAssertFalse(b.playbackIntent)
    XCTAssertEqual(driver.calls.filter { $0 == "activate" }.count, 2, "Interruption resume must reacquire native activation once")
    driver.onInterruption?(.began)
    try await a.stop()
    driver.onInterruption?(.ended(shouldResume: true))
    for _ in 0..<5 { await Task.yield() }
    XCTAssertNil(a.sessionId)
    XCTAssertEqual(shared.ownerCount, 0)
  }
  func testInterruptionWithoutResumePermissionDoesNotAutoplay() async throws {
    let driver = Driver()
    let coordinator = YlAudioOwnershipCoordinator(driver: driver)
    let managed = registry(coordinator); defer { managed.detach() }
    let host = try create(managed)
    let load = try await host.load(request: request("play"))
    try await host.play(command: .init(sessionId: load.sessionId))
    driver.onInterruption?(.began); driver.onInterruption?(.ended(shouldResume: false))
    for _ in 0..<8 { await Task.yield() }
    XCTAssertFalse(host.playbackIntent)
  }
  func testUnownedReleaseDoesNotClaimAnExternalAppActivation() {
    let driver = Driver()
    let shared = YlAudioOwnershipCoordinator(driver: driver)
    shared.release(.init(registry: UUID(), player: "external"))
    shared.releaseRegistry(UUID())
    XCTAssertTrue(driver.calls.isEmpty)
    XCTAssertEqual(shared.ownerCount, 0)
  }
  #if os(iOS)
  @MainActor
  func testActualIosDriverConfiguresMediaSessionAcrossRegistryOwners() throws {
    let session = AVAudioSession.sharedInstance()
    let oldCategory = session.category, oldMode = session.mode, oldOptions = session.categoryOptions
    let driver = YlIosAudioSession(session: session)
    let shared = YlAudioOwnershipCoordinator(driver: driver)
    let first = YlAudioOwnershipKey(registry: UUID(), player: "same-player-id")
    let second = YlAudioOwnershipKey(registry: UUID(), player: "same-player-id")
    defer {
      shared.release(first); shared.release(second)
      try? session.setCategory(oldCategory, mode: oldMode, options: oldOptions)
    }
    try shared.acquire(first)
    XCTAssertEqual(session.category, .playback)
    XCTAssertEqual(session.mode, .moviePlayback)
    try shared.acquire(second)
    XCTAssertEqual(shared.ownerCount, 2)
    shared.release(first)
    XCTAssertTrue(shared.contains(second)); XCTAssertEqual(shared.ownerCount, 1)
    XCTAssertEqual(session.category, .playback)
    shared.release(second); XCTAssertEqual(shared.ownerCount, 0)
    let attachment = XCTAttachment(string: "Actual AVAudioSession driver accepted playback/moviePlayback activation and final release; two registry UUIDs. Global active state is intentionally not readable; exact deactivation calls are covered by injected-driver ownership tests. Physical interruption and multi-FlutterEngine evidence pending.")
    attachment.name = "Task8-real-audio-session"; attachment.lifetime = .keepAlways; add(attachment)
  }
  #endif
  #if os(macOS)
  func testMacosDriverTracksOutputWithoutGlobalSession() throws {
    let driver = YlMacosAudioSession()
    let shared = YlAudioOwnershipCoordinator(driver: driver)
    let key = YlAudioOwnershipKey(registry: UUID(), player: "one")
    try shared.acquire(key); XCTAssertTrue(driver.outputActive)
    shared.release(key); XCTAssertFalse(driver.outputActive)
    XCTAssertEqual(shared.ownerCount, 0)
  }
  #endif
}

final class YlObservabilityBoundaryTests: XCTestCase {
  func testUnobservedFallbackRebufferCountersMustRemainAbsent() {
    let m = YlBackendStateEncoder.fallbackMetrics(openDurationMs: nil, firstFrameDurationMs: nil,
      bufferedDurationMs: nil, bufferedBytes: nil, droppedVideoFrames: 0, audioUnderruns: 0, reconnectCount: 0)
    XCTAssertNil(m.rebufferCount)
    XCTAssertNil(m.rebufferDurationMs)
  }
  @MainActor
  func testDiagnosticFuzzAcrossNativeFailureStateRetryAndDescriptions() {
    let payloads = ["https://user:password@[2001:db8::1]/private?token=SECRET", "network.SECRET",
      "%53%45%43%52%45%54", "aUtHoRiZaTiOn: Bearer SECRET", "Cookie: auth=SECRET", "Basic c2VjcmV0",
      "/Users/private/secret.mov", "0 Module 0x1234 closure #1 in secret()"]
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    for index in 0..<100 {
      let secret = payloads[index % payloads.count] + String(repeating: "SECRET", count: index)
      let error = NativePlayerError(category: secret, code: secret, message: secret, diagnostic: secret)
      let reducer = YlAppleStateReducer(playerId: 1, clock: { 0 })
      let id = reducer.makeIdentity(loadRequestId: "safe")
      reducer.commit(id)
      var failures = [AppleFailureMessage]()
      reducer.onOutput = { event in
        switch event {
        case .retry(_, _, _, let error), .failed(_, let error):
          failures.append(YlAppleFailureMapper.message(error, scope: .session))
        default: break
        }
      }
      reducer.accept(.init(generation: 1, event: .retry(attempt: 1, delayMs: 1, error: error)), identity: id)
      reducer.fail(error)
      failures.append(fixture.host.encode(reducer.state).failure!)
      XCTAssertEqual(failures.count, 3)
      let strings = failures.map { String(describing: $0) } + [String(describing: error), String(reflecting: error)]
      for value in strings {
        XCTAssertFalse(value.contains(secret)); XCTAssertFalse(value.contains("SECRET"))
        XCTAssertLessThanOrEqual(value.count, 512)
      }
    }
  }
  func testDiagnosticMustNotPublishEvenCredentialFreeURLs() {
    let value = YlAvPlayerRecoveryPolicy.diagnostic(error: nil, errorDomain: nil, statusCode: nil,
      uri: "https://media.test/private/user/movie.m3u8")
    XCTAssertFalse(value.contains("media.test"))
    XCTAssertFalse(value.contains("movie.m3u8"))
    let proxyBody = String(data: YlHlsMediaProxy.badGatewayBody(
      NSError(domain: "https://media.test/private?token=SECRET", code: 7,
        userInfo: [NSLocalizedDescriptionKey: "Authorization: Bearer SECRET"])), encoding: .utf8)
    XCTAssertEqual(proxyBody, "Playback operation failed.")
  }
  func testRepeatedSafeCommandMappingPreservesClassificationWithoutRawForwarding() {
    let error = NativePlayerError(category: "cancelled", code: "session.stale", message: "SECRET")
    let first = YlAppleFailureMapper.command(error)
    let next = YlAppleFailureMapper.command(first)
    XCTAssertFalse(first === next)
    XCTAssertEqual(next.code, "session.stale")
    XCTAssertEqual((next.details as? AppleFailureMessage)?.category, .cancelled)
    XCTAssertFalse(next.localizedDescription.contains("SECRET"))
  }
  func testUntrustedPigeonFailureCannotBypassSafeBoundary() {
    let secrets = ["https://user:password@[2001:db8::1]/private?token=SECRET", "%53%45%43%52%45%54", "aUtHoRiZaTiOn: Bearer SECRET", "Cookie: auth=SECRET", "Basic c2VjcmV0", "/Users/private/secret.mov", "0 Module 0x1234 closure #1 in secret()"]
    for secret in secrets {
      let result = YlAppleFailureMapper.command(PigeonError(code: secret, message: secret, details: secret))
      for value in [result.code, result.message ?? "", String(describing: result.details)] {
        XCTAssertFalse(value.contains(secret))
        XCTAssertLessThanOrEqual(value.count, 512)
      }
    }
  }
}

// A pending remote asset must never be synchronously inspected by state publication.
private final class PendingGeometryAsset: AVURLAsset, @unchecked Sendable {
  var synchronousTrackReads = 0
  override func tracks(withMediaType mediaType: AVMediaType) -> [AVAssetTrack] {
    synchronousTrackReads += 1
    return []
  }
}

private final class PendingGeometryPlayer: AVPlayer {
  let pendingItem: AVPlayerItem
  init(item: AVPlayerItem) { pendingItem = item; super.init() }
  override var currentItem: AVPlayerItem? { pendingItem }
}

@MainActor
final class YlAvPlayerNonblockingMetadataTests: XCTestCase {
  func testStatePublicationDoesNotSynchronouslyReadPendingAssetTracks() throws {
    let url = try XCTUnwrap(URL(string: "https://example.test/pending.m3u8"))
    let asset = PendingGeometryAsset(url: url)
    let player = PendingGeometryPlayer(item: AVPlayerItem(asset: asset))
    let services = YlPlatformServices(platform: .current, textureOutput: AppleTestTexture(),
      makeDisplayDriver: { _ in AppleTestDisplay() })
    var states = [YlNativeState]()
    let backend = YlAvPlayerBackend(playerId: 97, services: services,
      configuration: PlayerConfiguration(map: [:]), player: player,
      emit: { if case .state(let state) = $0.event { states.append(state) } })
    defer { backend.dispose() }

    backend.emitState()
    backend.emitState()

    XCTAssertEqual(states.count, 2)
    XCTAssertNil(states.last?.geometry)
    XCTAssertEqual(asset.synchronousTrackReads, 0,
      "Snapshot publication must not block the platform/UI thread waiting for network metadata")
  }
}

final class YlGeometryAndMetricTests: XCTestCase {
  func testManagedMetricsReadSingleLedgerIncludingRetiredGenerationUntilRelease() throws {
    let ledger = YlManagedBufferLedger(maxBytes: 4096)
    let scope = try ledger.makeScope(maxBytes: 4096)
    let bounded = YlMetricsCollector(scope: scope, bounded: true)
    let unbounded = YlMetricsCollector(scope: scope, bounded: false)
    XCTAssertEqual(bounded.snapshot.bufferedBytes, 0)
    XCTAssertNil(unbounded.snapshot.bufferedBytes)
    XCTAssertNil(unbounded.snapshot.bufferedDurationMs)
    var retained = ledger.reserve(category: .queuedVideoFrames, bytes: 1024, generation: 1)
    XCTAssertNotNil(retained)
    ledger.invalidate(generation: 1)
    XCTAssertEqual(bounded.snapshot.bufferedBytes, 1024)
    retained = nil
    XCTAssertEqual(bounded.snapshot.bufferedBytes, 0)
  }
  func testAVAssetTrackPreferredTransformFlowsIntoPublicGeometry() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: 320, AVVideoHeightKey: 180])
    input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 180, ty: 0)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
    var pixel: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
    let buffer = try XCTUnwrap(pixel)
    CVPixelBufferLockBaseAddress(buffer, [])
    if let address = CVPixelBufferGetBaseAddress(buffer) { memset(address, 0, CVPixelBufferGetDataSize(buffer)) }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    for index in 0..<3 {
      for _ in 0..<100 where !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 10_000_000) }
      XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
    }
    input.markAsFinished(); await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    XCTAssertEqual(tracks.count, 1)
    let track = try XCTUnwrap(tracks.first)
    let transform = try await track.load(.preferredTransform)
    XCTAssertEqual(transform.b, 1, accuracy: 0.001)
    let geometry = try XCTUnwrap(YlVideoGeometryResolver.avPlayer(item: AVPlayerItem(asset: asset)))
    XCTAssertEqual(geometry.encodedSize, CGSize(width: 320, height: 180))
    XCTAssertEqual(geometry.displaySize, CGSize(width: 320, height: 180))
    XCTAssertEqual(geometry.finalDisplaySize, CGSize(width: 180, height: 320))
    XCTAssertEqual(geometry.message.rotationDegrees, 90)
  }

  func testLoadToReadyIncludesPreparationUsingSessionMonotonicClock() {
    var now: Int64 = 100
    let reducer = YlAppleStateReducer(playerId: 1, clock: { now })
    let id = reducer.makeIdentity(loadRequestId: "load")
    now = 200; reducer.commit(id)
    var state = YlNativeState.characterizationReady
    state.metrics.openDurationMs = 5 // engine construction is later than Load
    reducer.accept(.init(generation: 1, event: .state(state)), identity: id)
    XCTAssertEqual(reducer.state.snapshot?.metrics.openDurationMs, 100)
    now = 225; reducer.publicFrame(identity: id)
    XCTAssertEqual(reducer.state.snapshot?.metrics.firstFrameDurationMs, 125)
    now = 400; reducer.accept(.init(generation: 2, event: .state(state)), identity: id)
    XCTAssertEqual(reducer.state.snapshot?.metrics.openDurationMs, 100)
  }
  private func format(_ extensions: [String: Any] = [:]) throws -> CMVideoFormatDescription {
    var result: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
      width: 720, height: 480, extensions: extensions as CFDictionary, formatDescriptionOut: &result), noErr)
    return try XCTUnwrap(result)
  }
  func testCleanApertureAndPARApplyExactlyOnceWithUnappliedQuarterTurns() throws {
    let f = try format([
      kCMFormatDescriptionExtension_CleanAperture as String: [
        kCMFormatDescriptionKey_CleanApertureWidth as String: 704,
        kCMFormatDescriptionKey_CleanApertureHeight as String: 460,
        kCMFormatDescriptionKey_CleanApertureHorizontalOffset as String: 0,
        kCMFormatDescriptionKey_CleanApertureVerticalOffset as String: 0],
      kCMFormatDescriptionExtension_PixelAspectRatio as String: [
        kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String: 10,
        kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String: 11]])
    for rotation in [90, 270, -90, 450] {
      let g = try XCTUnwrap(YlVideoGeometryResolver.managed(format: f, rotationDegrees: rotation))
      XCTAssertEqual(g.encodedSize, CGSize(width: 720, height: 480))
      XCTAssertEqual(g.cleanAperture.size, CGSize(width: 704, height: 460))
      XCTAssertEqual(g.displaySize.width, 704, accuracy: 0.001)
      XCTAssertEqual(g.displaySize.height, 460)
      XCTAssertEqual(g.pixelAspectRatio, 10.0 / 11, accuracy: 0.00001)
      XCTAssertEqual(g.message.displaySize.width, 704, accuracy: 0.001)
      XCTAssertEqual(g.message.pixelAspectRatio, 10.0 / 11, accuracy: 0.00001)
      XCTAssertEqual(g.finalDisplaySize, CGSize(width: 460, height: 640))
      XCTAssertEqual(g.rotationDegrees, (rotation % 360 + 360) % 360)
    }
    let oriented = try XCTUnwrap(YlVideoGeometryResolver.managed(format: f, rotationDegrees: 90, pixelsAreOriented: true))
    XCTAssertEqual(oriented.rotationDegrees, 0)
    XCTAssertEqual(oriented.pixelAspectRatio, 1)
    XCTAssertEqual(oriented.displaySize, CGSize(width: 460, height: 640))
    XCTAssertEqual(oriented.finalDisplaySize, CGSize(width: 460, height: 640))
    let viewFixture = try XCTUnwrap(YlVideoGeometryResolver.resolve(
      encodedSize: CGSize(width: 720, height: 576), cleanAperture: nil,
      pixelAspectRatio: 16.0 / 15, rotationDegrees: 90))
    XCTAssertEqual(viewFixture.message.displaySize.width, 720)
    XCTAssertEqual(viewFixture.message.displaySize.height, 576)
    XCTAssertEqual(viewFixture.message.pixelAspectRatio, 16.0 / 15, accuracy: 0.00001)
    XCTAssertEqual(viewFixture.finalDisplaySize, CGSize(width: 576, height: 768))
  }
  func testAbsentMetadataUsesValidFormatButRejectsInvalidMeasurements() throws {
    var pixel: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180,
      kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
    let buffer = try XCTUnwrap(pixel)
    let frame = try XCTUnwrap(YlVideoGeometryResolver.avPlayer(pixelBuffer: buffer))
    XCTAssertEqual(frame.encodedSize, CGSize(width: 320, height: 180))
    XCTAssertEqual(frame.displaySize, CGSize(width: 320, height: 180))
    XCTAssertEqual(frame.pixelAspectRatio, 1)
    let rotated = try XCTUnwrap(YlVideoGeometryResolver.avPlayer(pixelBuffer: buffer, rotationDegrees: 90))
    XCTAssertEqual(rotated.finalDisplaySize, CGSize(width: 180, height: 320))
    let g = try XCTUnwrap(YlVideoGeometryResolver.managed(format: format()))
    XCTAssertEqual(g.encodedSize, g.displaySize)
    XCTAssertEqual(g.pixelAspectRatio, 1)
    XCTAssertEqual(g.rotationDegrees, 0)
    XCTAssertNil(YlVideoGeometryResolver.avPlayer(presentationSize: .zero, naturalSize: .zero,
      preferredTransform: .identity, format: nil))
    for invalid in [0.0, -1.0, Double.nan, Double.infinity] {
      XCTAssertNil(YlVideoGeometryResolver.resolve(encodedSize: CGSize(width: invalid, height: 480),
        cleanAperture: nil, pixelAspectRatio: 1, rotationDegrees: 0))
      XCTAssertNil(YlVideoGeometryResolver.resolve(encodedSize: CGSize(width: 720, height: 480),
        cleanAperture: nil, pixelAspectRatio: invalid, rotationDegrees: 0))
    }
    XCTAssertNil(YlVideoGeometryResolver.managed(format: try format(), rotationDegrees: 45))
    XCTAssertNil(YlVideoGeometryResolver.resolve(encodedSize: CGSize(width: 720, height: 480),
      cleanAperture: CGRect(x: 0, y: 0, width: -1, height: 10), pixelAspectRatio: 1, rotationDegrees: 0))
  }
  func testAVPreferredTransformAndPresentationFallbackDoNotDoubleRotate() throws {
    for degrees in [90.0, 270.0] {
      let transform = CGAffineTransform(rotationAngle: degrees * .pi / 180)
      let g = try XCTUnwrap(YlVideoGeometryResolver.avPlayer(presentationSize: CGSize(width: 480, height: 720),
        naturalSize: CGSize(width: 720, height: 480), preferredTransform: transform, format: format()))
      XCTAssertEqual(g.displaySize, CGSize(width: 720, height: 480))
      XCTAssertEqual(g.rotationDegrees, Int(degrees))
      XCTAssertEqual(g.finalDisplaySize, CGSize(width: 480, height: 720))
    }
    let fallback = try XCTUnwrap(YlVideoGeometryResolver.avPlayer(presentationSize: CGSize(width: 320, height: 180),
      naturalSize: CGSize(width: 320, height: 180), preferredTransform: .identity, format: nil))
    XCTAssertEqual(fallback.displaySize, CGSize(width: 320, height: 180))
    XCTAssertEqual(YlMetricsCollector.decoderMode(state: .characterizationReady), .unknown)
  }
  func testMonotonicMilestonesNullableCountersAndNonOverlappingRebuffers() {
    var now: Int64 = 100
    let m = YlMetricsCollector(clock: { now })
    XCTAssertNil(m.snapshot.openDurationMs)
    XCTAssertNil(m.snapshot.rebufferCount)
    XCTAssertNil(m.snapshot.droppedVideoFrames)
    XCTAssertNil(m.snapshot.audioUnderruns)
    XCTAssertNil(m.snapshot.reconnectCount)
    m.observe(.playback("buffering")) // startup is not a rebuffer
    now = 125; m.observe(.ready(durationMs: nil))
    XCTAssertEqual(m.snapshot.openDurationMs, 25)
    XCTAssertEqual(m.snapshot.rebufferCount, 0)
    m.observe(.playback("buffering"))
    XCTAssertEqual(m.snapshot.rebufferCount, 0, "Startup waiting is not a rebuffer")
    now = 140; m.observe(.firstFrame(durationMs: nil))
    m.observe(.playback("playing"))
    now = 150; m.observe(.playback("buffering"))
    now = 160; m.observe(.playback("buffering"))
    XCTAssertEqual(m.snapshot.rebufferCount, 1)
    XCTAssertEqual(m.snapshot.rebufferDurationMs, 10)
    now = 175; m.observe(.playback("paused"))
    m.observe(.playback("paused"))
    now = 200; m.observe(.ready(durationMs: 999)); m.observe(.firstFrame(durationMs: 999))
    XCTAssertEqual(m.snapshot.openDurationMs, 25)
    XCTAssertEqual(m.snapshot.firstFrameDurationMs, 40)
    XCTAssertEqual(m.snapshot.rebufferDurationMs, 25)
    m.observe(.videoDropped(total: 0)); m.observe(.audioUnderruns(total: 0))
    XCTAssertEqual(m.snapshot.droppedVideoFrames, 0)
    XCTAssertEqual(m.snapshot.audioUnderruns, 0)
    m.observe(.reconnect(id: 1)); m.observe(.reconnect(id: 1)); m.observe(.reconnect(id: 2))
    XCTAssertEqual(m.snapshot.reconnectCount, 2)
    XCTAssertNil(m.snapshot.bufferedBytes)
    XCTAssertNil(m.snapshot.bufferedDurationMs)
    XCTAssertNil(YlApplePlayerHost.metrics(m.snapshot).estimatedBitrate)
  }
}

/// Observe the actual binary send boundary; acknowledgements deliberately resume
/// from a background queue so each subsequent callback crosses an async boundary.
private final class AppleThreadRecordingMessenger: NSObject, FlutterBinaryMessenger {
  struct Record {
    let method: String
    let channel: String
    let isMainThread: Bool
    let argumentCount: Int
  }
  private let lock = NSLock()
  private var storage = [Record]()
  private let delivered: XCTestExpectation
  init(delivered: XCTestExpectation) { self.delivered = delivered }
  var records: [Record] { lock.lock(); defer { lock.unlock() }; return storage }
  func send(onChannel channel: String, message: Data?) {
    send(onChannel: channel, message: message, binaryReply: nil)
  }
  func send(onChannel channel: String, message: Data?, binaryReply: FlutterBinaryReply?) {
    let arguments = YlPlayerApplePigeonCodec.shared.decode(message) as? [Any]
    let method = channel.split(separator: ".").dropLast().last.map(String.init) ?? ""
    lock.lock()
    storage.append(.init(method: method, channel: channel, isMainThread: Thread.isMainThread,
      argumentCount: arguments?.count ?? -1))
    lock.unlock()
    delivered.fulfill()
    let response = YlPlayerApplePigeonCodec.shared.encode([NSNull()])
    DispatchQueue.global().async { binaryReply?(response) }
  }
  func setMessageHandlerOnChannel(_ channel: String,
      binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection { 0 }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
}
