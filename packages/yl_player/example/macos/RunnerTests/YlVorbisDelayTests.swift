@testable import yl_player_media_core
@testable import yl_player_apple
import AVFoundation
import XCTest
import YlFFmpegBridge

final class YlVorbisDelayTests: XCTestCase {
  // Decode real packets, with synthetic presentation timestamps only. This
  // isolates PCM trimming from Matroska's already-subtracted CodecDelay.
  private func decode(target: Int64?) throws -> [YlScheduledAudioBuffer] {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "vorbis_switch", withExtension: "mkv"))
    var context: YLFMediaContextRef?; var info = YLFMediaInfo()
    XCTAssertEqual(ylf_open_local(url.path, &context, &info), 0)
    defer { ylf_close(&context) }
    let opened = try XCTUnwrap(context)
    var vorbis: YLFStreamInfo?
    for index in 0..<info.stream_count {
      var stream = YLFStreamInfo()
      XCTAssertEqual(ylf_copy_stream_info(opened, index, &stream), 0)
      if Int(stream.codec) == YLFCodecVorbis { vorbis = stream; break }
    }
    let stream = try XCTUnwrap(vorbis)
    var cookie = Data(count: ylf_stream_codec_config_size(opened, stream.index))
    let size = cookie.count
    XCTAssertEqual(cookie.withUnsafeMutableBytes {
      ylf_copy_stream_codec_config(opened, stream.index, $0.bindMemory(to: UInt8.self).baseAddress, size)
    }, 0)
    let converter = YlVorbisAudioConverter()
    try converter.configure(stream: .init(codec: .vorbis, sampleRate: Double(stream.sample_rate),
      channelCount: Int(stream.channel_count), magicCookie: cookie, generation: 1))
    var outputs = [YlScheduledAudioBuffer](); var index: Int64 = 0
    while index < 8 {
      var packet: YLFPacketRef?
      let result = ylf_read_packet(opened, &packet)
      if result == YLFResultEOF { break }
      XCTAssertEqual(result, 0)
      defer { ylf_packet_release(&packet) }
      let owned = try XCTUnwrap(packet)
      guard ylf_packet_stream_index(owned) == stream.index else { continue }
      let bytes = try XCTUnwrap(ylf_packet_data(owned))
      let output = try converter.convert(packet: .init(data: Data(bytes: bytes, count: ylf_packet_size(owned)),
        ptsUs: -30_000 + index * 10_000, durationUs: 10_000, generation: 1, presentationStartUs: target))
      if let output { outputs.append(output) }
      index += 1
    }
    return outputs
  }
  func testInitialDecodeNeverPresentsNegativePCM() throws {
    let outputs = try decode(target: nil)
    XCTAssertFalse(outputs.isEmpty)
    XCTAssertTrue(outputs.allSatisfy { $0.ptsUs >= 0 })
    XCTAssertLessThan(try XCTUnwrap(outputs.first).ptsUs, 1000)
  }
  func testExplicitPrerollTargetTrimsAcrossSeveralPackets() throws {
    let outputs = try decode(target: 15_000)
    XCTAssertFalse(outputs.isEmpty)
    XCTAssertTrue(outputs.allSatisfy { $0.ptsUs >= 15_000 })
    XCTAssertLessThan(try XCTUnwrap(outputs.first).ptsUs, 16_000)
    for output in outputs {
      let pcm = try XCTUnwrap(output.payload as? AVAudioPCMBuffer)
      XCTAssertEqual(output.byteCount, Int(pcm.frameLength * pcm.format.channelCount) * 4)
    }
  }
}
