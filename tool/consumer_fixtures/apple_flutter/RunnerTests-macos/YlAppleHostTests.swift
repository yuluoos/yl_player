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
