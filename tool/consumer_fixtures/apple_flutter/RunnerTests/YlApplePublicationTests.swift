import XCTest
import AVFoundation
import CoreVideo
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif
@testable import yl_player_apple

final class ApplePublicationRegistry: NSObject, FlutterTextureRegistry {
  var textures: [Int64: FlutterTexture] = [:]
  var registrations = 0
  var unregistered = [Int64]()
  var notifications = 0
  var positivePublicFrames = 0
  func register(_ texture: FlutterTexture) -> Int64 {
    registrations += 1; textures[Int64(registrations)] = texture; return Int64(registrations)
  }
  func unregisterTexture(_ textureId: Int64) { unregistered.append(textureId); textures[textureId] = nil }
  func textureFrameAvailable(_ textureId: Int64) {
    notifications += 1
    if let frame = textures[textureId]?.copyPixelBuffer()?.takeRetainedValue(),
      CVPixelBufferGetWidth(frame) > 0, CVPixelBufferGetHeight(frame) > 0 { positivePublicFrames += 1 }
  }
  func services(audio: @escaping () throws -> Void = {}) -> YlPlatformServices {
    #if os(iOS)
    return YlIosPlatformAdapter.makeServices(textures: self, activateAudioSession: audio)
    #else
    return YlMacosPlatformAdapter.makeServices(textures: self, activateAudioSession: audio)
    #endif
  }
}

/// Observation at the actual engine output dependency, forwarding unchanged.
final class AppleDecodedOutputObservation: YlTextureOutput {
  let target: YlTextureOutput
  var positiveFrames = 0
  var lastFrame: CVPixelBuffer?
  init(_ target: YlTextureOutput) { self.target = target }
  var textureId: Int64 { target.textureId }
  func publish(_ pixelBuffer: CVPixelBuffer?) {
    if let pixelBuffer, CVPixelBufferGetWidth(pixelBuffer) > 0 {
      positiveFrames += 1; lastFrame = pixelBuffer
    }
    target.publish(pixelBuffer)
  }
  func resize(width: Int, height: Int) { target.resize(width: width, height: height) }
  func clear() { target.clear() }
  func dispose() { target.dispose() }
}

@MainActor
final class YlApplePublicationTests: XCTestCase {
  private func server() throws -> RollbackHlsServer {
    func data(_ name: String, _ ext: String) throws -> Data {
      #if os(iOS)
      let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
      #else
      let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("assets/test_media/\(name).\(ext)")
      #endif
      return try Data(contentsOf: url)
    }
    return try RollbackHlsServer(key: data("hls_key", "bin"), segment: data("hls_encrypted_segment0", "ts"))
  }

