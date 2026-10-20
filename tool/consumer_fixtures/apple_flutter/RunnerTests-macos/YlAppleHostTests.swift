import XCTest
import AVFoundation
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
      try await f.host.setVideoConstraints(command: .init(sessionId: loaded.sessionId, constraints: .init(maxWidth: 1)))
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
    try await f.host.setVideoConstraints(command: .init(sessionId: loaded.sessionId, constraints: .init(maxHeight: 720)))
    let held = expectation(description: "command worker holds acknowledged session setter effects")
    let release = DispatchSemaphore(value: 0); defer { release.signal() }
    commands.begin(operation: { _ in held.fulfill(); _ = release.wait(timeout: .now() + 10) }, completion: { _ in })
    await fulfillment(of: [held], timeout: 1)
    try f.host.pause(command: .init(sessionId: loaded.sessionId))
    try f.host.seekTo(command: .init(sessionId: loaded.sessionId, positionMs: 3_000))
    do {
      try await f.host.setVideoConstraints(command: .init(sessionId: loaded.sessionId, constraints: .init(maxWidth: 1)))
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
        throw NativePlayerError(category: "resource", code: "resource.video_decoder_limit", message: "Controlled construction failure")
      }
    }); defer { f.host.close() }
    var request = AppleHostFixture.request("local-active", format: .matroska, autoplay: true)
    request.source.kind = .file; request.source.locator = file.path
    let loaded = try await f.load(request)
    try await AppleHostCharacterizations.waitFor({ f.host.initialState.timeline.positionMs > 50 })
    try await f.host.setVideoConstraints(command: .init(sessionId: loaded.sessionId, constraints: .init(maxHeight: 720)))
    let held = expectation(description: "old native command worker held through failed candidate")
    let release = DispatchSemaphore(value: 0); defer { release.signal() }
    commands.begin(operation: { _ in held.fulfill(); _ = release.wait(timeout: .now() + 10) }, completion: { _ in })
    await fulfillment(of: [held], timeout: 1)
    try f.host.pause(command: .init(sessionId: loaded.sessionId))
    try f.host.seekTo(command: .init(sessionId: loaded.sessionId, positionMs: 3_000))
    try f.host.setVolume(volume: 0.2)
    try f.host.setPlaybackSpeed(command: .init(sessionId: loaded.sessionId, speed: 1.5))
    rejectCandidate = true; request.loadRequestId = "post-quiescence-failure"
    do { _ = try await f.load(request); XCTFail("Controlled candidate committed") }
    catch { XCTAssertEqual((error as NSError).domain, "resource.video_decoder_limit") }
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
    // This continuation actually plays. A placeholder network URL can fail
    // between Load and Play and cannot establish persistent-control behavior.
    let mp4 = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("assets/test_media/format_matrix/mp4-avc-aac.mp4")
    var freshRequest = AppleHostFixture.request("persistent-av")
    freshRequest.source.kind = .file; freshRequest.source.locator = mp4.path
    let fresh = try await f.load(freshRequest)
    try await f.host.play(command: .init(sessionId: fresh.sessionId))
    try await AppleHostCharacterizations.waitFor({ f.av.rate == 1.5 || f.host.initialState.failure != nil })
    XCTAssertNil(f.host.initialState.failure)
    XCTAssertEqual(f.av.volume, 0.2, accuracy: 0.001)
    XCTAssertEqual(f.av.rate, 1.5, accuracy: 0.001)
  }

  /// Exercise the iOS retention policy with real macOS media services. Managed
  /// candidates reject known impossible limits before retiring that lease.
  func testRetainedTransactionEarlyQualityFailurePreservesAcknowledgedPauseAndSeek() async throws {
    try await retainedTransactionEarlyFailure(newerSeek: false)
  }

  func testNewerSeekWinsReplayedIntentAfterRetainedTransactionFailure() async throws {
    try await retainedTransactionEarlyFailure(newerSeek: true)
  }

  private func retainedTransactionEarlyFailure(newerSeek: Bool) async throws {
    let server = try ReactivationMediaServer(data: AppleHostCharacterizations.fixtureMedia()); defer { server.close() }
    let commands = YlAsyncCommandCoordinator()
    var observingFailure = false
    var candidateConstructions = 0
    let f = AppleHostFixture(commandCoordinator: commands, beforeFallbackConstruction: { _ in
      if observingFailure { candidateConstructions += 1 }
    }, slotCompatibility: .init(platform: .ios)); defer { f.host.close() }
    let loaded = try await f.load(AppleHostFixture.request("retained-current", url: server.url.absoluteString, format: .matroska, autoplay: true))
    try await AppleHostCharacterizations.waitFor({ f.host.initialState.timeline.positionMs > 50 })
    let held = expectation(description: "old command worker held across retained-transaction early failure")
    let release = DispatchSemaphore(value: 0); defer { release.signal() }
    commands.begin(operation: { _ in held.fulfill(); _ = release.wait(timeout: .now() + 10) }, completion: { _ in })
    await fulfillment(of: [held], timeout: 1)
    try f.host.pause(command: .init(sessionId: loaded.sessionId))
    try f.host.seekTo(command: .init(sessionId: loaded.sessionId, positionMs: 3_000))
    let clears = f.output.clears
    observingFailure = true
    do {
      _ = try await f.load(AppleHostFixture.request("valid-unplayable-width", url: server.url.absoluteString, format: .matroska, width: 1))
      XCTFail("Media cannot satisfy the valid positive width constraint")
    } catch { XCTAssertEqual((error as NSError).domain, "decoder.quality_constraint_unsupported") }
    XCTAssertEqual(candidateConstructions, 0, "Known impossible limits fail before candidate construction")
    XCTAssertTrue(f.host.isActive, "Early rejection keeps the accepted engine active")
    XCTAssertEqual(f.output.clears, clears, "Early rejection must not retire accepted output")
    XCTAssertEqual(f.host.sessionId, loaded.sessionId)
    XCTAssertFalse(f.host.playbackIntent, "Acknowledged Pause survives early rejection without engine retirement")
    XCTAssertNil(f.host.initialState.failure)
    XCTAssertTrue(commands.hasCurrent)
    if newerSeek { try f.host.seekTo(command: .init(sessionId: loaded.sessionId, positionMs: 4_500)) }
    let minimumPosition: Int64 = newerSeek ? 4_450 : 2_950
    release.signal()
    try await AppleHostCharacterizations.waitFor({ f.host.isActive && !commands.hasCurrent })
    XCTAssertEqual(f.host.sessionId, loaded.sessionId)
    XCTAssertFalse(f.host.playbackIntent)
    XCTAssertTrue([.paused, .ready].contains(f.host.initialState.status))
    XCTAssertGreaterThanOrEqual(f.host.initialState.timeline.positionMs, minimumPosition)
    XCTAssertNil(f.host.initialState.failure)
    let frames = f.output.frames.count
    try await f.host.play(command: .init(sessionId: loaded.sessionId))
    try await AppleHostCharacterizations.waitFor({ f.output.frames.count > frames || f.host.initialState.failure != nil })
    XCTAssertGreaterThan(f.output.frames.count, frames)
    XCTAssertGreaterThanOrEqual(f.host.initialState.timeline.positionMs, minimumPosition)
    XCTAssertNil(f.host.initialState.failure)
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
    let mp4 = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("assets/test_media/format_matrix/mp4-avc-aac.mp4")
    var freshRequest = AppleHostFixture.request("fresh-av")
    freshRequest.source.kind = .file; freshRequest.source.locator = mp4.path
    let fresh = try await f.load(freshRequest)
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

// Keep the real engine's handler storage/connection semantics. Only the Dart
// transport and texture registry are substituted; no Dart isolate/media is needed.
import Cocoa
import FlutterMacOS

@MainActor
final class YlMacosHostConnectionTests: XCTestCase {
  func testDisposedPlayersRemoveAllPlayerEngineChannelRecords() async throws {
    let registrar = ConnectionRegistrar()
    YlPlayerApplePlugin.register(with: registrar)
    defer { registrar.plugin?.detachFromEngine(for: registrar) }
    XCTAssertEqual(try registrar.transport.pluginChannelCount(), 1)
    for _ in 0..<3 {
      let player = try await create(registrar)
      XCTAssertEqual(try registrar.transport.pluginChannelCount(), 19)
      XCTAssertEqual(try registrar.transport.airPlayChannelCount(), 1)
      _ = try await registrar.transport.call("ApplePlayerHostApi.dispose.\(player.channelSuffix)", arguments: nil)
      XCTAssertEqual(try registrar.transport.pluginChannelCount(), 1,
        "Dispose must remove records, including nil-handler records, for all 15 player + 3 DRM channels")
      XCTAssertEqual(try registrar.transport.airPlayChannelCount(), 0)
    }
  }

  func testDetachRemovesFactoryAndEveryLivePlayerOnlyOnce() async throws {
    let registrar = ConnectionRegistrar()
    YlPlayerApplePlugin.register(with: registrar)
    _ = try await create(registrar)
    _ = try await create(registrar)
    XCTAssertEqual(try registrar.transport.pluginChannelCount(), 37)
    registrar.plugin?.detachFromEngine(for: registrar)
    XCTAssertEqual(try registrar.transport.pluginChannelCount(), 0)
    registrar.plugin?.detachFromEngine(for: registrar)
    XCTAssertEqual(try registrar.transport.pluginChannelCount(), 0,
      "Repeated detach must not insert a fresh nil-handler factory record")
  }

  func testDisposingOnePlayerPreservesPeerAndNewerForeignConnection() async throws {
    let registrar = ConnectionRegistrar()
    YlPlayerApplePlugin.register(with: registrar)
    defer { registrar.plugin?.detachFromEngine(for: registrar) }
    let first = try await create(registrar), peer = try await create(registrar)
    let replacement = "ApplePlayerHostApi.setVolume.\(first.channelSuffix)"
    let connection = registrar.transport.setMessageHandlerOnChannel(ConnectionTransport.prefix + replacement,
      binaryMessageHandler: { _, reply in reply(ApplePlayerHostApiSetup.codec.encode(["replacement"])) })
    defer { registrar.transport.cleanUpConnection(connection) }
    _ = try await registrar.transport.call("ApplePlayerHostApi.dispose.\(first.channelSuffix)", arguments: nil)
    XCTAssertEqual(try registrar.transport.pluginChannelCount(), 20,
      "Factory, live peer's 18 channels, and newer foreign connection must survive")
    let reply = try await registrar.transport.call(replacement, arguments: nil)
    XCTAssertEqual(reply.first as? String, "replacement")
    let peerReply = try await registrar.transport.call("ApplePlayerHostApi.setVolume.\(peer.channelSuffix)", arguments: [0.3])
    XCTAssertEqual(peerReply.count, 1)
    XCTAssertTrue(peerReply[0] is NSNull)
  }

  private func create(_ registrar: ConnectionRegistrar) async throws -> AppleCreateReply {
    let values = try await registrar.transport.call("ApplePlayerFactoryHostApi.create", arguments: [
      AppleCreateRequest(schemaMajor: 7, options: .init(decoderPolicy: .systemDefault,
        audioPolicy: .appManaged, positionUpdateIntervalMs: 250))])
    return try XCTUnwrap(values.first as? AppleCreateReply)
  }
}

private final class ConnectionTransport: NSObject, FlutterBinaryMessenger {
  static let prefix = "dev.flutter.pigeon.yl_player_apple."
  let engine = FlutterEngine(name: "channel-cleanup-regression", project: nil, allowHeadlessExecution: true)
  private var handlers: [String: (FlutterBinaryMessengerConnection, FlutterBinaryMessageHandler)] = [:]

  func pluginChannelCount() throws -> Int {
    // Test-only inspection of the actual local macOS engine; production uses
    // only FlutterBinaryMessenger's public connection API.
    let records = try XCTUnwrap(engine.value(forKey: "messengerHandlers") as? [String: Any])
    return records.keys.filter { $0.hasPrefix(Self.prefix) }.count
  }
  func airPlayChannelCount() throws -> Int {
    let records = try XCTUnwrap(engine.value(forKey: "messengerHandlers") as? [String: Any])
    return records.keys.filter { $0.hasPrefix("dev.ylplayer.airplay.") }.count
  }
  func call(_ name: String, arguments: [Any?]?) async throws -> [Any] {
    let handler = try XCTUnwrap(handlers[Self.prefix + name]?.1, "Missing active route: \(name)")
    let codec = ApplePlayerHostApiSetup.codec
    let data = await withCheckedContinuation { continuation in
      handler(codec.encode(arguments)) { continuation.resume(returning: $0) }
    }
    return try XCTUnwrap(codec.decode(data) as? [Any])
  }
  func send(onChannel channel: String, message: Data?) {}
  func send(onChannel channel: String, message: Data?, binaryReply: FlutterBinaryReply?) {
    binaryReply?(ApplePlayerHostApiSetup.codec.encode([nil] as [Any?]))
  }
  func setMessageHandlerOnChannel(_ channel: String,
      binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection {
    let connection = engine.binaryMessenger.setMessageHandlerOnChannel(channel, binaryMessageHandler: handler)
    handlers[channel] = handler.map { (connection, $0) }
    return connection
  }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {
    engine.binaryMessenger.cleanUpConnection(connection)
    handlers = handlers.filter { $0.value.0 != connection }
  }
}

private final class ConnectionRegistrar: NSObject, FlutterPluginRegistrar, FlutterTextureRegistry {
  let transport = ConnectionTransport()
  var plugin: YlPlayerApplePlugin?
  var messenger: FlutterBinaryMessenger { transport }
  var textures: FlutterTextureRegistry { self }
  var view: NSView? { nil }
  var viewController: NSViewController? { nil }
  private var nextTexture: Int64 = 0
  func register(_ texture: FlutterTexture) -> Int64 { nextTexture += 1; return nextTexture }
  func unregisterTexture(_ textureId: Int64) {}
  func textureFrameAvailable(_ textureId: Int64) {}
  func register(_ factory: FlutterPlatformViewFactory, withId factoryId: String) {}
  func addMethodCallDelegate(_ delegate: FlutterPlugin, channel: FlutterMethodChannel) {}
  func addApplicationDelegate(_ delegate: FlutterAppLifecycleDelegate) {}
  func publish(_ value: NSObject) { plugin = value as? YlPlayerApplePlugin }
  func lookupKey(forAsset asset: String) -> String { asset }
  func lookupKey(forAsset asset: String, fromPackage package: String) -> String { asset }
}

@MainActor
final class YlAirPlayHostTests: XCTestCase {
  func testDirectAirPlayAssessmentPreservesStrictPolicyRejection() throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    var request = AppleHostFixture.request("airplay", url: "https://example.invalid/video.m3u8", format: .hls)
    let direct = try f.host.assessAirPlay(request: .init(source: request.source, options: request.options))
    XCTAssertEqual(direct.outcome, .compatible)
    XCTAssertEqual(direct.candidateEngine, .avPlayer)
    request.options.decoderPolicyOverride = .hardwareRequired
    let strict = try f.host.assessAirPlay(request: .init(source: request.source, options: request.options))
    XCTAssertEqual(strict.outcome, .incompatible)
    XCTAssertEqual(strict.rejection?.code, "policy.unsupported")
  }

  func testAirPlayCustomSourceNeedsInspectionAndHeaderedHlsIsRejected() throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    var request = AppleHostFixture.request("airplay", url: "https://example.invalid/video.mkv", format: .matroska)
    let custom = try f.host.assessAirPlay(request: .init(source: request.source, options: request.options))
    XCTAssertEqual(custom.outcome, .requiresInspection)
    XCTAssertEqual(custom.candidateEngine, .avPlayer)
    request.source.format = .hls
    request.source.request = .init(headers: ["X-AirPlay-Test": "private"], credentials: [:])
    let headered = try f.host.assessAirPlay(request: .init(source: request.source, options: request.options))
    XCTAssertEqual(headered.outcome, .incompatible)
    XCTAssertEqual(headered.rejection?.code, "policy.unsupported")
    XCTAssertFalse(f.host.airPlayState["enabled"] as! Bool)
  }

  func testRejectedAirPlayLoadPreservesExistingSession() async throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    let original = try await f.load(AppleHostFixture.request("original"))
    var request = AppleHostFixture.request("rejected", url: "https://example.invalid/drm.m3u8", format: .hls)
    request.options.decoderPolicyOverride = .hardwareRequired
    do { _ = try await f.host.loadAirPlay(request: request); XCTFail("strict AirPlay load accepted") } catch {}
    XCTAssertEqual(f.host.initialState.sessionId, original.sessionId)
    XCTAssertFalse(f.host.airPlayState["enabled"] as! Bool)
  }
}


