@testable import yl_player_macos
import XCTest
import YlFFmpegBridge

final class YlMacosFallbackTests: XCTestCase {
  func testMacOSAudioUsesNonInterleavedPCMAndCountsEveryChannel() {
    XCTAssertFalse(YlAudioFormatPolicy.usesInterleavedPCM)
    XCTAssertEqual(
      YlAudioFormatPolicy.byteCount(
        frameCount: 100,
        bytesPerFrame: 4,
        channelCount: 2
      ),
      800
    )
  }

  func testBufferBudgetsStayWithinDocumentedCeilings() throws {
    let lowLatency = try YlFallbackBufferBudget.make(
      configuration: PlayerConfiguration(map: ["bufferMode": "lowLatency"])
    )
    XCTAssertEqual(lowLatency.networkBytes, 4 * 1024 * 1024)
    XCTAssertEqual(lowLatency.scheduledAudioBytes, 1 * 1024 * 1024)
    XCTAssertEqual(lowLatency.inFlightPacketBytes, 2 * 1024 * 1024)
  }

  func testQualityConstraintRejectsOversizedFixedVideo() throws {
    let constraint = try YlFallbackQualityConstraint(validating: [
      "maxWidth": 1_920,
      "maxHeight": 1_080,
      "maxBitrate": 8_000_000,
    ])

    XCTAssertThrowsError(try YlFallbackQualityPolicy.validate(
      constraint: constraint,
      stream: YlFallbackVideoDescriptor(
        width: 3_840,
        height: 2_160,
        bitrate: 12_000_000
      )
    )) {
      XCTAssertEqual(
        ($0 as? NativePlayerError)?.code,
        "decoder.quality_constraint_unsupported"
      )
    }
  }

  func testFrameSchedulerDropsLateFramesAndRejectsOldGeneration() {
    let scheduler = YlFrameScheduler()
    scheduler.enqueue(YlFrameEnvelope(
      payload: NSObject(),
      ptsUs: 10_000,
      durationUs: 40_000,
      keyframe: false,
      generation: 1
    ))
    scheduler.enqueue(YlFrameEnvelope(
      payload: NSObject(),
      ptsUs: 20_000,
      durationUs: 40_000,
      keyframe: false,
      generation: 1
    ))

    XCTAssertEqual(scheduler.frame(at: 25_000, generation: 1)?.ptsUs, 20_000)
    XCTAssertEqual(scheduler.lateFrameDropCount, 1)
    scheduler.flush(generation: 2)
    XCTAssertNil(scheduler.frame(at: 30_000, generation: 1))
  }

  func testAudioCatalogExposesAACAndMP3Selection() {
    var aac = YLFStreamInfo()
    aac.index = 3
    aac.kind = Int32(YLFStreamAudio)
    aac.codec = Int32(YLFCodecAAC)
    var mp3 = YLFStreamInfo()
    mp3.index = 4
    mp3.kind = Int32(YLFStreamAudio)
    mp3.codec = Int32(YLFCodecMP3)

    let tracks = YlFallbackTrackCatalog.audioTracks(
      streams: [aac, mp3],
      selectedIndex: mp3.index,
      codecName: { Int($0.codec) == YLFCodecMP3 ? "MP3" : "AAC" }
    )

    XCTAssertEqual(tracks[0]["codec"] as? String, "AAC")
    XCTAssertEqual(tracks[1]["codec"] as? String, "MP3")
    XCTAssertEqual(tracks[1]["isSelected"] as? Bool, true)
  }

  func testFallbackStateDeltaRetainsGenerationEnvelope() {
    let envelope = YlMacosChannel.stateDelta(
      playerId: 9,
      generation: 42,
      delta: ["positionMs": Int64(250)]
    )

    XCTAssertEqual(envelope["protocolVersion"] as? Int, 1)
    XCTAssertEqual(envelope["generation"] as? UInt64, 42)
    XCTAssertEqual(envelope["type"] as? String, "stateDelta")
  }
}