  func testDecodedPrivateFrameDoesNotConsumeFirstCommittedPublication() async throws {
    let server = try server(); defer { server.close() }
    let registry = ApplePublicationRegistry()
    var audioMutations = 0
    let services = registry.services { audioMutations += 1 }
    let reducer = YlAppleStateReducer(playerId: 91, clock: YlAppleSafeDiagnostics.nowMilliseconds)
    let id = reducer.makeIdentity(loadRequestId: "private-candidate")
    var firstFrames = 0
    reducer.onOutput = { if case .firstFrame = $0 { firstFrames += 1 } }
    let owner = YlAppleTextureOwner(output: services.textureOutput, onFrame: { reducer.publicFrame(identity: $0) })
    let lease = owner.makeLease(identity: id)
    let observed = AppleDecodedOutputObservation(lease)
    let events = YlAppleCommitEmitter(identity: id, emit: { reducer.accept($1, identity: $0) })
    let av = AVPlayer()
    var privateReady = false
    let backend = YlAvPlayerBackend(playerId: 91, services: services.borrowing(observed),
      configuration: PlayerConfiguration(map: ["audioPolicy": "appManaged"]), player: av, emit: { callback in
        if case .state(let state) = callback.event, state.metrics.openDurationMs != nil { privateReady = true }
        events.accept(callback)
      })
    defer { backend.dispose(); owner.dispose() }
    let source: [String: Any?] = ["uri": server.url.absoluteString, "kind": "network", "formatHint": "hls",
      "credentials": ["Authorization": "Bearer rollback-test"], "loadRequestId": id.loadRequestId,
      "loadOptions": ["autoplay": true]]
    let prepared = try YlPreparedHlsAsset(originURL: server.url, headers: [:],
      credentials: ["Authorization": "Bearer rollback-test"],
      configuration: PlayerConfiguration(map: [:]).network, cancellationToken: YlOpenCancellationToken())
    try backend.stagePreparedHls(source: source, prepared: prepared, resume: false)
    try backend.activate()
    // Decoded output and AV readiness are independent asynchronous observations.
    // Require both before testing the committed publication transition.
    try await AppleHostCharacterizations.waitFor({
      observed.positiveFrames > 0 && privateReady && av.currentItem?.status == .readyToPlay
    }, timeout: 10)
    let decoded = try XCTUnwrap(observed.lastFrame, "Real encrypted HLS must produce a decoded pixel buffer")
    XCTAssertGreaterThan(CVPixelBufferGetWidth(decoded), 0)
    XCTAssertEqual(av.currentItem?.status, .readyToPlay)
    XCTAssertEqual(registry.notifications, 0)
    XCTAssertEqual(registry.positivePublicFrames, 0)
    XCTAssertEqual(firstFrames, 0)
    reducer.commit(id); events.commit(); owner.commit(lease)
    XCTAssertGreaterThan(registry.positivePublicFrames, 0)
    XCTAssertEqual(firstFrames, 1)
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(firstFrames, 1)
    XCTAssertEqual(audioMutations, 0)
    XCTAssertTrue(server.requests.contains { $0.path == "/segment0.ts" && $0.authorized })
    let next = owner.makeLease(identity: .init(sessionId: "next", loadRequestId: "next"))
    next.publish(decoded); owner.commit(next)
    backend.deactivate(); backend.dispose()
    XCTAssertNotNil(registry.textures[services.textureOutput.textureId]?.copyPixelBuffer()?.takeRetainedValue())
    XCTAssertTrue(registry.unregistered.isEmpty)
    owner.dispose()
    XCTAssertEqual(registry.registrations, 1)
    XCTAssertEqual(registry.unregistered.count, 1)
  }

