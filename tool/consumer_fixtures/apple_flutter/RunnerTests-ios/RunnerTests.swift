import AVFoundation
import CoreMedia
@testable import yl_player_apple
import Flutter
import UIKit
import XCTest

class RunnerTests: XCTestCase {
  func testMediaProxyParsesOnlyExactInheritedCredentialQueryItem() {
    XCTAssertTrue(YlHlsMediaProxy.inheritsCredentialStripping(fromRequestTarget: "/token/media.ts?credentialsStripped=1"))
    XCTAssertTrue(YlHlsMediaProxy.inheritsCredentialStripping(fromRequestTarget: "/token/media.ts?other=2&credentialsStripped=1"))
    for target in ["/credentialsStripped=1/media.ts", "/token/media.ts", "/token/media.ts?credentialsStripped=10", "/token/media.ts?other=credentialsStripped%3D1", "/token/media.ts?xcredentialsStripped=1", "/token/media.ts#credentialsStripped=1"] {
      XCTAssertFalse(YlHlsMediaProxy.inheritsCredentialStripping(fromRequestTarget: target), target)
    }
  }

  func testPerLoadBufferStrategyUsesExistingGoalsWithoutChangingLegacyConfiguration() throws {
    let legacy = PlayerConfiguration(map: ["bufferMode": "stable", "audioPolicy": "appManaged"])
    let low = legacy.forLoad(["loadOptions": ["bufferStrategy": "lowLatency"]])
    XCTAssertEqual(low.bufferMode, "lowLatency")
    XCTAssertEqual(low.preferredForwardBufferDuration, 2)
    XCTAssertFalse(low.managesAudioSession)
    XCTAssertEqual(legacy.forLoad(["loadOptions": ["bufferStrategy": "smoothPlayback"]]).preferredForwardBufferDuration, 30)
    XCTAssertEqual(legacy.forLoad(["loadOptions": [:]]).preferredForwardBufferDuration, 10)
    XCTAssertEqual(legacy.forLoad([:]).preferredForwardBufferDuration, 30)
    XCTAssertEqual(legacy.bufferMode, "stable")
  }



  func testPreparingRetriesDoNotPolluteOldSessionAndCommittedRetriesRetainIdentity() {
    var publicEvents = [[String: Any?]]()
    let old = YlLegacyCommitEmitter(emit: { publicEvents.append($0) })
    old.commit(generation: 3)
    old.accept(["type": "networkRetry"])
    let candidate = YlLegacyCommitEmitter(emit: { publicEvents.append($0) })
    candidate.accept(["type": "networkRetry"])
    XCTAssertEqual(publicEvents.count, 1)
    XCTAssertEqual(publicEvents.last?["generation"] as? UInt64, 3)
    candidate.commit(generation: 4)
    old.invalidate()
    old.accept(["type": "networkRetry"])
    candidate.accept(["type": "networkRetry"])
    XCTAssertEqual(publicEvents.count, 2)
    XCTAssertEqual(publicEvents.last?["generation"] as? UInt64, 4)
  }

