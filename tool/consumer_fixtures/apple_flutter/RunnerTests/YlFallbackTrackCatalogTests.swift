@testable import yl_player_apple
import XCTest
import YlFFmpegBridge

final class YlFallbackTrackCatalogTests: XCTestCase {
  func testVideoTrackUsesStableIdAndCanonicalMimeCodec() {
    var stream = YLFStreamInfo()
    stream.index = 2
    stream.kind = Int32(YLFStreamVideo)
    stream.codec = Int32(YLFCodecH264)
    stream.width = 1_280
    stream.height = 720

    let track = YlFallbackTrackCatalog.videoTrack(
      stream: stream,
      codecName: "h264",
      bitrate: nil
    )

    XCTAssertEqual(track["id"] as? String, "video-2")
    XCTAssertEqual(track["kind"] as? String, "video")
    XCTAssertEqual(track["codec"] as? String, "video/avc")
    XCTAssertEqual(track["width"] as? Int, 1_280)
    XCTAssertEqual(track["height"] as? Int, 720)
    XCTAssertNil(track["bitrate"] ?? nil)
    XCTAssertEqual(track["isSelected"] as? Bool, true)
  }

  func testAudioTracksExposeCodecLabelsAndSelection() {
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
      codecName: { stream in
        Int(stream.codec) == YLFCodecMP3 ? "MP3" : "AAC"
      }
    )

    XCTAssertEqual(tracks[0]["id"] as? String, "audio-3")
    XCTAssertEqual(tracks[0]["codec"] as? String, "AAC")
    XCTAssertEqual(tracks[0]["label"] as? String, "AAC 3")
    XCTAssertEqual(tracks[0]["isSelected"] as? Bool, false)
    XCTAssertEqual(tracks[1]["id"] as? String, "audio-4")
    XCTAssertEqual(tracks[1]["codec"] as? String, "MP3")
    XCTAssertEqual(tracks[1]["label"] as? String, "MP3 4")
    XCTAssertEqual(tracks[1]["isSelected"] as? Bool, true)
  }

  func testVideoTrackMapsHevcAliasToCanonicalMimeCodec() {
    var stream = YLFStreamInfo()
    stream.index = 5
    stream.codec = Int32(YLFCodecHEVC)

    XCTAssertEqual(
      YlFallbackTrackCatalog.videoTrack(
        stream: stream,
        codecName: "hevc",
        bitrate: 4_000_000
      )["codec"] as? String,
      "video/hevc"
    )
  }
}
