import CoreMedia
import Cocoa
import FlutterMacOS
import XCTest
@testable import yl_player_macos

class RunnerTests: XCTestCase {
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
    func decode(_ sample: CMSampleBuffer, generation: UInt64, reservation: YlVideoDecodeReservation) -> OSStatus {
      reservation.release()
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

  func testStopOfFallbackSlotClearsStaticMetadataAndCannotReactivate() throws {
    for startsActive in [false, true] {
      let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("assets/test_media/h264_aac.mkv")
      let prepared = try YlPreparedFallback(source: [
        "uri": fixture.absoluteString, "kind": "file", "formatHint": "matroska",
      ], requireHardwareProbe: false)
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
    backend.textureId = 71
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

  func testStopCancelsPendingOpenRetainsTextureAndAllowsFreshOpen() throws {
    let textures = StopTextureRegistry()
    var events = [[String: Any?]]()
    let player = YlMacosPlayer(
      playerId: 7, textures: textures,
      configuration: PlayerConfiguration(map: [:]), emit: { events.append($0) }
    )
    player.textureId = 71
    defer { player.dispose() }
    let cancelled = expectation(description: "pending open cancelled")
    player.beginOpen(
      ["uri": "https://example.test/video.mp4", "kind": "network", "formatHint": "mp4"],
      willCommit: { _ in XCTFail("stopped open committed") }, didCommit: {}, didRollback: {},
      completion: { result in
        guard case .failure = result else { return XCTFail("open was not cancelled") }
        cancelled.fulfill()
      }
    )
    events.removeAll()
    var stopped = false
    player.beginCommand(name: "stop", arguments: [:]) { result in
      if case .success = result { stopped = true }
    }
    XCTAssertTrue(stopped)
    XCTAssertEqual(events.count, 1)
    let state = try XCTUnwrap(events.last?["state"] as? [String: Any?])
    XCTAssertEqual(state["status"] as? String, "idle")
    XCTAssertEqual(state["positionMs"] as? Int64, 0)
    XCTAssertEqual((state["audioTracks"] as? [Any])?.count, 0)
    XCTAssertNil(state["error"] as? [String: Any?])
    XCTAssertNil(player.copyPixelBuffer())
    XCTAssertEqual(player.textureId, 71)
    XCTAssertTrue(textures.unregistered.isEmpty)
    wait(for: [cancelled], timeout: 3)
    try player.activate()
    player.emitState()
    XCTAssertEqual((events.last?["state"] as? [String: Any?])?["status"] as? String, "idle")
    let opened = expectation(description: "fresh open")
    player.beginOpen(
      ["uri": "https://example.test/fresh.mp4", "kind": "network", "formatHint": "mp4"],
      willCommit: { _ in }, didCommit: {}, didRollback: {},
      completion: { result in
        if case .failure(let error) = result { XCTFail("fresh open failed: \(error)") }
        opened.fulfill()
      }
    )
    wait(for: [opened], timeout: 3)
    XCTAssertEqual(player.textureId, 71)
    XCTAssertTrue(textures.unregistered.isEmpty)
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

  func testCapabilitiesUseCanonicalCodecIdentifiers() {
    let capabilities = YlMacosChannel.capabilities(
      hardwareH264: true,
      hardwareHevc: true
    )

    XCTAssertEqual(
      capabilities["hardwareVideoCodecs"] as? [String],
      ["video/avc", "video/hevc"]
    )
    XCTAssertEqual(
      Set(capabilities["supportedFormats"] as? [String] ?? []),
      Set(["automatic", "hls", "httpFlv", "mp4", "mov", "matroska", "flv"])
    )
    XCTAssertEqual(capabilities["maxConcurrentVideoDecoders"] as? Int, 1)
  }

  func testChannelGenerationsAreStrictlyIncreasing() {
    let first = YlMacosChannelGeneration.next()
    let second = YlMacosChannelGeneration.next()

    XCTAssertGreaterThan(second, first)
  }

  func testStateEnvelopeUsesVersionedGeneration() {
    let envelope = YlMacosChannel.fullState(
      playerId: 7,
      generation: 9,
      state: ["status": "ready"]
    )

    XCTAssertEqual(envelope["playerId"] as? Int64, 7)
    XCTAssertEqual(envelope["protocolVersion"] as? Int, 1)
    XCTAssertEqual(envelope["generation"] as? UInt64, 9)
    XCTAssertEqual(envelope["type"] as? String, "state")
  }

  func testPluginChannelNamesMatchTheDartAdapter() {
    XCTAssertEqual(
      YlPlayerMacosPlugin.methodChannelName,
      "dev.ylplayer.yl_player_macos/methods"
    )
    XCTAssertEqual(
      YlPlayerMacosPlugin.eventChannelName,
      "dev.ylplayer.yl_player_macos/events"
    )
  }
}