  func testActualHostEmitsFirstFrameOnlyAfterPositivePublicTextureSubmission() async throws {
    let server = try server(); defer { server.close() }
    let registry = ApplePublicationRegistry()
    let callbacks = AppleRecordingCallbacks()
    let host = YlApplePlayerHost(playerId: 92, suffix: "publication-92",
      options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 100),
      services: registry.services(), callbacks: callbacks)
    defer { host.close() }
    try host.attach()
    var request = AppleHostFixture.request("public", url: server.url.absoluteString, format: .hls, autoplay: true)
    request.source.request = .init(headers: [:], credentials: ["Authorization": "Bearer rollback-test"])
    let loaded = try await host.load(request: request)
    try await AppleHostCharacterizations.waitFor({ !callbacks.frames.isEmpty }, timeout: 10)
    XCTAssertGreaterThan(registry.positivePublicFrames, 0)
    XCTAssertEqual(callbacks.frames.count, 1)
    XCTAssertEqual(callbacks.frames.first?.sessionId, loaded.sessionId)
    XCTAssertEqual(callbacks.states.last?.decoderMode, .unknown)
    XCTAssertTrue(callbacks.states.contains { $0.status == .ready || $0.metrics.loadToReadyMs != nil })
    let frameSequence = try XCTUnwrap(callbacks.frames.first?.sequence)
    XCTAssertTrue(callbacks.states.contains { $0.sequence < frameSequence && $0.metrics.loadToFirstFrameMs != nil })
    host.suspend(); host.resume()
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(host.sessionId, loaded.sessionId)
    XCTAssertEqual(callbacks.frames.count, 1)
    try await host.stop()
    XCTAssertNil(registry.textures.values.first?.copyPixelBuffer()?.takeRetainedValue())
    XCTAssertTrue(registry.unregistered.isEmpty)
    host.close(); host.close()
    XCTAssertEqual(registry.registrations, 1)
    XCTAssertEqual(registry.unregistered.count, 1)
  }
  func testFailedCandidateRetainsActiveHlsSessionAndRestoresPublicProjection() async throws {
    let server = try server(); defer { server.close() }
    let registry = ApplePublicationRegistry()
    let callbacks = AppleRecordingCallbacks()
    let av = AVPlayer()
    let host = YlApplePlayerHost(playerId: 93, suffix: "rollback-93",
      options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 100),
      services: registry.services(), callbacks: callbacks, avPlayer: av)
    defer { host.close() }
    try host.attach()
    var request = AppleHostFixture.request("accepted", url: server.url.absoluteString, format: .hls, autoplay: true)
    request.source.request = .init(headers: [:], credentials: ["Authorization": "Bearer rollback-test"])
    let accepted = try await host.load(request: request)
    try await AppleHostCharacterizations.waitFor({ !callbacks.frames.isEmpty }, timeout: 10)
    let item = try XCTUnwrap(av.currentItem)
    let rejected = try ReactivationMediaServer(data: AppleHostCharacterizations.fixtureMedia())
    defer { rejected.close() }
    do {
      _ = try await host.load(request: AppleHostFixture.request("rejected", url: rejected.url.absoluteString,
        format: .matroska, width: 1))
      XCTFail("Impossible fixed-stream constraint committed")
    } catch let error as PigeonError {
      XCTAssertEqual(error.code, "decoder.quality_constraint_unsupported")
    }
    XCTAssertEqual(host.sessionId, accepted.sessionId)
    #if os(iOS)
    XCTAssertTrue(av.currentItem === item, "iOS must keep the actual retained AV/HLS item on rollback")
    #else
    _ = item
    #endif
    try await AppleHostCharacterizations.waitFor({ host.isActive && host.playbackIntent }, timeout: 10)
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(host.initialState.sessionId, accepted.sessionId)
    XCTAssertNotEqual(host.initialState.status, .failed)
    XCTAssertNotNil(host.initialState.metrics.loadToReadyMs)
    XCTAssertNotNil(host.initialState.metrics.loadToFirstFrameMs)
    XCTAssertEqual(callbacks.frames.count, 1)
    XCTAssertEqual(registry.registrations, 1)
    XCTAssertTrue(registry.unregistered.isEmpty)
  }

  func testHeldDisplayCallbackCannotAcquireNewBindingOrReviveStoppedOutput() async throws {
    let server = try server(); defer { server.close() }
    let registry = ApplePublicationRegistry()
    let base = registry.services()
    var ticks = [() -> Void]()
    let services = YlPlatformServices(platform: .current, textureOutput: base.textureOutput,
      makeDisplayDriver: { ticks.append($0); return AppleTestDisplay() }, activateAudioSession: {})
    var oldEvents = [YlNativeBackendCallback]()
    var currentEvents = [YlNativeBackendCallback]()
    let av = AVPlayer()
    let backend = YlAvPlayerBackend(playerId: 94, services: services,
      configuration: PlayerConfiguration(map: ["audioPolicy": "appManaged"]), player: av,
      emit: { oldEvents.append($0) })
    defer { backend.dispose(); base.textureOutput.dispose() }
    let source: [String: Any?] = ["uri": server.url.absoluteString, "kind": "network", "formatHint": "hls",
      "credentials": ["Authorization": "Bearer rollback-test"], "loadRequestId": "captured",
      "loadOptions": ["autoplay": true]]
    let prepared = try YlPreparedHlsAsset(originURL: server.url, headers: [:],
      credentials: ["Authorization": "Bearer rollback-test"],
      configuration: PlayerConfiguration(map: [:]).network, cancellationToken: YlOpenCancellationToken())
    try backend.stagePreparedHls(source: source, prepared: prepared, resume: false)
    try backend.activate()
    try await AppleHostCharacterizations.waitFor({ av.currentItem?.status == .readyToPlay && av.rate > 0 }, timeout: 10)
    try await Task.sleep(nanoseconds: 100_000_000)
    let oldTick = try XCTUnwrap(ticks.last)
    backend.bindCallbacks { currentEvents.append($0) }
    let before = registry.notifications
    oldTick()
    XCTAssertEqual(registry.notifications, before, "Held old callback must not borrow the new binding")
    let newTick = try XCTUnwrap(ticks.last)
    newTick()
    XCTAssertGreaterThan(registry.positivePublicFrames, 0, "A real decoded frame must be available to the new binding")
    let oldCount = oldEvents.count
    try backend.command(name: "stop", arguments: [:])
    let count = currentEvents.count
    let published = registry.notifications
    oldTick(); newTick()
    XCTAssertEqual(oldEvents.count, oldCount)
    XCTAssertEqual(currentEvents.count, count)
    XCTAssertEqual(registry.notifications, published)
    XCTAssertNil(registry.textures.values.first?.copyPixelBuffer()?.takeRetainedValue())
  }

}
