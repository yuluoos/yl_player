import CoreMedia
import Cocoa
import FlutterMacOS
import XCTest
@testable import yl_player_apple

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
    let low = legacy.forLoad(.init(uri: "file:///tmp/media", kind: .file, loadOptions: .init(bufferStrategy: .lowLatency)))
    XCTAssertEqual(low.bufferMode, "lowLatency")
    XCTAssertEqual(low.preferredForwardBufferDuration, 2)
    XCTAssertFalse(low.managesAudioSession)
    XCTAssertEqual(legacy.forLoad(.init(uri: "file:///tmp/media", kind: .file, loadOptions: .init(bufferStrategy: .smoothPlayback))).preferredForwardBufferDuration, 30)
    XCTAssertEqual(legacy.forLoad(.init(uri: "file:///tmp/media", kind: .file, loadOptions: .init())).preferredForwardBufferDuration, 10)
    XCTAssertEqual(legacy.forLoad(.init(uri: "file:///tmp/media", kind: .file)).preferredForwardBufferDuration, 30)
    XCTAssertEqual(legacy.bufferMode, "stable")
  }



  func testPreparingRetriesDoNotPolluteOldSessionAndCommittedRetriesRetainIdentity() {
    var identities = [YlAppleSessionIdentity]()
    let oldId = YlAppleSessionIdentity(sessionId: "old", loadRequestId: "request-3")
    let newId = YlAppleSessionIdentity(sessionId: "new", loadRequestId: "request-4")
    let retry = YlNativeBackendCallback(generation: 1, event: .retry(attempt: 1,
      delayMs: 400, error: NativePlayerError(category: "network", code: "network.retry", message: "Retry")))
    let old = YlAppleCommitEmitter(identity: oldId, emit: { id, _ in identities.append(id) })
    old.commit()
    old.accept(retry)
    let candidate = YlAppleCommitEmitter(identity: newId, emit: { id, _ in identities.append(id) })
    candidate.accept(retry)
    XCTAssertEqual(identities.count, 1)
    XCTAssertEqual(identities.last, oldId)
    candidate.commit()
    old.invalidate()
    old.accept(retry)
    candidate.accept(retry)
    XCTAssertEqual(identities.count, 2)
    XCTAssertEqual(identities.last, newId)
  }

  func testPrivateCandidateEventsPublishOnlyAfterCommit() {
    var identities = [YlAppleSessionIdentity]()
    let id = YlAppleSessionIdentity(sessionId: "candidate", loadRequestId: "request-9")
    let candidate = YlAppleCommitEmitter(identity: id, emit: { identity, _ in identities.append(identity) })
    candidate.accept(YlNativeBackendCallback(generation: 1, event: .state(.characterizationReady)))
    candidate.accept(YlNativeBackendCallback(generation: 1, event: .firstFrame(width: 320, height: 180)))
    XCTAssertTrue(identities.isEmpty)
    candidate.commit()
    XCTAssertEqual(identities.count, 1)
    XCTAssertEqual(identities.first?.loadRequestId, "request-9")
    candidate.accept(YlNativeBackendCallback(generation: 1, event: .firstFrame(width: 320, height: 180)))
    XCTAssertEqual(identities.count, 2)
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
    func decode(_ sample: CMSampleBuffer, generation: UInt64, reservation: YlVideoDecodeReservation?) -> OSStatus {
      reservation?.release()
      return noErr
    }
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
      let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("assets/test_media/h264_aac.mkv")
      let prepared = try YlPreparedFallback(source: YlAppleSourceDescriptor(uri: fixture.absoluteString, kind: .file, formatHint: .matroska), requireHardwareProbe: false)
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
        try backend.seek(toMs: 1000, cancellationToken: token)
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
    for command: YlApplePlaybackCommand in [
      .seek(12345), .liveEdge, .track("old"), .play, .pause,
    ] {
      XCTAssertNoThrow(try command.apply(to: backend))
    }
    XCTAssertEqual(events.count, stopCount)
    backend.emitState()
    XCTAssertEqual((events.last?["state"] as? [String: Any?])?["positionMs"] as? Int64, 0)
    XCTAssertNoThrow(try backend.setVolume(0.25))
    XCTAssertNoThrow(try backend.setPlaybackSpeed(1.5))
    try backend.open(YlAppleSourceDescriptor(uri: "https://example.test/fresh.mp4", kind: .network))
    XCTAssertTrue(backend.isActive)
  }

  func testStopOfFallbackSlotClearsStaticMetadataAndCannotReactivate() throws {
    for startsActive in [false, true] {
      let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("assets/test_media/h264_aac.mkv")
      let prepared = try YlPreparedFallback(source: YlAppleSourceDescriptor(uri: fixture.absoluteString, kind: .file, formatHint: .matroska), requireHardwareProbe: false)
      let textures = StopTextureRegistry()
      var events = [[String: Any?]]()
      let backend = try YlFallbackBackend(
        playerId: 9, textureId: 71, textures: textures,
        configuration: PlayerConfiguration(map: [:]), prepared: prepared,
        generation: 1, emit: { events.append($0) }
      )
      let slot = YlBackendSlot(initial: backend)
      defer { slot.dispose() }
      if startsActive { try backend.activate() }
      backend.emitState()
      let previousGeneration = try XCTUnwrap(events.last?["generation"] as? UInt64)
      events.removeAll()
      slot.stop()
      XCTAssertEqual(events.count, 1)
      let state = try XCTUnwrap(events.last?["state"] as? [String: Any?])
      XCTAssertGreaterThan(try XCTUnwrap(events.last?["generation"] as? UInt64), previousGeneration)
      XCTAssertEqual(state["status"] as? String, "idle")
      XCTAssertNil(state["videoWidth"] as? Int)
      XCTAssertNil(state["durationMs"] as? Int64)
      XCTAssertEqual((state["audioTracks"] as? [Any])?.count, 0)
      XCTAssertEqual((state["videoTracks"] as? [Any])?.count, 0)
      XCTAssertEqual(state["isHardwareDecoding"] as? Bool, false)
      XCTAssertNil(backend.copyPixelBuffer())
      XCTAssertEqual(backend.textureId, 71)
      try backend.activate()
      XCTAssertFalse(backend.isActive)
      XCTAssertEqual(events.count, 1, "Activation must not reopen stopped fallback media")
      XCTAssertTrue(textures.unregistered.isEmpty)
    }
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
    try backend.open(YlAppleSourceDescriptor(uri: "https://example.test/live.m3u8", kind: .network, intent: .live))
    let oldGeneration = try XCTUnwrap(events.last?["generation"] as? UInt64)
    backend.deactivate()
    try backend.seek(toMs: 12345, cancellationToken: nil)
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
    try backend.play()
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




  func testConfigurationDefaultsToHardwareOnly() {
    let configuration = PlayerConfiguration(map: [:])

    XCTAssertEqual(configuration.decoderPolicy, "hardwareOnly")
    XCTAssertEqual(configuration.bufferMode, "automatic")
  }

  func testLifecycleTerminationDisposesAllPlayers() {
    XCTAssertEqual(
      YlMacosLifecyclePolicy.action(for: .willTerminate),
      .disposeAll
    )
  }

  func testLifecycleResignActivePreservesPlayback() {
    XCTAssertEqual(
      YlMacosLifecyclePolicy.action(for: .didResignActive),
      .preserve
    )
  }








}
