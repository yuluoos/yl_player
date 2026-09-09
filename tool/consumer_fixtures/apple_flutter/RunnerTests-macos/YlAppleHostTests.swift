import XCTest
import Network
@testable import yl_player_apple

@MainActor
final class YlAppleHostTests: XCTestCase {
  func testCancelOpenMatchesOnlyThePreparingCandidate() async throws {
    try await AppleHostCharacterizations.cancelCandidate(self)
  }
  func testStopCancelsPendingOpenRetainsTextureAndAllowsFreshOpen() async throws {
    try await AppleHostCharacterizations.stopPending(self)
  }
  func testCapabilitiesUseCanonicalCodecIdentifiers() async throws {
    try await AppleHostCharacterizations.capabilities(self)
  }
  func testChannelGenerationsAreStrictlyIncreasing() async throws {
    try await AppleHostCharacterizations.generations(self)
  }
  func testStateEnvelopeUsesVersionedGeneration() async throws {
    try await AppleHostCharacterizations.fullState(self)
  }
  func testPluginChannelNamesMatchTheDartAdapter() async throws {
    try await AppleHostCharacterizations.channels(self)
  }
  func testFallbackStateDeltaRetainsGenerationEnvelope() async throws {
    try await AppleHostCharacterizations.delta(self)
  }
  func testFailedReplacementThenReactivationPreservesAcceptedSessionControls() async throws {
    try await AppleHostCharacterizations.reactivation(self)
  }
  func testActiveFallbackReplacementUsesDefaultAudioBackedClock() async throws {
    try await AppleHostCharacterizations.activeReplacement(self)
  }
}

@MainActor
final class YlAppleRestorationTests: XCTestCase {
  func testRequestObserverDoesNotTreatCancelledEmptyConnectionAsHttpRequest() async throws {
    let gate = AppleRequestGate()
    let server = try ReactivationMediaServer(data: Data([1]), onRequest: gate.observe)
    defer { server.close() }
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(server.url.port!))!, using: .tcp)
    let connected = expectation(description: "actual idle TCP connection")
    connection.stateUpdateHandler = { if case .ready = $0 { connected.fulfill() } }
    connection.start(queue: .global())
    await fulfillment(of: [connected], timeout: 2)
    connection.cancel()
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertTrue(gate.observed.isEmpty, "EOF is not an HTTP request: \(gate.observed)")
  }

  func testAcceptedPauseWinsHeldForegroundReprepareAndCredentialsReachEveryReader() async throws {
    let gate = AppleRequestGate()
    let server = try ReactivationMediaServer(data: AppleHostCharacterizations.fixtureMedia(), onRequest: gate.observe)
    defer { gate.release(); server.close() }
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    var request = AppleHostFixture.request("credentials", url: server.url.absoluteString, format: .matroska, autoplay: true)
    request.source.request = .init(headers: ["X-Display": "visible"], credentials: ["X-Session-Identity": "private"])
    let loaded = try await f.load(request)
    try await AppleHostCharacterizations.waitFor({ f.host.initialState.timeline.positionMs > 50 })
    f.host.suspend()
    try await Task.sleep(nanoseconds: 100_000_000)
    let entered = expectation(description: "foreground uses actual new network reader")
    gate.onHeld = { entered.fulfill() }
    gate.arm()
    let before = gate.observed.count
    f.host.resume()
    await fulfillment(of: [entered], timeout: 5)
    try f.host.pause(command: .init(sessionId: loaded.sessionId))
    gate.release()
    try await AppleHostCharacterizations.waitFor({ f.host.isActive }, timeout: 5)
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertFalse(f.host.playbackIntent, "Accepted Pause must beat older foreground autoplay intent")
    XCTAssertEqual(f.host.initialState.status, .paused)
    XCTAssertEqual(f.host.sessionId, loaded.sessionId)
    XCTAssertGreaterThan(gate.observed.count, before)
    for request in gate.observed {
      XCTAssertTrue(request.contains("x-session-identity: private"), "Observed request: \(request.debugDescription)")
      XCTAssertTrue(request.contains("x-display: visible"), "Observed request: \(request.debugDescription)")
    }
    XCTAssertNil(f.host.initialState.failure)
  }
}

