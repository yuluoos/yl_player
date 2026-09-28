@testable import yl_player_apple
import AVFoundation
import XCTest
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

final class YlFairPlayOutputTests: XCTestCase {
  func testUncommittedWrongOwnerAndDuplicateViewsCannotBorrowPlayer() throws {
    let registry = YlFairPlayViewRegistry()
    let id = try registry.allocate(playerId: 1, sessionId: "s1")
    let record = registry.register(id)
    let player = AVPlayer()
    record.setPlayer(player)
    let container = CALayer()
    XCTAssertFalse(record.mount(viewId: 10, container: container))
    record.commit()
    XCTAssertNil(registry.lookup(.init(playerId: 2, surfaceId: id.surfaceId, sessionId: id.sessionId, generation: id.generation)))
    XCTAssertTrue(record.mount(viewId: 10, container: container))
    XCTAssertFalse(record.mount(viewId: 11, container: CALayer()))
    XCTAssertTrue(record.layer?.player === player)
    XCTAssertEqual(try record.ack(viewId: 10).revision, record.revision)
    record.retire()
    XCTAssertNil(registry.lookup(id))
    XCTAssertNil(record.layer)
  }
  func testRemountAndAssetReplacementCreateFreshLayerAndRejectOldReadiness() throws {
    let registry = YlFairPlayViewRegistry(), container = CALayer()
    let id = try registry.allocate(playerId: 1, sessionId: "s")
    let record = registry.register(id)
    record.setPlayer(AVPlayer()); record.commit()
    var frames = 0
    record.onFrame = { _ in frames += 1 }
    XCTAssertTrue(record.mount(viewId: 1, container: container))
    let oldLayer = record.layer!, oldRevision = record.revision
    record.setPlayer(AVPlayer())
    XCTAssertFalse(record.layer === oldLayer)
    record.presented(layer: oldLayer, revision: oldRevision)
    XCTAssertEqual(frames, 0)
    let layer = record.layer!, revision = record.revision
    record.presented(layer: layer, revision: revision)
    XCTAssertEqual(frames, 1)
    record.detach(viewId: 1)
    record.presented(layer: layer, revision: revision)
    XCTAssertEqual(frames, 1)
    XCTAssertNil(layer.player)
    record.retire()
  }
  func testProtectionPolicyRejectsStrictAndHeaderedMediaWithoutGuessingEvidence() throws {
    var source = YlAppleSourceDescriptor(uri: "https://media.test/a.m3u8", kind: .network, formatHint: .hls)
    source.drm = .init(certificate: Data([1]), contentId: Data([2]), timeoutMs: 1000)
    let assessment = YlEngineRouter.assess(source)
    XCTAssertEqual(assessment.outcome, .requiresInspection)
    XCTAssertEqual(assessment.candidate, .fairPlay)
    source.networkPolicy = .managed
    XCTAssertEqual(YlEngineRouter.assess(source).rejection?.code, "policy.unsupported")
    source.networkPolicy = .platformDefault; source.credentials = ["Authorization": "SECRET"]
    XCTAssertEqual(YlEngineRouter.assess(source).rejection?.code, "policy.unsupported")
    source.credentials = [:]; source.loadOptions = .init(); source.loadOptions?.decoderPolicy = .hardwareRequired
    XCTAssertEqual(YlEngineRouter.assess(source).rejection?.code, "policy.unsupported")
  }
  func testPauseRemainsPausedAcrossPeriodicStateAndControlUpdates() throws {
    let views = YlFairPlayViewRegistry()
    let id = try views.allocate(playerId: 1, sessionId: "s1")
    let backend = YlFairPlayBackend(source: .init(uri: "https://media.test/a.m3u8", kind: .network),
      record: views.register(id), bridge: .init(playerId: 1, views: views, callbacks: ProtectedCallbacks()),
      events: .init(identity: .init(sessionId: "s1", loadRequestId: "l1"), emit: { _, _ in }))
    defer { backend.dispose() }
    XCTAssertEqual(backend.playbackStatus, "ready")
    try backend.pause()
    XCTAssertEqual(backend.playbackStatus, "paused")
    try backend.setVolume(0.5); try backend.setPlaybackSpeed(1.5)
    XCTAssertEqual(backend.playbackStatus, "paused")
  }

  func testConcurrentRestorationsSharePreparationAndEveryCommandSettles() {
    let gate = YlFairPlayPreparation()
    var completions = 0
    XCTAssertTrue(gate.begin { _ in completions += 1 })
    XCTAssertFalse(gate.begin { _ in completions += 1 })
    XCTAssertTrue(gate.isPending)
    gate.finish(.failure(YlFairPlayFailure.error("load.cancelled")))
    XCTAssertEqual(completions, 2)
    XCTAssertFalse(gate.isPending)
    gate.finish(.success(()))
    XCTAssertEqual(completions, 2)
    XCTAssertTrue(gate.begin { _ in completions += 1 })
    gate.finish(.success(()))
    XCTAssertEqual(completions, 3)
  }

