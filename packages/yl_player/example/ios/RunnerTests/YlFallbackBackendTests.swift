@testable import yl_player_ios
import CoreVideo
import Flutter
import XCTest
import YlFFmpegBridge

private final class FallbackFixtureURLProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var fixtureData = Data()
  private static var capturedRequest: URLRequest?
  private static var capturedRequestCount = 0
  private static var requestObserver: ((Int) -> Void)?

  static func configure(
    data: Data,
    onRequest: ((Int) -> Void)? = nil
  ) -> URLSessionConfiguration {
    lock.lock()
    fixtureData = data
    capturedRequest = nil
    capturedRequestCount = 0
    requestObserver = onRequest
    lock.unlock()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FallbackFixtureURLProtocol.self]
    return configuration
  }

  static var request: URLRequest? {
    lock.lock()
    defer { lock.unlock() }
    return capturedRequest
  }

  static var requestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return capturedRequestCount
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    Self.capturedRequest = request
    Self.capturedRequestCount += 1
    let count = Self.capturedRequestCount
    let observer = Self.requestObserver
    let data = Self.fixtureData
    Self.lock.unlock()
    observer?(count)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "video/x-flv"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

final class YlFallbackBackendTests: XCTestCase {
  private final class FakeTextureRegistry: NSObject, FlutterTextureRegistry {
    func register(_ texture: FlutterTexture) -> Int64 { 1 }
    func textureFrameAvailable(_ textureId: Int64) {}
    func unregisterTexture(_ textureId: Int64) {}
  }

  private final class FakeBackend: YlPlaybackBackend {
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    private(set) var disposeCount = 0
    var activationError: Error?
    var isActive: Bool { activateCount > deactivateCount }

    func activate() throws {
      activateCount += 1
      if let activationError { throw activationError }
    }
    private(set) var stopCount = 0
    func stop() { stopCount += 1 }
    func deactivate() { deactivateCount += 1 }
    func command(name: String, arguments: [String: Any?]) throws {}
    func emitState() {}
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? { nil }
    func dispose() { disposeCount += 1 }
  }

  private struct ExpectedFailure: Error {}

  private final class IrreversibleBackend: YlPlaybackBackend {
    private(set) var active = true
    private(set) var permanentlyClosed = false
    private(set) var quiesceCount = 0
    var isActive: Bool { active }

    func activate() throws {
      if permanentlyClosed { throw ExpectedFailure() }
      active = true
    }
    func deactivate() {
      active = false
      permanentlyClosed = true
    }
    func quiesceForReplacement() {
      active = false
      quiesceCount += 1
    }
    func command(name: String, arguments: [String: Any?]) throws {}
    func emitState() {}
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? { nil }
    func stop() { active = false }
    func dispose() { permanentlyClosed = true }
  }

  func testSlotStopInvalidatesGenerationAndRemainsReplaceable() throws {
    let original = FakeBackend()
    let slot = YlBackendSlot(initial: original)
    let generation = slot.generation
    slot.stop()
    XCTAssertFalse(slot.accepts(generation: generation))
    XCTAssertTrue(slot.current === original)
    XCTAssertEqual(original.stopCount, 1)
    XCTAssertEqual(original.deactivateCount, 0)
    XCTAssertEqual(original.disposeCount, 0)
    let replacement = FakeBackend()
    _ = try slot.replace { replacement }
    XCTAssertTrue(slot.current === replacement)
  }

  func testPreparationFailurePreservesCurrentBackend() throws {
    let original = FakeBackend()
    let slot = YlBackendSlot(initial: original)
    try original.activate()

    XCTAssertThrowsError(try slot.replace { throw ExpectedFailure() })
    XCTAssertTrue(slot.current === original)
    XCTAssertEqual(original.deactivateCount, 0)
  }

  func testReplacementKeepsOnlyOneBackendActive() throws {
    let original = FakeBackend()
    let replacement = FakeBackend()
    let slot = YlBackendSlot(initial: original)
    try original.activate()

    try slot.replace { replacement }
    XCTAssertEqual(original.deactivateCount, 1)
    XCTAssertEqual(replacement.activateCount, 1)
    XCTAssertTrue(slot.current === replacement)
  }

  func testActivationFailureRestoresPreviousBackendAndDisposesCandidate() throws {
    let original = FakeBackend()
    let candidate = FakeBackend()
    candidate.activationError = ExpectedFailure()
    let slot = YlBackendSlot(initial: original)
    try original.activate()

    XCTAssertThrowsError(try slot.replace { candidate })
    XCTAssertTrue(slot.current === original)
    XCTAssertTrue(original.isActive)
    XCTAssertEqual(original.deactivateCount, 1)
    XCTAssertEqual(original.activateCount, 2)
    XCTAssertEqual(candidate.activateCount, 1)
    XCTAssertEqual(candidate.disposeCount, 1)
  }