@MainActor
final class YlAppleCommandOrderingTests: XCTestCase {
  func testActualQueuedTrackAndTimelineCommandsSettleInOrderAcrossQuiescence() async throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("assets/test_media/network_seek_h264_aac.mkv")
    let server = try ReactivationMediaServer(data: Data(contentsOf: file)); defer { server.close() }
    let commands = YlAsyncCommandCoordinator()
    let f = AppleHostFixture(commandCoordinator: commands); defer { f.host.close() }
    let loaded = try await f.load(AppleHostFixture.request("tracks", url: server.url.absoluteString, format: .matroska))
    let tracks = f.host.initialState.audioTracks
    XCTAssertGreaterThanOrEqual(tracks.count, 2)
    let first = try XCTUnwrap(tracks.first?.id), second = try XCTUnwrap(tracks.last?.id)
    let held = expectation(description: "command worker held")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    var settlements = [String]()
    commands.begin(operation: { _ in held.fulfill(); _ = release.wait(timeout: .now() + 5) }, completion: { _ in settlements.append("barrier") })
    await fulfillment(of: [held], timeout: 1)
    let older = Task { () -> Bool in
      do { try await f.host.selectAudioTrack(command: .init(sessionId: loaded.sessionId, trackId: second)); settlements.append("old-success"); return true }
      catch { settlements.append("old-rejected"); return false }
    }
    await f.settle()
    f.host.quiesce()
    let newer = Task {
      try await f.host.selectAudioTrack(command: .init(sessionId: loaded.sessionId, trackId: first))
      settlements.append("new-success")
    }
    await f.settle()
    try f.host.seekTo(command: .init(sessionId: loaded.sessionId, positionMs: 700))
    do { try await f.host.selectAudioTrack(command: .init(sessionId: loaded.sessionId, trackId: "missing")); XCTFail("Missing track accepted") }
    catch { settlements.append("missing-rejected") }
    XCTAssertFalse(settlements.contains("new-success"), "Enqueued is not completed/accepted yet")
    do {
      try f.host.setVideoConstraints(command: .init(sessionId: loaded.sessionId, constraints: .init(maxWidth: 1)))
      XCTFail("Queued fixed-stream rejection must be synchronous")
    } catch let error as PigeonError { XCTAssertEqual(error.code, "decoder.quality_constraint_unsupported") }
    release.signal()
    let oldAccepted = await older.value
    try await newer.value
    XCTAssertFalse(oldAccepted, "The old active operation must reject after quiescence invalidates its activity")
    // Await-task resumption may reorder observations; authoritative FIFO effects
    // and each command Future's actual result are asserted independently.
    XCTAssertTrue(settlements.contains("old-rejected"))
    XCTAssertTrue(settlements.contains("new-success"))
    XCTAssertTrue(settlements.contains("missing-rejected"))
    try await AppleHostCharacterizations.waitFor({ !commands.hasCurrent })
    XCTAssertEqual(f.host.initialState.audioTracks.first { $0.isSelected }?.id, first)
    XCTAssertGreaterThanOrEqual(f.host.initialState.timeline.positionMs, 650)
    XCTAssertNil(f.host.initialState.failure)
    let frameCount = f.output.frames.count
    f.host.restorePeer()
    try await AppleHostCharacterizations.waitFor({ f.host.isActive })
    XCTAssertEqual(f.host.initialState.sessionId, loaded.sessionId)
    XCTAssertEqual(f.host.initialState.audioTracks.first { $0.isSelected }?.id, first)
    XCTAssertGreaterThanOrEqual(f.host.initialState.timeline.positionMs, 650)
    XCTAssertNil(f.host.initialState.failure)
    XCTAssertFalse(f.host.playbackIntent)
    XCTAssertTrue([.paused, .ready].contains(f.host.initialState.status))
    try await f.host.play(command: .init(sessionId: loaded.sessionId))
    try await AppleHostCharacterizations.waitFor({ f.output.frames.count > frameCount || f.host.initialState.failure != nil })
    XCTAssertGreaterThan(f.output.frames.count, frameCount)
    XCTAssertNil(f.host.initialState.failure)
  }
}