@MainActor
extension YlAirPlayHostTests {
  func testAutomaticHlsLiveLoadsReadyWithAirPlayEnabled() async throws {
    let server = try AirPlayLiveFixtureServer(bundle: Bundle(for: Self.self))
    defer { server.close() }
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    var request = AppleHostFixture.request("live-airplay", url: server.url.absoluteString, format: .automatic)
    request.source.intent = .live
    let reply = try await f.host.loadAirPlay(request: request)
    XCTAssertEqual(f.host.sessionId, reply.sessionId)
    XCTAssertEqual(f.host.initialState.engine, .avPlayer)
    XCTAssertTrue(f.av.allowsExternalPlayback)
    let item = try XCTUnwrap(f.av.currentItem)
    try await AppleHostCharacterizations.waitFor({ item.status == .readyToPlay }, timeout: 15)
    XCTAssertEqual((item.asset as? AVURLAsset)?.url, server.url,
      "Live HLS must use the original stream, never complete-VOD remux")
    XCTAssertEqual(f.host.airPlayState["enabled"] as? Bool, true)
    XCTAssertNil(f.host.initialState.failure)
  }

  func testAutomaticLiveAirPlayRequiresInspectionInsteadOfRejection() throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    var request = AppleHostFixture.request("live", url: "https://example.invalid/live.m3u8", format: .automatic)
    request.source.intent = .live
    let result = try f.host.assessAirPlay(request: .init(source: request.source, options: request.options))
    XCTAssertEqual(result.outcome, .requiresInspection)
    XCTAssertNil(result.rejection)
  }

  func testAirPlayOptInBelongsToCommittedLoadAndStopClearsIt() async throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    let loaded = try await f.host.loadAirPlay(request: AppleHostFixture.request("remote"))
    XCTAssertTrue(f.av.allowsExternalPlayback)
    XCTAssertEqual(f.host.airPlayState["sessionId"] as? String, loaded.sessionId)
    XCTAssertEqual(f.host.airPlayState["enabled"] as? Bool, true)
    let revision = try XCTUnwrap(f.host.airPlayState["revision"] as? Int64)
    _ = try await f.load(AppleHostFixture.request("local"))
    XCTAssertFalse(f.av.allowsExternalPlayback)
    XCTAssertEqual(f.host.airPlayState["enabled"] as? Bool, false)
    XCTAssertGreaterThan(f.host.airPlayState["revision"] as! Int64, revision)
    try await f.host.stop()
    XCTAssertTrue(f.host.airPlayState["sessionId"] is NSNull)
  }

  func testReplacingAirPlayWithFallbackReleasesRetiredOrigin() async throws {
    #if targetEnvironment(simulator)
    // This test asserts ownership/cleanup, not hardware decode. AVPlayer still
    // consumes the real remux; only the replacement decoder is substituted.
    let f = AppleHostFixture(videoSessionFactory: AirPlayPassiveVTFactory())
    #else
    let f = AppleHostFixture()
    #endif
    defer { f.host.close() }
    try f.host.attach()
    let server = try ReactivationMediaServer(data: AppleHostCharacterizations.fixtureMedia()); defer { server.close() }
    _ = try await f.host.loadAirPlay(request: AppleHostFixture.request("remux", url: server.url.absoluteString, format: .matroska))
    let url = try XCTUnwrap((f.av.currentItem?.asset as? AVURLAsset)?.url)
    _ = try await f.load(AppleHostFixture.request("fallback", url: server.url.absoluteString, format: .matroska))
    XCTAssertNil(f.av.currentItem)
    XCTAssertEqual(f.host.airPlayState["enabled"] as? Bool, false)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    let client = URLSession(configuration: configuration)
    defer { client.invalidateAndCancel() }
    do { _ = try await client.data(from: url); XCTFail("Replaced AirPlay origin still serves media") } catch {}
  }

  func testNetworkCustomSourceLoadsThroughAirPlayRemuxAndReleasesOriginOnStop() async throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    let server = try ReactivationMediaServer(data: AppleHostCharacterizations.fixtureMedia()); defer { server.close() }
    let reply = try await f.host.loadAirPlay(request: AppleHostFixture.request("remux", url: server.url.absoluteString, format: .matroska))
    XCTAssertEqual(f.host.initialState.sessionId, reply.sessionId)
    XCTAssertTrue(f.av.allowsExternalPlayback)
    let item = try XCTUnwrap(f.av.currentItem)
    try await AppleHostCharacterizations.waitFor({ item.status == .readyToPlay }, timeout: 15)
    XCTAssertEqual(f.host.airPlayState["enabled"] as? Bool, true)
    let url = try XCTUnwrap((item.asset as? AVURLAsset)?.url)
    XCTAssertEqual(url.pathExtension, "m3u8")
    let (_, response) = try await URLSession.shared.data(from: url)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    try await f.host.stop()
    XCTAssertNil(f.av.currentItem)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    let client = URLSession(configuration: configuration)
    defer { client.invalidateAndCancel() }
    do { _ = try await client.data(from: url); XCTFail("Retired AirPlay origin still serves media") } catch {}
  }
}

