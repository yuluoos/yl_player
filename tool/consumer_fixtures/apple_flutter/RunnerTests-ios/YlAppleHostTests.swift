import XCTest
import UIKit
@testable import yl_player_apple

@MainActor
final class YlAppleHostTests: XCTestCase {
  func testCancelOpenMatchesOnlyThePreparingCandidate() async throws {
    try await AppleHostCharacterizations.cancelCandidate(self)
  }
  func testPlayerVolumeAndCandidateOptionsSurviveFailedReplacementAndStop() async throws {
    try await AppleHostCharacterizations.volumeAndOptions(self)
  }
  func testStopCancelsPendingOpenRetainsTextureAndAllowsFreshOpen() async throws {
    try await AppleHostCharacterizations.stopPending(self)
  }
  func testPlayerPersistsSuccessfulQualityConstraint() async throws {
    try await AppleHostCharacterizations.persistedQuality(self)
  }
  func testCapabilitiesDescribeCompletePlayerWithCanonicalMimeCodecs() async throws {
    try await AppleHostCharacterizations.capabilities(self)
  }
  func testCapabilitiesOmitUnsupportedHardwareCodecs() async throws {
    try await AppleHostCharacterizations.capabilities(self, hevc: false)
  }
  func testFallbackMetricsUseDartContractDroppedFrameKey() async throws {
    try await AppleHostCharacterizations.metrics(self)
  }
  func testChannelGenerationsAreStrictlyIncreasing() async throws {
    try await AppleHostCharacterizations.generations(self)
  }
  func testFullStateEnvelopeUsesVersionedGeneration() async throws {
    try await AppleHostCharacterizations.fullState(self)
  }
  func testDeltaEnvelopeContainsOnlyDynamicPayload() async throws {
    try await AppleHostCharacterizations.delta(self)
  }
  func testFailedReplacementThenReactivationPreservesAcceptedSessionControls() async throws {
    try await AppleHostCharacterizations.reactivation(self)
  }
}

@MainActor
final class YlAppleMemoryWarningTests: XCTestCase {
  func testForegroundRestoresOnlyPreviouslyActivePlayer() async throws {
    let center = NotificationCenter()
    let registry = YlApplePlayerRegistry(makeServices: { _ in YlAppleRegistryTests.services() },
      makeCallbacks: { _ in AppleRecordingCallbacks() }, installHost: { _, _ in },
      lifecycle: YlIosLifecycle(center: center))
    defer { registry.detach() }
    let options = ApplePlayerOptionsMessage(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 500)
    let a = try registry.create(request: .init(schemaMajor: 2, options: options))
    let b = try registry.create(request: .init(schemaMajor: 2, options: options))
    let old = try XCTUnwrap(registry.host(for: a.channelSuffix))
    let current = try XCTUnwrap(registry.host(for: b.channelSuffix))
    _ = try await old.load(request: AppleHostFixture.request("old"))
    _ = try await current.load(request: AppleHostFixture.request("current"))
    XCTAssertFalse(old.isActive)
    XCTAssertTrue(current.isActive)
    var oldRestorations = 0
    let oldCommit = old.didCommit
    old.didCommit = { oldRestorations += 1; oldCommit?() }
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    XCTAssertFalse(current.isActive)
    center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    try await AppleHostCharacterizations.waitFor({ current.isActive })
    XCTAssertFalse(old.isActive)
    XCTAssertEqual(oldRestorations, 0, "Foreground cannot revive a peer that was inactive before suspension")
  }

  func testActualLifecycleMemoryWarningDeactivatesSessionAndPreservesTexture() async throws {
    let key = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "hls_key", withExtension: "bin"))
    let segment = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "hls_encrypted_segment0", withExtension: "ts"))
    let server = try RollbackHlsServer(key: Data(contentsOf: key), segment: Data(contentsOf: segment))
    defer { server.close() }
    let center = NotificationCenter()
    let lifecycle = YlIosLifecycle(center: center)
    let output = AppleTestTexture()
    let callbacks = AppleRecordingCallbacks()
    let registry = YlApplePlayerRegistry(makeServices: { _ in
      YlPlatformServices(platform: .ios, textureOutput: output,
        makeDisplayDriver: { AppleClockDisplay(onTick: $0) }, activateAudioSession: {})
    }, makeCallbacks: { _ in callbacks }, installHost: { _, _ in }, lifecycle: lifecycle)
    defer { registry.detach() }
    let created = try registry.create(request: .init(schemaMajor: 2,
      options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 500)))
    let host = try XCTUnwrap(registry.host(for: created.channelSuffix))
    try host.attach()
    var request = AppleHostFixture.request("memory", url: server.url.absoluteString, format: .hls)
    request.source.request = .init(headers: [:], credentials: ["Authorization": "Bearer rollback-test"])
    let loaded = try await host.load(request: request)
    try await AppleHostCharacterizations.waitFor({ host.initialState.status == .ready || host.initialState.status == .paused })
    XCTAssertTrue(host.isActive)
    center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    XCTAssertFalse(host.isActive)
    XCTAssertEqual(host.sessionId, loaded.sessionId)
    XCTAssertEqual(host.initialState.status, .paused)
    XCTAssertNil(host.initialState.failure)
    XCTAssertEqual(output.disposals, 0)
    try await host.play(command: .init(sessionId: loaded.sessionId))
    XCTAssertTrue(host.isActive)
    XCTAssertEqual(host.sessionId, loaded.sessionId)
    registry.detach()
    XCTAssertEqual(output.disposals, 1)
    center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    XCTAssertEqual(output.disposals, 1)
  }
}
