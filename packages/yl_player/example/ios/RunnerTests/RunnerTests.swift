@testable import yl_player_ios
import Flutter
import UIKit
import XCTest

class RunnerTests: XCTestCase {
  private final class StopTextureRegistry: NSObject, FlutterTextureRegistry {
    var unregistered = [Int64]()
    func register(_ texture: FlutterTexture) -> Int64 { 71 }
    func textureFrameAvailable(_ textureId: Int64) {}
    func unregisterTexture(_ textureId: Int64) { unregistered.append(textureId) }
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
    let player = YlIosPlayer(
      playerId: 7, textures: textures,
      configuration: PlayerConfiguration(map: [:]), emit: { events.append($0) }
    )
    player.textureId = 71
    defer { player.dispose() }
    let cancelled = expectation(description: "pending open cancelled")
    player.beginOpen(
      ["uri": "https://example.test/video.mp4", "kind": "network", "formatHint": "mp4"],
      didCommit: { XCTFail("stopped open committed") },
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
      didCommit: {},
      completion: { result in
        if case .failure(let error) = result { XCTFail("fresh open failed: \(error)") }
        opened.fulfill()
      }
    )
    wait(for: [opened], timeout: 3)
    XCTAssertEqual(player.textureId, 71)
    XCTAssertTrue(textures.unregistered.isEmpty)
  }


  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

}