  func testActivationFailureRestoresBackendWithoutPermanentTeardown() {
    let original = IrreversibleBackend()
    let candidate = FakeBackend()
    candidate.activationError = ExpectedFailure()
    let slot = YlBackendSlot(initial: original)

    XCTAssertThrowsError(try slot.replace { candidate })

    XCTAssertTrue(slot.current === original)
    XCTAssertTrue(original.isActive)
    XCTAssertFalse(original.permanentlyClosed)
    XCTAssertEqual(original.quiesceCount, 1)
  }

  func testGenerationRejectsCallbacksFromReplacedBackend() throws {
    let slot = YlBackendSlot(initial: FakeBackend())
    let oldGeneration = slot.generation
    try slot.replace { FakeBackend() }
    XCTAssertFalse(slot.accepts(generation: oldGeneration))
    XCTAssertTrue(slot.accepts(generation: slot.generation))
  }

  func testDisposeIsIdempotentFromPartialState() {
    let backend = FakeBackend()
    let slot = YlBackendSlot(initial: backend)
    slot.dispose()
    slot.dispose()
    XCTAssertEqual(backend.disposeCount, 1)
  }

  func testRealMkvPreflightEitherPreparesOrReturnsStableHardwareError() throws {
    let fixture = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mkv")
    )
    var prepared: YlPreparedFallback?
    do {
      prepared = try YlPreparedFallback(source: [
        "uri": fixture.absoluteString,
        "kind": "file",
        "formatHint": "matroska",
        "isLive": false,
      ])
    } catch {
      XCTAssertEqual(
        (error as? NativePlayerError)?.code,
        "decoder.video_hardware_unavailable"
      )
    }
    if let prepared {
      XCTAssertGreaterThan(prepared.videoStream.width, 0)
      guard case let .local(path, container) = prepared.sourceRecipe else {
        return XCTFail("Expected local source recipe")
      }
      XCTAssertEqual(path, fixture.path)
      XCTAssertEqual(container, .matroska)
    }
    prepared = nil
    XCTAssertEqual(ylf_debug_outstanding_packet_count(), 0)
  }

  func testNetworkFlvPreparesSequentialMP3Fallback() throws {
    let fixture = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "h264_mp3", withExtension: "flv")
    )
    let session = FallbackFixtureURLProtocol.configure(
      data: try Data(contentsOf: fixture)
    )
    let prepared = try YlPreparedFallback(
      source: [
        "uri": "https://media.test/live.flv",
        "kind": "network",
        "formatHint": "httpFlv",
        "isLive": true,
        "headers": ["Authorization": "Bearer test"],
      ],
      requireHardwareProbe: false,
      sessionConfiguration: session
    )
    defer { prepared.discard() }

    XCTAssertEqual(prepared.container, .flv)
    XCTAssertTrue(prepared.policy.isLive)
    XCTAssertFalse(prepared.isSeekable)
    XCTAssertTrue(prepared.policy.requiresInitialVideoKeyframe)
    XCTAssertNil(prepared.policy.durationMs(mediaDurationUs: prepared.mediaInfo.duration_us))
    XCTAssertEqual(prepared.audioStreams.first?.codec, Int32(YLFCodecMP3))
    XCTAssertTrue(prepared.audioCookies.isEmpty)
    guard case let .network(request, container) = prepared.sourceRecipe else {
      return XCTFail("Expected network FLV recipe")
    }
    XCTAssertEqual(container, .flv)
    XCTAssertEqual(request.mode, .sequentialLive)
    XCTAssertNil(FallbackFixtureURLProtocol.request?
      .value(forHTTPHeaderField: "Range"))
  }

  func testNetworkFlvReconnectsWholePipelineFromByteZeroAfterEOF() throws {
    let fixture = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "flv")
    )
    let secondRequest = expectation(description: "second FLV connection")
    secondRequest.assertForOverFulfill = false
    let session = FallbackFixtureURLProtocol.configure(
      data: try Data(contentsOf: fixture),
      onRequest: { count in
        if count >= 2 { secondRequest.fulfill() }
      }
    )
    let configuration = PlayerConfiguration(map: [
      "bufferMode": "lowLatency",
      "network": [
        "maxRetries": 1,
        "baseRetryDelayMs": 0,
        "maxRetryDelayMs": 0,
      ],
    ])
    let prepared = try YlPreparedFallback(
      source: [
        "uri": "https://media.test/reconnecting.flv",
        "kind": "network",
        "formatHint": "httpFlv",
        "isLive": true,
      ],
      requireHardwareProbe: false,
      configuration: configuration,
      sessionConfiguration: session
    )
    var events = [[String: Any?]]()
    let eventsLock = NSLock()
    let backend: YlFallbackBackend
    do {
      backend = try YlFallbackBackend(
        playerId: 41,
        textureId: -1,
        textures: FakeTextureRegistry(),
        configuration: configuration,
        prepared: prepared,
        generation: 1,
        emit: { event in
          eventsLock.lock()
          events.append(event)
          eventsLock.unlock()
        }
      )
    } catch let error as NativePlayerError
      where error.code == "decoder.video_hardware_unavailable" {
      throw XCTSkip("This simulator runtime does not expose hardware H.264 decoding.")
    }
    defer { backend.dispose() }

    try backend.activate()
    try backend.command(name: "play", arguments: [:])
    wait(for: [secondRequest], timeout: 5)

    XCTAssertGreaterThanOrEqual(FallbackFixtureURLProtocol.requestCount, 2)
    eventsLock.lock()
    let eventSnapshot = events
    eventsLock.unlock()
    XCTAssertTrue(eventSnapshot.contains { $0["type"] as? String == "retry" })
    XCTAssertFalse(eventSnapshot.contains {
      ($0["error"] as? [String: Any?])?["code"] as? String
        == "network.retry_exhausted"
    })
  }

  func testDiscardedPreparedFallbackCannotTransferItsMedia() throws {
    let fixture = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mkv")
    )
    let prepared = try YlPreparedFallback(
      source: [
        "uri": fixture.absoluteString,
        "kind": "file",
        "formatHint": "matroska",
        "isLive": false,
      ],
      requireHardwareProbe: false
    )

    prepared.discard()
    prepared.discard()

    XCTAssertThrowsError(try prepared.takeMedia()) { error in
      XCTAssertEqual(
        (error as? NativePlayerError)?.code,
        "internal.fallback_invariant"
      )
    }
  }

  func testInFlightPacketBudgetRejectsOversizedCompressedPacket() throws {
    let budget = try YlFallbackBufferBudget.make(configuration: PlayerConfiguration(map: [
      "bufferMode": "lowLatency",
    ]))

    XCTAssertNoThrow(try budget.validateInFlightPacket(size: budget.inFlightPacketBytes))
    XCTAssertThrowsError(
      try budget.validateInFlightPacket(size: budget.inFlightPacketBytes + 1)
    ) { error in
      XCTAssertEqual((error as? NativePlayerError)?.category, "resource")
      XCTAssertEqual((error as? NativePlayerError)?.code, "resource.network_buffer_limit")
    }
  }

  func testRejectedQualityConstraintKeepsActiveFallbackUsable() throws {
    let fixture = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mkv")
    )
    let prepared = try YlPreparedFallback(
      source: [
        "uri": fixture.absoluteString,
        "kind": "file",
        "formatHint": "matroska",
        "isLive": false,
      ],
      requireHardwareProbe: false
    )
    let backend: YlFallbackBackend
    do {
      backend = try YlFallbackBackend(
        playerId: 52,
        textureId: -1,
        textures: FakeTextureRegistry(),
        configuration: PlayerConfiguration(map: [:]),
        prepared: prepared,
        generation: 1,
        emit: { _ in }
      )
    } catch let error as NativePlayerError
      where error.code == "decoder.video_hardware_unavailable" {
      throw XCTSkip("This simulator runtime does not expose hardware H.264 decoding.")
    }
    defer { backend.dispose() }

    try backend.activate()
    XCTAssertThrowsError(try backend.command(
      name: "setQualityConstraint",
      arguments: ["constraint": ["maxHeight": 1]]
    )) { error in
      XCTAssertEqual(
        (error as? NativePlayerError)?.code,
        "decoder.quality_constraint_unsupported"
      )
    }

    XCTAssertTrue(backend.isActive)
    XCTAssertNoThrow(try backend.command(name: "pause", arguments: [:]))
    XCTAssertNoThrow(try backend.command(name: "play", arguments: [:]))
    XCTAssertTrue(backend.isActive)
  }

  func testRejectedInitialConstraintDoesNotConsumePreparedMedia() throws {
    let fixture = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mkv")
    )
    let prepared = try YlPreparedFallback(
      source: [
        "uri": fixture.absoluteString,
        "kind": "file",
        "formatHint": "matroska",
        "isLive": false,
      ],
      requireHardwareProbe: false
    )

    XCTAssertThrowsError(try YlFallbackBackend(
      playerId: 53,
      textureId: -1,
      textures: FakeTextureRegistry(),
      configuration: PlayerConfiguration(map: [:]),
      prepared: prepared,
      qualityConstraint: try YlFallbackQualityConstraint(
        validating: ["maxWidth": 1]
      ),
      generation: 1,
      emit: { _ in }
    )) { error in
      XCTAssertEqual(
        (error as? NativePlayerError)?.code,
        "decoder.quality_constraint_unsupported"
      )
    }

    let media = try prepared.takeMedia()
    media.close()
  }

  func testPlayerPersistsSuccessfulQualityConstraint() {
    let player = YlIosPlayer(
      playerId: 54,
      textures: FakeTextureRegistry(),
      configuration: PlayerConfiguration(map: [:]),
      emit: { _ in }
    )
    defer { player.dispose() }
    var commandResult: Result<Void, NativePlayerError>?

    player.beginCommand(
      name: "setQualityConstraint",
      arguments: ["constraint": ["maxHeight": 720]],
      completion: { commandResult = $0 }
    )

    guard case .success? = commandResult else {
      return XCTFail("Expected quality constraint command to succeed")
    }
    XCTAssertEqual(player.lastQualityConstraint["maxHeight"] as? Int, 720)
  }
}
