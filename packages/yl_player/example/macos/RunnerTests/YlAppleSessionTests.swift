import XCTest
import CoreVideo
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
    XCTAssertEqual(reducer.state.snapshot?.metrics.openDurationMs, 15)
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