@MainActor
final class YlAppleAcceptedIntentTests: XCTestCase {
  func testTrackAndSeekAcceptedAfterForegroundReaderStartsSurviveReprepare() async throws {
    let gate = AppleRequestGate()
    let server = try ReactivationMediaServer(data: AppleHostCharacterizations.fixtureMedia(), onRequest: gate.observe)
    defer { gate.release(); server.close() }
    let f = AppleHostFixture(); defer { f.host.close() }
    let loaded = try await f.load(AppleHostFixture.request("late-intent", url: server.url.absoluteString, format: .matroska, autoplay: true))
    try await AppleHostCharacterizations.waitFor({ f.host.initialState.timeline.positionMs > 50 })
    let original = try XCTUnwrap(f.host.initialState.audioTracks.first { $0.isSelected }?.id)
    let other = try XCTUnwrap(f.host.initialState.audioTracks.first { $0.id != original }?.id)
    f.host.suspend()
    try await Task.sleep(nanoseconds: 100_000_000)
    let entered = expectation(description: "actual foreground reader held before accepting new intent")
    gate.onHeld = { entered.fulfill() }; gate.arm()
    f.host.resume()
    await fulfillment(of: [entered], timeout: 5)
    try await f.host.selectAudioTrack(command: .init(sessionId: loaded.sessionId, trackId: other))
    try f.host.seekTo(command: .init(sessionId: loaded.sessionId, positionMs: 3_000))
    try f.host.pause(command: .init(sessionId: loaded.sessionId))
    let frames = f.output.frames.count
    gate.release()
    try await AppleHostCharacterizations.waitFor({ f.host.isActive })
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(f.host.sessionId, loaded.sessionId)
    XCTAssertEqual(f.host.initialState.audioTracks.first { $0.isSelected }?.id, other)
    XCTAssertGreaterThanOrEqual(f.host.initialState.timeline.positionMs, 2_950)
    XCTAssertFalse(f.host.playbackIntent)
    XCTAssertNil(f.host.initialState.failure)
    try await f.host.play(command: .init(sessionId: loaded.sessionId))
    try await AppleHostCharacterizations.waitFor({ f.output.frames.count > frames || f.host.initialState.failure != nil })
    XCTAssertGreaterThan(f.output.frames.count, frames)
    XCTAssertNil(f.host.initialState.failure)
  }

  func testAcknowledgedVolumeAndSpeedSurviveStopBeforeQueuedEffectsRun() async throws {
    try await persistentSettersSurviveCancellation(stopFirst: true)
  }

  func testAcknowledgedVolumeAndSpeedSurviveReplacementBeforeQueuedEffectsRun() async throws {
    try await persistentSettersSurviveCancellation(stopFirst: false)
  }

  func testAcknowledgedPauseSeekAndConstraintsSurviveQueuedEffectCancellationOnPeerRestore() async throws {
    try await sessionSettersSurviveRestoration(network: true)
  }

  func testAcknowledgedSessionSettersSurviveLocalDirectRestoration() async throws {
    try await sessionSettersSurviveRestoration(network: false)
  }