  func testPostActivationFailureRestoresOldBackendAndAudioAuthority() throws {
    for platform in [YlApplePlatform.ios, .macos] {
      let old = ProtectedBackendSpy(), candidate = ProtectedBackendSpy()
      try old.activate()
      let slot = YlBackendSlot(initial: old, compatibility: .init(platform: platform))
      var authorityRestored = false
      XCTAssertThrowsError(try slot.replace(beforeRollbackActivation: { _ in authorityRestored = true },
        afterActivation: { _ in throw YlFairPlayFailure.error("drm.session_failed") }) { candidate })
      XCTAssertTrue(slot.current === old)
      XCTAssertTrue(old.isActive)
      XCTAssertFalse(old.disposed)
      XCTAssertTrue(authorityRestored)
      XCTAssertTrue(candidate.disposed)
    }
  }

  @MainActor func testBridgeCancelsOldExchangeAndRejectsMismatchedReply() async throws {
    let callbacks = ProtectedCallbacks()
    let views = YlFairPlayViewRegistry()
    let bridge = YlFairPlayBridge(playerId: 1, views: views, callbacks: callbacks)
    let surface = try views.allocate(playerId: 1, sessionId: "s1")
    var replies: [Result<Data, NativePlayerError>] = []
    let requested = expectation(description: "challenge sent")
    callbacks.onRequest = { requested.fulfill() }
    let cancelled = expectation(description: "cancel sent")
    callbacks.onCancel = { cancelled.fulfill() }
    let cancel = bridge.exchange(surface: surface, loadId: "load1", id: .init(epoch: 1, requestId: 1),
      challenge: Data([7])) { replies.append($0) }
    await fulfillment(of: [requested], timeout: 2)
    XCTAssertEqual(callbacks.requests.count, 1)
    cancel()
    await fulfillment(of: [cancelled], timeout: 2)
    XCTAssertEqual(callbacks.cancelled.count, 1)
    callbacks.respond(index: 0, wrongOwner: false)
    await Task.yield()
    XCTAssertTrue(replies.isEmpty)
    let renewed = expectation(description: "renewal sent")
    let rejected = expectation(description: "foreign response rejected")
    callbacks.onRequest = { renewed.fulfill() }
    _ = bridge.exchange(surface: surface, loadId: "load1", id: .init(epoch: 2, requestId: 1),
      challenge: Data([7])) { replies.append($0); rejected.fulfill() }
    await fulfillment(of: [renewed], timeout: 2)
    callbacks.respond(index: 1, wrongOwner: true)
    await fulfillment(of: [rejected], timeout: 2)
    XCTAssertEqual(replies.count, 1)
    if case let .failure(error) = replies.first { XCTAssertEqual(error.code, "drm.license_response_invalid") }
    else { XCTFail("A foreign reply must not install a license") }
  }

  @MainActor func testBridgeAcceptsOnlyMountedOwnedRecord() async throws {
    let views = YlFairPlayViewRegistry()
    let bridge = YlFairPlayBridge(playerId: 1, views: views, callbacks: ProtectedCallbacks())
    let id = try views.allocate(playerId: 1, sessionId: "s1")
    let record = views.register(id)
    let command = AppleProtectedViewCommand(surface: id.message, viewId: 42)
    do { _ = try await bridge.attachProtectedView(command: command); XCTFail("Uncommitted") } catch {}
    record.commit(); record.setPlayer(AVPlayer())
    XCTAssertTrue(record.mount(viewId: 42, container: CALayer()))
    let ack = try await bridge.attachProtectedView(command: command)
    XCTAssertTrue(ack.attached)
    XCTAssertEqual(ack.surface, id.message)
    record.retire()
    let detached = try await bridge.detachProtectedView(command: command)
    XCTAssertFalse(detached.attached)
  }

}

private final class ProtectedCallbacks: AppleDrmFlutterApiProtocol {
  var onRequest: (() -> Void)?
  var onCancel: (() -> Void)?
  var requests: [AppleDrmLicenseRequest] = []
  var cancelled: [AppleDrmExchangeId] = []
  var replies: [CheckedContinuation<AppleDrmLicenseReply, Error>] = []
  func exchangeLicense(request: AppleDrmLicenseRequest) async throws -> AppleDrmLicenseReply {
    try await withCheckedThrowingContinuation { completion in
      requests.append(request); replies.append(completion); onRequest?()
    }
  }
  func respond(index: Int, wrongOwner: Bool) {
    var id = requests[index].id
    if wrongOwner { id.surface.playerId = 2 }
    replies[index].resume(returning: .init(id: id, response: FlutterStandardTypedData(bytes: Data([8]))))
  }
  func cancelLicense(id: AppleDrmExchangeId) async throws { cancelled.append(id); onCancel?() }
  func onProtectedFrame(frame: AppleProtectedViewAck) async throws {}
}

private final class ProtectedBackendSpy: YlPlaybackBackend {
  var isActive = false
  var disposed = false
  func activate() throws { isActive = true }
  func deactivate() { isActive = false }
  func stop() { deactivate() }
  func dispose() { disposed = true; deactivate() }
  func play() throws {}
  func pause() throws {}
  func seek(toMs: Int64, cancellationToken: YlOpenCancellationToken?) throws {}
  func seekToLiveEdge() throws {}
  func setPlaybackSpeed(_ speed: Float) throws {}
  func setVolume(_ volume: Float) throws {}
  func selectAudioTrack(_ trackId: String, cancellationToken: YlOpenCancellationToken?) throws {}
  func setVideoConstraints(_ constraints: YlAppleVideoConstraints) throws {}
  func emitState() {}
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? { nil }
}
