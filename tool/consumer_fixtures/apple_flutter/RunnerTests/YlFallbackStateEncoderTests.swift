@testable import yl_player_apple
import XCTest

final class YlFallbackStateEncoderTests: XCTestCase {
  func testErrorEventContainsOnlyPublicErrorEnvelopeFields() {
    let event = YlFallbackErrorEvent(
      playerId: 7,
      error: ["code": "decoder.failed"]
    ).eventMap

    XCTAssertEqual(Set(event.keys), Set(["playerId", "type", "error"]))
    XCTAssertEqual(event["playerId"] as? Int64, 7)
    XCTAssertEqual(event["type"] as? String, "error")
  }

  func testDynamicSnapshotContainsOnlyCompactPositionFields() {
    let snapshot = YlFallbackDynamicSnapshot(
      positionMs: 1_000,
      bufferedPositionMs: 2_500,
      isAtLiveEdge: true,
      liveOffsetMs: nil,
      metrics: ["droppedVideoFrames": 3]
    )

    XCTAssertEqual(
      Set(snapshot.deltaMap.keys),
      Set([
        "positionMs",
        "bufferedPositionMs",
        "isAtLiveEdge",
        "liveOffsetMs",
        "metrics",
      ])
    )
    XCTAssertEqual(snapshot.deltaMap["positionMs"] as? Int64, 1_000)
    XCTAssertEqual(snapshot.deltaMap["bufferedPositionMs"] as? Int64, 2_500)
    XCTAssertEqual(snapshot.deltaMap["isAtLiveEdge"] as? Bool, true)
    XCTAssertNil(snapshot.deltaMap["liveOffsetMs"] ?? nil)
  }

  func testFullSnapshotContainsEveryPublicFallbackStateField() {
    let capabilities: [String: Any] = ["maxConcurrentVideoDecoders": 1]
    let snapshot = YlFallbackStateSnapshot(
      status: "playing",
      positionMs: 1_000,
      durationMs: 10_000,
      bufferedPositionMs: 2_500,
      isLive: false,
      isSeekable: true,
      isAtLiveEdge: false,
      liveOffsetMs: nil,
      dvrStartMs: nil,
      dvrEndMs: nil,
      videoWidth: 1_280,
      videoHeight: 720,
      engine: "nativeFallback",
      isHardwareDecoding: true,
      decoderName: "VideoToolbox",
      audioTracks: [["id": "audio-1"]],
      videoTracks: [["id": "video-0"]],
      capabilities: capabilities,
      metrics: ["bufferedBytes": 4_096],
      error: nil
    )

    XCTAssertEqual(
      Set(snapshot.fullMap.keys),
      Set([
        "status",
        "positionMs",
        "durationMs",
        "bufferedPositionMs",
        "isLive",
        "isSeekable",
        "isAtLiveEdge",
        "liveOffsetMs",
        "dvrStartMs",
        "dvrEndMs",
        "videoWidth",
        "videoHeight",
        "engine",
        "isHardwareDecoding",
        "decoderName",
        "audioTracks",
        "videoTracks",
        "capabilities",
        "metrics",
        "error",
      ])
    )
    XCTAssertEqual(snapshot.fullMap["status"] as? String, "playing")
    XCTAssertEqual(snapshot.fullMap["durationMs"] as? Int64, 10_000)
    XCTAssertEqual(snapshot.fullMap["videoWidth"] as? Int, 1_280)
    XCTAssertEqual(
      (snapshot.fullMap["capabilities"] as? [String: Any])?["maxConcurrentVideoDecoders"] as? Int,
      1
    )
  }
}
