@testable import yl_player_media_core
import XCTest
import CoreVideo
import CoreMedia
@testable import yl_player_apple

/// R22: the direct engine comparison excludes the typed host from the decoded
/// output proof. Both branches resume at the accepted seek after VT retirement.
@MainActor
final class YlAppleDecoderRestorationTests: XCTestCase {
  func testLocalQuiescenceRebuildSeeksBeforePublishingDecodedOutput() async throws {
    try await restore(network: false)
  }
  func testNetworkQuiescenceUsesReprepareBeforePublishingDecodedOutput() async throws {
    try await restore(network: true)
  }
  func testActiveNetworkSeekDoesNotRequestCompetingReactivationWhileDecoderIsRecreated() async throws {
    let server = try ReactivationMediaServer(data: AppleHostCharacterizations.fixtureMedia())
    defer { server.close() }
    let source = YlAppleSourceDescriptor(uri: server.url.absoluteString, kind: .network, formatHint: .matroska)
    let configuration = PlayerConfiguration(map: ["audioPolicy": "appManaged"])
    let prepared = try YlPreparedFallback(source: source, requireHardwareProbe: false, configuration: configuration)
    let entered = expectation(description: "seek retired old VT session before creating replacement")
    let finished = expectation(description: "seek completed")
    let factory = HeldSeekVideoFactory(onHeld: { entered.fulfill() })
    defer { factory.release.signal() }
    let output = AppleTestTexture()
    let services = YlPlatformServices(platform: .macos, textureOutput: output,
      makeDisplayDriver: { AppleClockDisplay(onTick: $0) })
    let backend = try YlFallbackBackend(playerId: 101, services: services, configuration: configuration,
      prepared: prepared, generation: YlBackendGeneration.next(), videoSessionFactory: factory, emit: { _ in })
    defer { backend.dispose() }
    try backend.activate()
    let token = YlOpenCancellationToken()
    DispatchQueue.global().async {
      defer { finished.fulfill() }
      do { try backend.seek(toMs: 0, cancellationToken: token) }
      catch { XCTFail("Actual network seek failed: \(error)") }
    }
    await fulfillment(of: [entered], timeout: 5)
    XCTAssertTrue(backend.isActive)
    XCTAssertFalse(backend.requiresAsyncActivation,
      "An active seek owns decoder recreation; play must not start a competing network reprepare")
    factory.release.signal()
    await fulfillment(of: [finished], timeout: 5)
    try backend.play()
    try await AppleHostCharacterizations.waitFor({ !output.frames.isEmpty })
    XCTAssertFalse(backend.requiresAsyncActivation)
  }

  private func restore(network: Bool) async throws {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("assets/test_media/network_seek_h264_aac.mkv")
    let server = network ? try ReactivationMediaServer(data: Data(contentsOf: path)) : nil
    defer { server?.close() }
    let source = YlAppleSourceDescriptor(uri: (server?.url ?? path).absoluteString, kind: network ? .network : .file, formatHint: .matroska)
    let configuration = PlayerConfiguration(map: ["audioPolicy": "appManaged"])
    let prepared = try YlPreparedFallback(source: source, requireHardwareProbe: false, configuration: configuration)
    var errors = [NativePlayerError]()
    var states = [YlNativeState]()
    let output = AppleTestTexture()
    let services = YlPlatformServices(platform: .macos, textureOutput: output,
      makeDisplayDriver: { AppleClockDisplay(onTick: $0) })
    func backend(_ prepared: YlPreparedFallback) throws -> YlFallbackBackend {
      try YlFallbackBackend(playerId: 99, services: services, configuration: configuration,
        prepared: prepared, generation: YlBackendGeneration.next(), emit: { callback in
          if case .failure(let error) = callback.event { errors.append(error) }
          if case .state(let state) = callback.event { states.append(state) }
        })
    }
    let original = try backend(prepared)
    defer { original.dispose() }
    try original.activate()
    original.emitState()
    try original.play()
    try await AppleHostCharacterizations.waitFor({ !output.frames.isEmpty })
    XCTAssertTrue(errors.isEmpty)
    original.quiesceForReplacement()
    let track = try XCTUnwrap(states.last?.audioTracks.last?.id)
    try original.selectAudioTrack(track, cancellationToken: nil)
    try original.seek(toMs: Int64(700), cancellationToken: nil)
    XCTAssertEqual(original.requiresAsyncActivation, network)
    let frameCount = output.frames.count
    var replacement: YlFallbackBackend?
    defer { replacement?.dispose() }
    if original.requiresAsyncActivation {
      let preparedAgain = try YlPreparedFallback(source: source, requireHardwareProbe: false, configuration: configuration)
      try preparedAgain.prepareForReactivation(original.reactivationState(forcePlay: false))
      let resumed = try backend(preparedAgain)
      replacement = resumed
      try resumed.activate()
    } else {
      try original.activate()
    }
    try await AppleHostCharacterizations.waitFor({ output.frames.count > frameCount || !errors.isEmpty })
    XCTAssertTrue(errors.isEmpty, "Retired decoder must not resume from retained arbitrary demux packets")
    XCTAssertGreaterThan(output.frames.count, frameCount)
    let frame = try XCTUnwrap(output.frames.last)
    XCTAssertGreaterThan(CVPixelBufferGetWidth(frame), 0)
    XCTAssertGreaterThan(CVPixelBufferGetHeight(frame), 0)
    XCTAssertGreaterThanOrEqual(states.last?.positionMs ?? 0, 650)
    XCTAssertEqual(states.last?.audioTracks.first { $0.isSelected }?.id, track)
  }
}

private final class HeldSeekVideoFactory: YlVTSessionFactory {
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var calls = 0
  private let onHeld: () -> Void
  init(onHeld: @escaping () -> Void) { self.onHeld = onHeld }
  func makeSession(formatDescription: CMVideoFormatDescription,
                   output: @escaping (YlVTDecodedImage) -> Void) throws -> YlVTSession {
    lock.lock(); calls += 1; let hold = calls == 2; lock.unlock()
    if hold { onHeld(); _ = release.wait(timeout: .now() + 10) }
    return try YlHardwareVTSessionFactory().makeSession(formatDescription: formatDescription, output: output)
  }
}