  func testPrivateCandidateEventsPublishOnlyAfterCommit() {
    var events = [[String: Any?]]()
    let candidate = YlLegacyCommitEmitter(emit: { events.append($0) })
    candidate.accept(["type": "state", "loadToken": 9])
    candidate.accept(["type": "firstFrame"])
    XCTAssertTrue(events.isEmpty)
    candidate.commit()
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?["loadToken"] as? Int, 9)
    candidate.accept(["type": "firstFrame"])
    XCTAssertEqual(events.count, 2)
  }

  func testExplicitCredentialScopeAndInheritedManifestStripping() throws {
    let origin = URL(string: "https://source.test/master.m3u8")!
    let policy = YlHlsHeaderPolicy(originURL: origin, headers: ["X-Client": "ordinary"], credentials: ["X-Session": "secret"])
    XCTAssertEqual(policy.headers(for: origin)["X-Session"], "secret")
    XCTAssertNil(policy.headers(for: URL(string: "https://other.test/segment.ts")!)["X-Session"])
    XCTAssertNil(policy.headers(for: origin, credentialsStripped: true)["X-Session"])
    XCTAssertEqual(policy.headers(for: origin, credentialsStripped: true)["X-Client"], "ordinary")
    let result = try YlHlsManifestRewriter.rewrite(data: Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nchild.m3u8\n".utf8), baseURL: origin, credentialsStripped: true)
    let child = try XCTUnwrap(String(data: result, encoding: .utf8)?.split(separator: "\n").last.flatMap { URL(string: String($0)) })
    XCTAssertTrue(YlHlsURLCodec.credentialsStripped(child))
    XCTAssertEqual(try YlHlsURLCodec.decode(child), URL(string: "https://source.test/child.m3u8"))
  }



  func testAppManagedAVNeverActivatesAudioSession() throws {
    var calls = 0
    let backend = YlAvPlayerBackend(playerId: 31, textures: StopTextureRegistry(),
      configuration: PlayerConfiguration(map: ["audioPolicy": "appManaged"]),
      activateAudioSession: { calls += 1 }, emit: { _ in })
    defer { backend.dispose() }
    try backend.activate()
    backend.stop()
    try backend.command(name: "open", arguments: ["source": ["uri": "https://example.test/a.mp4", "kind": "network"]])
    XCTAssertEqual(calls, 0)
  }
  func testLoadTokenBelongsToCommittedAVSourceAndRequestStateDoesNotActivate() throws {
    var events = [[String: Any?]]()
    let backend = YlAvPlayerBackend(playerId: 32, textures: StopTextureRegistry(),
      configuration: PlayerConfiguration(map: ["audioPolicy": "appManaged"]), emit: { events.append($0) })
    defer { backend.dispose() }
    backend.emitState()
    XCTAssertFalse(backend.isActive)
    try backend.command(name: "open", arguments: ["source": ["uri": "https://example.test/a.mp4", "kind": "network", "loadToken": 17]])
    XCTAssertEqual(events.last?["loadToken"] as? Int, 17)
    XCTAssertThrowsError(try backend.command(name: "open", arguments: ["source": ["uri": "", "loadToken": 18]]))
    backend.emitState()
    XCTAssertEqual(events.last?["loadToken"] as? Int, 17)
  }

  private final class StopTextureRegistry: NSObject, FlutterTextureRegistry {
    var unregistered = [Int64]()
    func register(_ texture: FlutterTexture) -> Int64 { 71 }
    func textureFrameAvailable(_ textureId: Int64) {}
    func unregisterTexture(_ textureId: Int64) { unregistered.append(textureId) }
  }

  private final class StopBarrierSession: YlVTSession {
    let usesHardwareDecoder = true
    private let lock = NSLock()
    private var invalidated = false
    var isInvalidated: Bool { lock.lock(); defer { lock.unlock() }; return invalidated }
    func decode(_ sample: CMSampleBuffer, generation: UInt64, reservation: YlVideoDecodeReservation?) -> OSStatus { noErr }
    func flush() {}
    func invalidate() { lock.lock(); invalidated = true; lock.unlock() }
  }

  private final class StopBarrierFactory: YlVTSessionFactory {
    let entered: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var values = [StopBarrierSession]()
    var sessions: [StopBarrierSession] { lock.lock(); defer { lock.unlock() }; return values }
    init(entered: XCTestExpectation) { self.entered = entered }
    func makeSession(
      formatDescription: CMVideoFormatDescription,
      output: @escaping (YlVTDecodedImage) -> Void
    ) throws -> YlVTSession {
      let session = StopBarrierSession()
      lock.lock()
      values.append(session)
      let isRecreation = values.count == 2
      lock.unlock()
      if isRecreation {
        entered.fulfill()
        guard release.wait(timeout: .now() + 10) == .success else {
          throw YlOpenCancellationToken.cancellationError()
        }
      }
      return session
    }
  }

  func testStopRejectsDecoderCreatedAfterTeardown() throws {
    for cancelCommand in [false, true] {
      let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mkv"))
      let prepared = try YlPreparedFallback(source: [
        "uri": fixture.absoluteString, "kind": "file", "formatHint": "matroska",
      ], requireHardwareProbe: false)
      let entered = expectation(description: "decoder recreation entered")
      let factory = StopBarrierFactory(entered: entered)
      let clock = YlMediaClock()
      var events = [[String: Any?]]()
      let backend = try YlFallbackBackend(
        playerId: 20, textureId: 71, textures: StopTextureRegistry(),
        configuration: PlayerConfiguration(map: [:]), prepared: prepared,
        generation: 1, videoSessionFactory: factory, mediaClock: clock,
        emit: { events.append($0) }
      )
      defer { factory.release.signal(); backend.dispose() }
      try backend.activate()
      let coordinator = YlAsyncCommandCoordinator()
      let completed = expectation(description: "cancelled seek completed")
      coordinator.begin(operation: { token in
        try backend.command(name: "seekTo", arguments: ["positionMs": 1000], cancellationToken: token)
      }, completion: { result in
        guard case .failure(let error) = result else { return XCTFail("Seek survived Stop") }
        XCTAssertEqual(error.code, "network.cancelled")
        completed.fulfill()
      })
      wait(for: [entered], timeout: 5)
      events.removeAll()
      if cancelCommand { coordinator.cancelCurrent() }
      backend.stop()
      XCTAssertEqual(events.count, 1)
      factory.release.signal()
      wait(for: [completed], timeout: 5)
      XCTAssertEqual(clock.position(atHostTimeUs: 0), 0, "Cancelled seek must not move the stopped media clock")
      XCTAssertEqual(factory.sessions.count, 2)
      XCTAssertTrue(factory.sessions.allSatisfy { $0.isInvalidated }, "Stop must dispose a decoder candidate completed after teardown")
      XCTAssertEqual(events.count, 1, "Cancelled seek must not publish after the idle snapshot")
      backend.emitState()
      let state = try XCTUnwrap(events.last?["state"] as? [String: Any?])
      XCTAssertEqual(state["status"] as? String, "idle")
      XCTAssertEqual(state["positionMs"] as? Int64, 0)
      XCTAssertFalse(backend.isActive)
    }
  }

  func testStoppedAVRejectsSourceCommandsButAllowsControlsAndFreshOpen() throws {
    var events = [[String: Any?]]()
    let backend = YlAvPlayerBackend(
      playerId: 21, textures: StopTextureRegistry(), configuration: PlayerConfiguration(map: [:]),
      emit: { events.append($0) }
    )
    defer { backend.dispose() }
    backend.stop()
    let stopCount = events.count
    for (name, arguments) in [
      ("seekTo", ["positionMs": 12345] as [String: Any?]),
      ("seekToLiveEdge", [:]), ("selectAudioTrack", ["trackId": "old"]),
      ("play", [:]), ("pause", [:]),
    ] {
      XCTAssertNoThrow(try backend.command(name: name, arguments: arguments))
    }
    XCTAssertEqual(events.count, stopCount)
    backend.emitState()
    XCTAssertEqual((events.last?["state"] as? [String: Any?])?["positionMs"] as? Int64, 0)
    XCTAssertNoThrow(try backend.command(name: "setVolume", arguments: ["volume": 0.25]))
    XCTAssertNoThrow(try backend.command(name: "setPlaybackSpeed", arguments: ["speed": 1.5]))
    try backend.command(name: "open", arguments: ["source": [
      "uri": "https://example.test/fresh.mp4", "kind": "network",
    ]])
    XCTAssertTrue(backend.isActive)
  }

  func testFreshOpenAfterStopReactivatesAudioWithoutLifecycleRevival() throws {
    var activationCount = 0
    let backend = YlAvPlayerBackend(
      playerId: 10, textures: StopTextureRegistry(),
      configuration: PlayerConfiguration(map: [:]),
      activateAudioSession: { activationCount += 1 }, emit: { _ in }
    )
    defer { backend.dispose() }
    try backend.activate()
    XCTAssertEqual(activationCount, 1)
    try backend.command(name: "open", arguments: ["source": [
      "uri": "https://example.test/first.mp4", "kind": "network",
    ]])
    backend.stop()
    try backend.activate()
    XCTAssertEqual(activationCount, 1, "Lifecycle activation must not reacquire audio after Stop")
    XCTAssertFalse(backend.isActive)
    try backend.command(name: "open", arguments: ["source": [
      "uri": "https://example.test/second.mp4", "kind": "network",
    ]])
    XCTAssertEqual(activationCount, 2, "A fresh open must establish audio activation again")
    XCTAssertTrue(backend.isActive)
  }

  func testStopClearsRetainedAVSourceAndFencesQueuedCallbacks() throws {
    let textures = StopTextureRegistry()
    var events = [[String: Any?]]()
    let backend = YlAvPlayerBackend(
      playerId: 8, textures: textures, configuration: PlayerConfiguration(map: [:]),
      emit: { events.append($0) }
    )

    // The platform output registers the same test texture identifier.
    defer { backend.dispose() }
    try backend.command(name: "open", arguments: ["source": [
      "uri": "https://example.test/live.m3u8", "kind": "network", "isLive": true,
    ]])
    let oldGeneration = try XCTUnwrap(events.last?["generation"] as? UInt64)
    backend.deactivate()
    try backend.command(name: "seekTo", arguments: ["positionMs": 12345])
    events.removeAll()
    backend.stop()
    XCTAssertEqual(events.count, 1)
    XCTAssertGreaterThan(try XCTUnwrap(events.last?["generation"] as? UInt64), oldGeneration)
    let state = try XCTUnwrap(events.last?["state"] as? [String: Any?])
    XCTAssertEqual(state["status"] as? String, "idle")
    XCTAssertEqual(state["positionMs"] as? Int64, 0)
    XCTAssertEqual(state["isLive"] as? Bool, false)
    XCTAssertNil(state["videoWidth"] as? Int)
    XCTAssertNil(state["durationMs"] as? Int64)
    XCTAssertEqual((state["videoTracks"] as? [Any])?.count, 0)
    XCTAssertNil((state["metrics"] as? [String: Any?])?["openDurationMs"] as? Int64)
    try backend.activate()
    try backend.command(name: "play", arguments: [:])
    let drained = expectation(description: "queued AV callbacks drained")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { drained.fulfill() }
    wait(for: [drained], timeout: 2)
    XCTAssertEqual(events.count, 1, "Stop must publish one idle state and reject queued callbacks")
    XCTAssertNil(backend.copyPixelBuffer())
    XCTAssertTrue(textures.unregistered.isEmpty)
    events.removeAll()
    backend.clearMediaForStop()
    XCTAssertTrue(events.isEmpty, "Clearing the inactive AV backend must be silent")
    XCTAssertEqual(backend.textureId, 71)
  }





}