private final class AirPlayLiveFixtureServer {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "yl.test.airplay-live")
  private var connections = [NWConnection]()
  var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/live.m3u8")! }
  init(bundle: Bundle) throws {
    let segment = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "hls_encrypted_segment0", withExtension: "ts")))
    let key = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "hls_key", withExtension: "bin")))
    let playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x00000000000000000000000000000000\n"
      + (0..<5).map { "#EXT-X-DISCONTINUITY\n#EXTINF:1.968,\nsegment\($0).ts\n" }.joined()
    listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      self.connections.append(connection)
      connection.start(queue: self.queue)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { bytes, _, _, _ in
        let path = String(decoding: bytes ?? Data(), as: UTF8.self)
          .split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let body: Data; let type: String
        if path == "/live.m3u8" { body = Data(playlist.utf8); type = "application/vnd.apple.mpegurl" }
        else if path == "/key.bin" { body = key; type = "application/octet-stream" }
        else if (0..<5).contains(where: { path == "/segment\($0).ts" }) { body = segment; type = "video/mp2t" }
        else { connection.cancel(); return }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
      }
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
      listener.cancel(); throw NSError(domain: "AirPlayLiveFixtureServer", code: 1)
    }
  }
  func close() { queue.sync { listener.cancel(); connections.forEach { $0.cancel() }; connections.removeAll() } }
}

