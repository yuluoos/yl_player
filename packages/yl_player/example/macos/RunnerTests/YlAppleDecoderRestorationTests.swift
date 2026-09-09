import XCTest
import CoreVideo
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
  private func restore(network: Bool) async throws {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("assets/test_media/network_seek_h264_aac.mkv")
    let server = network ? try ReactivationMediaServer(data: Data(contentsOf: path)) : nil
    defer { server?.close() }
    let source: [String: Any?] = ["uri": (server?.url ?? path).absoluteString,
      "kind": network ? "network" : "file", "formatHint": "matroska"]
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
    try original.command(name: "open", arguments: ["source": source])
    try original.command(name: "play", arguments: [:])
    try await AppleHostCharacterizations.waitFor({ !output.frames.isEmpty })
    XCTAssertTrue(errors.isEmpty)
    original.quiesceForReplacement()
    let track = try XCTUnwrap(states.last?.audioTracks.last?.id)
    try original.command(name: "selectAudioTrack", arguments: ["trackId": track])
    try original.command(name: "seekTo", arguments: ["positionMs": Int64(700)])
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