  private func sessionSettersSurviveRestoration(network: Bool) async throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("assets/test_media/network_seek_h264_aac.mkv")
    let server = network ? try ReactivationMediaServer(data: AppleHostCharacterizations.fixtureMedia()) : nil
    defer { server?.close() }
    let commands = YlAsyncCommandCoordinator()
    let f = AppleHostFixture(commandCoordinator: commands); defer { f.host.close() }
    var request = AppleHostFixture.request("peer-setters", url: (server?.url ?? file).absoluteString, format: .matroska, autoplay: true)
    if !network { request.source.kind = .file; request.source.locator = file.path }
    let loaded = try await f.load(request)
    try await AppleHostCharacterizations.waitFor({ f.host.initialState.timeline.positionMs > 50 })
    let held = expectation(description: "command worker holds acknowledged session setter effects")
    let release = DispatchSemaphore(value: 0); defer { release.signal() }
    commands.begin(operation: { _ in held.fulfill(); _ = release.wait(timeout: .now() + 10) }, completion: { _ in })
    await fulfillment(of: [held], timeout: 1)
    try f.host.pause(command: .init(sessionId: loaded.sessionId))
    try f.host.seekTo(command: .init(sessionId: loaded.sessionId, positionMs: 3_000))
    try f.host.setVideoConstraints(command: .init(sessionId: loaded.sessionId, constraints: .init(maxHeight: 720)))
    do {
      try f.host.setVideoConstraints(command: .init(sessionId: loaded.sessionId, constraints: .init(maxWidth: 1)))
      XCTFail("Semantically invalid constraint accepted")
    } catch let error as PigeonError { XCTAssertEqual(error.code, "decoder.quality_constraint_unsupported") }
    XCTAssertThrowsError(try f.host.seekTo(command: .init(sessionId: loaded.sessionId, positionMs: -1)))
    XCTAssertEqual(f.host.acceptedVideoConstraints.maxHeight, 720)
    f.host.quiesce()
    f.host.restorePeer()
    try await AppleHostCharacterizations.waitFor({ f.host.isActive })
    XCTAssertGreaterThanOrEqual(f.host.initialState.timeline.positionMs, 2_950,
      "Restored output must incorporate the acknowledged seek before the old worker is released")
    XCTAssertTrue([.paused, .ready].contains(f.host.initialState.status),
      "Acknowledged Pause must already govern the restored backend")
    release.signal()
    try await AppleHostCharacterizations.waitFor({ !commands.hasCurrent })
    XCTAssertEqual(f.host.sessionId, loaded.sessionId)
    XCTAssertFalse(f.host.playbackIntent)
    XCTAssertGreaterThanOrEqual(f.host.initialState.timeline.positionMs, 2_950)
    XCTAssertEqual(f.host.acceptedVideoConstraints.maxHeight, 720)
    XCTAssertNil(f.host.initialState.failure)
    let restoredFrames = f.output.frames.count
    try await f.host.play(command: .init(sessionId: loaded.sessionId))
    try await AppleHostCharacterizations.waitFor({ f.output.frames.count > restoredFrames || f.host.initialState.failure != nil })
    XCTAssertGreaterThan(f.output.frames.count, restoredFrames, "Restored accepted timeline produces real decoded output")
    XCTAssertNil(f.host.initialState.failure)
    try await f.host.stop()
    XCTAssertNil(f.host.acceptedVideoConstraints.maxHeight)
    request.loadRequestId = "fresh-session"
    let fresh = try await f.load(request)
    XCTAssertNotEqual(fresh.sessionId, loaded.sessionId)
    XCTAssertTrue(f.host.playbackIntent, "New Load autoplay replaces the old session's acknowledged Pause")
    XCTAssertLessThan(f.host.initialState.timeline.positionMs, 1_000, "Old session seek does not leak into new Load")
    XCTAssertNil(f.host.acceptedVideoConstraints.maxHeight)
  }

  func testFailedLocalCandidateAfterQuiescenceRestoresAcknowledgedControlsBeforeOldWorkerRelease() async throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("assets/test_media/network_seek_h264_aac.mkv")
    let commands = YlAsyncCommandCoordinator()
    var rejectCandidate = false
    var former: YlPlaybackBackend?
    let f = AppleHostFixture(commandCoordinator: commands, beforeFallbackConstruction: { backend in
      if rejectCandidate {
        XCTAssertFalse(backend.isActive, "Failure occurs after the actual current backend quiesces")
        XCTAssertTrue(backend is YlFallbackBackend)
        former = backend
        throw NativePlayerError(category: "resource", code: "resource.test_candidate_failure", message: "Controlled construction failure")
      }
    }); defer { f.host.close() }
    var request = AppleHostFixture.request("local-active", format: .matroska, autoplay: true)
    request.source.kind = .file; request.source.locator = file.path
    let loaded = try await f.load(request)
    try await AppleHostCharacterizations.waitFor({ f.host.initialState.timeline.positionMs > 50 })
    let held = expectation(description: "old native command worker held through failed candidate")
    let release = DispatchSemaphore(value: 0); defer { release.signal() }
    commands.begin(operation: { _ in held.fulfill(); _ = release.wait(timeout: .now() + 10) }, completion: { _ in })
    await fulfillment(of: [held], timeout: 1)
    try f.host.pause(command: .init(sessionId: loaded.sessionId))
    try f.host.seekTo(command: .init(sessionId: loaded.sessionId, positionMs: 3_000))
    try f.host.setVolume(volume: 0.2)
    try f.host.setPlaybackSpeed(command: .init(sessionId: loaded.sessionId, speed: 1.5))
    try f.host.setVideoConstraints(command: .init(sessionId: loaded.sessionId, constraints: .init(maxHeight: 720)))
    rejectCandidate = true; request.loadRequestId = "post-quiescence-failure"
    do { _ = try await f.load(request); XCTFail("Controlled candidate committed") }
    catch { XCTAssertEqual((error as NSError).domain, "resource.test_candidate_failure") }
    XCTAssertTrue(try XCTUnwrap(former).isActive, "Actual former backend is reactivated by slot rollback")
    XCTAssertEqual(f.host.sessionId, loaded.sessionId)
    XCTAssertGreaterThanOrEqual(f.host.initialState.timeline.positionMs, 2_950)
    XCTAssertTrue([.paused, .ready].contains(f.host.initialState.status))
    XCTAssertFalse(f.host.playbackIntent)
    XCTAssertEqual(f.host.acceptedVideoConstraints.maxHeight, 720)
    XCTAssertNil(f.host.initialState.failure)
    XCTAssertTrue(commands.hasCurrent, "Assertions precede stale worker release")
    release.signal()
    try await AppleHostCharacterizations.waitFor({ !commands.hasCurrent })
    let frames = f.output.frames.count
    try await f.host.play(command: .init(sessionId: loaded.sessionId))
    try await AppleHostCharacterizations.waitFor({ f.output.frames.count > frames || f.host.initialState.failure != nil })
    XCTAssertGreaterThan(f.output.frames.count, frames)
    XCTAssertGreaterThanOrEqual(f.host.initialState.timeline.positionMs, 2_950)
    XCTAssertNil(f.host.initialState.failure)
    rejectCandidate = false
    let fresh = try await f.load(AppleHostFixture.request("persistent-av"))
    try await f.host.play(command: .init(sessionId: fresh.sessionId))
    XCTAssertEqual(f.av.volume, 0.2, accuracy: 0.001)
    XCTAssertEqual(f.av.rate, 1.5, accuracy: 0.001)
  }

  private func persistentSettersSurviveCancellation(stopFirst: Bool) async throws {
    let server = try ReactivationMediaServer(data: AppleHostCharacterizations.fixtureMedia()); defer { server.close() }
    let commands = YlAsyncCommandCoordinator()
    let f = AppleHostFixture(commandCoordinator: commands); defer { f.host.close() }
    let loaded = try await f.load(AppleHostFixture.request("queued-setters", url: server.url.absoluteString, format: .matroska))
    let held = expectation(description: "existing native command worker held")
    let release = DispatchSemaphore(value: 0); defer { release.signal() }
    commands.begin(operation: { _ in held.fulfill(); _ = release.wait(timeout: .now() + 10) }, completion: { _ in })
    await fulfillment(of: [held], timeout: 1)
    try f.host.setVolume(volume: 0.2)
    try f.host.setPlaybackSpeed(command: .init(sessionId: loaded.sessionId, speed: 1.5))
    XCTAssertThrowsError(try f.host.setVolume(volume: .nan))
    XCTAssertThrowsError(try f.host.setPlaybackSpeed(command: .init(sessionId: loaded.sessionId, speed: .infinity)))
    XCTAssertTrue(commands.hasCurrent, "Both synchronous setters acknowledged while effects remain queued")
    if stopFirst { try await f.host.stop() }
    let fresh = try await f.load(AppleHostFixture.request("fresh-av"))
    XCTAssertNotEqual(fresh.sessionId, loaded.sessionId)
    try await f.host.play(command: .init(sessionId: fresh.sessionId))
    XCTAssertEqual(f.av.volume, 0.2, accuracy: 0.001, "Acknowledged volume is player intent, even if the retired backend's queued effect is cancelled")
    XCTAssertEqual(f.av.rate, 1.5, accuracy: 0.001)
    release.signal()
    try await AppleHostCharacterizations.waitFor({ !commands.hasCurrent })
    XCTAssertEqual(f.av.volume, 0.2, accuracy: 0.001, "Late cancelled effects cannot overwrite the new backend")
    XCTAssertEqual(f.av.rate, 1.5, accuracy: 0.001)
    XCTAssertNil(f.host.initialState.failure)
  }
}
