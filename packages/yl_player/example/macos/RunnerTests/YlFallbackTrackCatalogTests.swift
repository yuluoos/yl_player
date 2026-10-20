@testable import yl_player_media_core
@testable import yl_player_apple
import XCTest
import YlFFmpegBridge

final class YlFallbackTrackCatalogTests: XCTestCase {
  func testDolbyAudioConfigurationPreservesCodecAndSpeakersAcrossReconnect() {
    let pipeline = YlAudioPipeline(bufferBudget: YlFallbackBufferBudget(
      networkBytes: 1000, scheduledAudioBytes: 100_000, inFlightPacketBytes: 1000),
      lock: NSLock(), generation: 1)
    for (native, codec, label) in [(YLFCodecAC3, YlAudioCodec.ac3, "AC-3"),
                                  (YLFCodecEAC3, YlAudioCodec.eac3, "E-AC-3")] {
      var stream = YLFStreamInfo()
      stream.index = 1; stream.kind = Int32(YLFStreamAudio); stream.codec = Int32(native)
      stream.sample_rate = 48_000; stream.channel_count = 6; stream.channel_layout_mask = 0x60f
      for configuration in [pipeline.configuration(for: stream, generation: 2, audioCookies: [:]),
                            pipeline.reconnectConfiguration(for: stream, generation: 2, copiedAudioCookies: [:])] {
        XCTAssertEqual(configuration.codec, codec)
        XCTAssertEqual(configuration.channelMask, 0x60f)
        XCTAssertEqual(configuration.channelCount, 6)
        XCTAssertEqual(configuration.sampleRate, 48_000)
      }
      let tracks = YlFallbackTrackCatalog.audioTracks(streams: [stream], selectedIndex: 1,
        codecName: pipeline.codecName)
      XCTAssertEqual(tracks.first?.codec, label)
    }
  }

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

    XCTAssertEqual(track.id, "video-2")
    XCTAssertEqual(track.kind, .video)
    XCTAssertEqual(track.codec, "video/avc")
    XCTAssertEqual(track.width, 1_280)
    XCTAssertEqual(track.height, 720)
    XCTAssertNil(track.bitrate)
    XCTAssertEqual(track.isSelected, true)
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

    XCTAssertEqual(tracks[0].id, "audio-3")
    XCTAssertEqual(tracks[0].codec, "AAC")
    XCTAssertEqual(tracks[0].label, "AAC 3")
    XCTAssertEqual(tracks[0].isSelected, false)
    XCTAssertEqual(tracks[1].id, "audio-4")
    XCTAssertEqual(tracks[1].codec, "MP3")
    XCTAssertEqual(tracks[1].label, "MP3 4")
    XCTAssertEqual(tracks[1].isSelected, true)
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
      ).codec,
      "video/hevc"
    )
  }
}
