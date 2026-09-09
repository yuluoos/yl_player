@testable import yl_player_apple
import XCTest

final class YlFallbackStateEncoderTests: XCTestCase {
  func testErrorEventContainsOnlyPublicErrorEnvelopeFields() {
    let event = YlNativeBackendEvent.failure(NativePlayerError(
      category: "decoder", code: "decoder.failed", message: "Decoder failed"))
    guard case .failure(let failure) = event else { return XCTFail("Expected typed failure") }
    XCTAssertEqual(failure.category, "decoder")
    XCTAssertEqual(failure.code, "decoder.failed")
    XCTAssertEqual(failure.message, "Decoder failed")
    XCTAssertNil(failure.diagnostic)
  }

  func testDynamicSnapshotContainsOnlyCompactPositionFields() {
    let snapshot = YlNativeTimelineDelta(positionMs: 1000,
      bufferedPositionMs: 2500, isAtLiveEdge: true, liveOffsetMs: nil,
      metrics: YlNativeMetrics(droppedVideoFrames: 3))
    XCTAssertEqual(snapshot.positionMs, 1000)
    XCTAssertEqual(snapshot.bufferedPositionMs, 2500)
    XCTAssertTrue(snapshot.isAtLiveEdge)
    XCTAssertNil(snapshot.liveOffsetMs)
    XCTAssertEqual(snapshot.metrics.droppedVideoFrames, 3)
  }

  func testFullSnapshotContainsEveryPublicFallbackStateField() {
    let snapshot = YlNativeState(status: "playing", positionMs: 1000,
      durationMs: 10000, bufferedPositionMs: 2500, isLive: false,
      isSeekable: true, isAtLiveEdge: false, liveOffsetMs: nil,
      dvrStartMs: nil, dvrEndMs: nil, videoWidth: 1280, videoHeight: 720,
      engine: .managedFallback, isHardwareDecoding: true, decoderName: "VideoToolbox",
      audioTracks: [.init(id: "audio-1", kind: .audio)],
      videoTracks: [.init(id: "video-0", kind: .video)],
      metrics: .init(bufferedBytes: 4096), error: nil)
    XCTAssertEqual(snapshot.status, "playing")
    XCTAssertEqual(snapshot.positionMs, 1000)
    XCTAssertEqual(snapshot.durationMs, 10000)
    XCTAssertEqual(snapshot.bufferedPositionMs, 2500)
    XCTAssertFalse(snapshot.isLive)
    XCTAssertTrue(snapshot.isSeekable)
    XCTAssertFalse(snapshot.isAtLiveEdge)
    XCTAssertNil(snapshot.liveOffsetMs)
    XCTAssertNil(snapshot.dvrStartMs)
    XCTAssertNil(snapshot.dvrEndMs)
    XCTAssertEqual(snapshot.videoWidth, 1280)
    XCTAssertEqual(snapshot.videoHeight, 720)
    XCTAssertEqual(snapshot.engine, .managedFallback)
    XCTAssertTrue(snapshot.isHardwareDecoding)
    XCTAssertEqual(snapshot.decoderName, "VideoToolbox")
    XCTAssertEqual(snapshot.audioTracks.first?.id, "audio-1")
    XCTAssertEqual(snapshot.videoTracks.first?.id, "video-0")
    XCTAssertEqual(snapshot.metrics.bufferedBytes, 4096)
    XCTAssertNil(snapshot.error)
    // Device-wide capabilities now belong to factory/host, not every engine state.
    XCTAssertEqual(YlBackendStateEncoder.deviceCapabilities.maxConcurrentVideoDecoders, 1)
  }
}