#if targetEnvironment(simulator)
private final class AirPlayPassiveVTFactory: YlVTSessionFactory {
  func makeSession(formatDescription: CMVideoFormatDescription,
      output: @escaping (YlVTDecodedImage) -> Void) throws -> YlVTSession { AirPlayPassiveVTSession() }
}
private final class AirPlayPassiveVTSession: YlVTSession {
  let usesHardwareDecoder = true
  let hardwareEvidence = YlHardwareDecoderEvidence(mode: .hardware)
  func decode(_ sample: CMSampleBuffer, generation: UInt64, reservation: YlVideoDecodeReservation?) -> OSStatus {
    reservation?.release(); return noErr
  }
  func flush() {}
  func invalidate() {}
}
#endif

@MainActor
extension YlAirPlayHostTests {
  func testHttpFlvAirPlayBecomesReadyBeforeEOFAndRollsUntilStop() async throws {
    let upstream = try AirPlayFlvFixtureServer(); defer { upstream.close() }
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    var request = AppleHostFixture.request("flv-live", url: upstream.url.absoluteString, format: .flv)
    request.source.intent = .live
    _ = try await f.host.loadAirPlay(request: request)
    let item = try XCTUnwrap(f.av.currentItem)
    try await AppleHostCharacterizations.waitFor({ item.status == .readyToPlay }, timeout: 15)
    XCTAssertTrue(f.av.allowsExternalPlayback)
    XCTAssertGreaterThan(upstream.activeCount, 0, "Load must commit while upstream remains connected")
    let origin = try XCTUnwrap((item.asset as? AVURLAsset)?.url)
    XCTAssertNotEqual(origin, upstream.url)
    let first = try await livePlaylist(origin)
    XCTAssertFalse(first.contains("#EXT-X-ENDLIST"))
    XCTAssertFalse(first.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
    XCTAssertTrue(first.contains("#EXT-X-MAP:"))
    let sequence = try mediaSequence(first)
    var rolling = first
    for _ in 0..<100 {
      rolling = try await livePlaylist(origin)
      if try mediaSequence(rolling) > sequence { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertGreaterThan(try mediaSequence(rolling), sequence)
    XCTAssertNil(f.host.initialState.failure)
    try await f.host.stop()
    try await AppleHostCharacterizations.waitFor({ upstream.activeCount == 0 }, timeout: 5)
    XCTAssertGreaterThan(upstream.disconnectCount, 0)
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 2
    let client = URLSession(configuration: config); defer { client.invalidateAndCancel() }
    do { _ = try await client.data(from: origin); XCTFail("Stopped live origin still serves requests") } catch {}
  }

  func testHttpFlvAirPlayReconnectPublishesDiscontinuityAndNewMap() async throws {
    let upstream = try AirPlayFlvFixtureServer(); defer { upstream.close() }
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    var request = AppleHostFixture.request("flv-recovery", url: upstream.url.absoluteString, format: .flv)
    request.source.intent = .live
    let reply = try await f.host.loadAirPlay(request: request)
    let item = try XCTUnwrap(f.av.currentItem)
    try await AppleHostCharacterizations.waitFor({ item.status == .readyToPlay }, timeout: 15)
    let origin = try XCTUnwrap((item.asset as? AVURLAsset)?.url)
    let before = try await livePlaylist(origin)
    let firstMaps = Set(before.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-MAP:") }.map(String.init))
    let accepted = upstream.acceptCount
    upstream.disconnectCurrent()
    try await AppleHostCharacterizations.waitFor({ upstream.acceptCount > accepted }, timeout: 10)
    var recovered = ""
    for _ in 0..<100 {
      recovered = try await livePlaylist(origin)
      let maps = Set(recovered.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-MAP:") }.map(String.init))
      if recovered.contains("#EXT-X-DISCONTINUITY\n") && !maps.subtracting(firstMaps).isEmpty { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    let maps = Set(recovered.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-MAP:") }.map(String.init))
    XCTAssertTrue(recovered.contains("#EXT-X-DISCONTINUITY\n"))
    XCTAssertFalse(maps.subtracting(firstMaps).isEmpty)
    XCTAssertFalse(recovered.contains("#EXT-X-ENDLIST"))
    XCTAssertEqual(f.host.sessionId, reply.sessionId)
    XCTAssertTrue(f.av.currentItem === item)
    XCTAssertNil(f.host.initialState.failure)
    try await f.host.stop()
  }

  func testAutomaticRtmpAirPlayBecomesReadyWithoutUpstreamEOF() async throws {
    let upstream = try YlRtmpFixturePeer(repetitions: 32); defer { upstream.close() }
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    var request = AppleHostFixture.request("rtmp-live", url: "rtmp://127.0.0.1:\(upstream.port)/live/owned", format: .automatic)
    request.source.intent = .automatic
    _ = try await f.host.loadAirPlay(request: request)
    let item = try XCTUnwrap(f.av.currentItem)
    try await AppleHostCharacterizations.waitFor({ item.status == .readyToPlay }, timeout: 15)
    let origin = try XCTUnwrap((item.asset as? AVURLAsset)?.url)
    XCTAssertEqual(origin.pathExtension, "m3u8")
    XCTAssertEqual(upstream.acceptCount, 1)
    let playlist = try await livePlaylist(origin)
    XCTAssertFalse(playlist.contains("#EXT-X-ENDLIST"))
    XCTAssertNil(f.host.initialState.failure)
    try await f.host.stop()
  }

  func testStoppingHeldRtmpAirPlayStartupCancelsPromptly() async throws {
    let upstream = try RtmpScriptPeer(prefix: Data()); defer { upstream.close() }
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    var request = AppleHostFixture.request("rtmp-held", url: "rtmp://127.0.0.1:\(upstream.port)/live/held", format: .automatic)
    request.source.intent = .live
    var completed = false
    var failure: Error?
    let loading = Task { @MainActor in
      defer { completed = true }
      do { _ = try await f.host.loadAirPlay(request: request); XCTFail("Held startup committed") }
      catch { failure = error }
    }
    try await AppleHostCharacterizations.waitFor({ upstream.acceptCount > 0 }, timeout: 5)
    try await f.host.stop()
    try await AppleHostCharacterizations.waitFor({ completed }, timeout: 3)
    await loading.value
    XCTAssertNotNil(failure)
    XCTAssertNil(f.av.currentItem)
    XCTAssertEqual(f.host.airPlayState["enabled"] as? Bool, false)
  }

  func testAutomaticRtmpsLoadAndAirPlayReachTlsAndRejectUntrustedPeer() async throws {
    for airPlay in [false, true] {
      let peer = try YlRtmpFixturePeer(tlsIdentity: ManagedTLSFixture.localhost)
      defer { peer.close() }
      let f = AppleHostFixture(); defer { f.host.close() }
      var request = AppleHostFixture.request("rtmps-auto", url: "rtmps://127.0.0.1:\(peer.port)/live/private-token", format: .automatic)
      request.source.intent = .automatic
      do {
        if airPlay { _ = try await f.host.loadAirPlay(request: request) }
        else { _ = try await f.host.load(request: request) }
        XCTFail("Untrusted RTMPS must fail")
      } catch {
        XCTAssertEqual((error as? PigeonError)?.code, "network.rtmp_tls_failed")
      }
      XCTAssertEqual(peer.acceptCount, 1)
      XCTAssertNil(f.host.sessionId)
      XCTAssertEqual(f.host.airPlayState["enabled"] as? Bool, false)
    }
  }

  func testRtmpAirPlayRetainsTransportAndStrictPolicyRejections() throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    var base = AppleHostFixture.request("rtmp-policy", url: "rtmp://127.0.0.1:1935/live/owned", format: .automatic)
    base.source.intent = .live
    var secure = base; secure.source.locator = "rtmps://127.0.0.1:1935/live/owned"
    var finite = base; finite.source.intent = .onDemand
    var headers = base; headers.source.request = .init(headers: ["Authorization": "private"], credentials: [:])
    var strict = base; strict.options.decoderPolicyOverride = .hardwareRequired
    let secureAssessment = try f.host.assessAirPlay(request: .init(source: secure.source, options: secure.options))
    XCTAssertEqual(secureAssessment.outcome, .requiresInspection)
    XCTAssertNil(secureAssessment.rejection)
    for request in [finite, headers, strict] {
      let assessment = try f.host.assessAirPlay(request: .init(source: request.source, options: request.options))
      XCTAssertEqual(assessment.outcome, .incompatible)
      XCTAssertNotNil(assessment.rejection)
    }
  }

  private func livePlaylist(_ url: URL) async throws -> String {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    return String(decoding: data, as: UTF8.self)
  }

  private func mediaSequence(_ playlist: String) throws -> Int {
    let line = try XCTUnwrap(playlist.split(separator: "\n").first { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") })
    return try XCTUnwrap(Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)))
  }
}

/// A genuinely open HTTP response: FLV header once, timestamp-shifted AV tags,
/// no video end-of-sequence marker, and no transport EOF until explicitly cut.
private final class AirPlayFlvFixtureServer {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "yl.test.airplay-flv")
  private var connections: [UUID: NWConnection] = [:]
  private var accepted = 0
  private var disconnected = 0
  private let header: Data
  private let tags: [(Data, UInt32)]
  private let span: UInt32
  var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/live.flv")! }
  var activeCount: Int { queue.sync { connections.count } }
  var acceptCount: Int { queue.sync { accepted } }
  var disconnectCount: Int { queue.sync { disconnected } }

  init() throws {
    let resource = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "flv"))
    let data = try Data(contentsOf: resource)
    header = Data(data.prefix(13))
    var parsed: [(Data, UInt32)] = []
    var offset = 13
    while offset < data.count {
      guard data.count - offset >= 15 else { throw YlByteSourceError.closed }
      let length = Int(data.rtmpUInt(offset + 1, 3))
      guard offset + length + 15 <= data.count else { throw YlByteSourceError.closed }
      let type = data[offset]
      let timestamp = UInt32(data.rtmpUInt(offset + 4, 3)) | UInt32(data[offset + 7]) << 24
      if (type == 8 || type == 9) && !(type == 9 && length >= 2 && data[offset + 12] == 2) {
        parsed.append((data.subdata(in: offset..<offset + length + 15), timestamp))
      }
      offset += length + 15
    }
    tags = parsed
    span = (parsed.map { $0.1 }.max() ?? 0) + 40
    listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      let id = UUID(); self.connections[id] = connection; self.accepted += 1
      connection.start(queue: self.queue)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] _, _, _, error in
        guard let self, error == nil else { connection.cancel(); return }
        let response = Data("HTTP/1.1 200 OK\r\nContent-Type: video/x-flv\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        var initial = response + self.header
        for epoch in 0..<16 { initial.append(self.body(epoch)) }
        connection.send(content: initial, completion: .contentProcessed { [weak self] error in
          guard let self else { return }
          if error != nil { self.retire(id); return }
          self.append(id, epoch: 16)
        })
        self.observeClose(id)
      }
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success else { listener.cancel(); throw YlByteSourceError.closed }
  }

  private func body(_ epoch: Int) -> Data {
    var output = Data()
    for (original, timestamp) in tags {
      var tag = original
      let time = timestamp + UInt32(epoch) * span
      tag[4] = UInt8(truncatingIfNeeded: time >> 16)
      tag[5] = UInt8(truncatingIfNeeded: time >> 8)
      tag[6] = UInt8(truncatingIfNeeded: time)
      tag[7] = UInt8(truncatingIfNeeded: time >> 24)
      output.append(tag)
    }
    return output
  }

  private func append(_ id: UUID, epoch: Int) {
    queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self, let connection = self.connections[id] else { return }
      connection.send(content: self.body(epoch), completion: .contentProcessed { [weak self] error in
        guard let self else { return }
        if error != nil { self.retire(id) } else { self.append(id, epoch: epoch + 1) }
      })
    }
  }

  private func observeClose(_ id: UUID) {
    guard let connection = connections[id] else { return }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, ended, error in
      guard let self else { return }
      if ended || error != nil { self.retire(id) } else { self.observeClose(id) }
    }
  }

  private func retire(_ id: UUID) {
    guard let connection = connections.removeValue(forKey: id) else { return }
    disconnected += 1
    connection.cancel()
  }
  func disconnectCurrent() { queue.sync { Array(connections.keys).forEach { retire($0) } } }
  func close() { queue.sync { listener.cancel(); Array(connections.keys).forEach { retire($0) } } }
}

@MainActor
extension YlAirPlayHostTests {
  func testLiveProducerFailureIsFencedAfterReplacementAndCurrentFailureTerminates() async throws {
    let origin = try AirPlayLiveFixtureServer(bundle: Bundle(for: Self.self)); defer { origin.close() }
    let old = AirPlayFailureFixture(), current = AirPlayFailureFixture()
    var failures: [NativePlayerError] = []
    let backend = YlAvPlayerBackend(playerId: 97,
      services: .init(platform: .current, textureOutput: AppleTestTexture(), makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: PlayerConfiguration(map: [:]), emit: {
        if case .failure(let error) = $0.event { failures.append(error) }
      })
    defer { backend.dispose() }
    try backend.activate()
    try backend.open(old.source(origin.url))
    XCTAssertEqual(old.handlers.count, 1)
    let retiredCallback = try XCTUnwrap(old.handlers.last)
    try backend.open(current.source(origin.url))
    XCTAssertEqual(old.cleanups, 1)
    retiredCallback(AirPlayFailureFixture.terminal)
    for _ in 0..<12 { await Task.yield() }
    XCTAssertTrue(failures.isEmpty)
    XCTAssertTrue(backend.isActive)
    current.fail()
    try await AppleHostCharacterizations.waitFor({ !failures.isEmpty }, timeout: 3)
    XCTAssertEqual(failures.map(\.code), [AirPlayFailureFixture.terminal.code])
    XCTAssertFalse(backend.isActive)
    backend.stop()
    XCTAssertEqual(current.cleanups, 1)
    backend.dispose()
    XCTAssertEqual(old.cleanups, 1)
    XCTAssertEqual(current.cleanups, 1)
  }

  func testSuspendedLiveProducerRetainsOwnershipAndReplaysFailureOnActivation() async throws {
    let origin = try AirPlayLiveFixtureServer(bundle: Bundle(for: Self.self)); defer { origin.close() }
    let producer = AirPlayFailureFixture()
    var failures: [NativePlayerError] = []
    let backend = YlAvPlayerBackend(playerId: 98,
      services: .init(platform: .current, textureOutput: AppleTestTexture(), makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: PlayerConfiguration(map: [:]), emit: {
        if case .failure(let error) = $0.event { failures.append(error) }
      })
    defer { backend.dispose() }
    try backend.activate()
    try backend.open(producer.source(origin.url))
    backend.deactivate()
    XCTAssertEqual(producer.cleanups, 0)
    producer.fail()
    for _ in 0..<12 { await Task.yield() }
    XCTAssertTrue(failures.isEmpty)
    try backend.activate()
    try await AppleHostCharacterizations.waitFor({ !failures.isEmpty }, timeout: 3)
    XCTAssertEqual(producer.handlers.count, 2)
    XCTAssertEqual(failures.map(\.code), [AirPlayFailureFixture.terminal.code])
    XCTAssertFalse(backend.isActive)
    backend.stop()
    XCTAssertEqual(producer.cleanups, 1)
  }
}

private final class AirPlayFailureFixture {
  static let terminal = NativePlayerError(category: "network", code: "airplay.live_failed", message: "Fixture producer ended")
  var handlers: [(NativePlayerError) -> Void] = []
  var cleanups = 0
  private var error: NativePlayerError?
  func source(_ url: URL) -> YlAppleSourceDescriptor {
    var source = YlAppleSourceDescriptor(uri: url.absoluteString, kind: .network, formatHint: .hls)
    source.intent = .live
    source.airPlay = true
    source.airPlayMedia = YlAirPlayPreparedMedia(url: url, cleanup: { self.cleanups += 1 }, observeFailure: { handler in
      self.handlers.append(handler)
      if let error = self.error { handler(error) }
    })
    return source
  }
  func fail() { error = Self.terminal; handlers.last?(Self.terminal) }
}
