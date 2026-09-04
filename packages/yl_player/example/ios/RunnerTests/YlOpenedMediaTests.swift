@testable import yl_player_ios
import Darwin
import Foundation
import XCTest
import YlFFmpegBridge

final class YlOpenedMediaTests: XCTestCase {
  private final class CancellationProbe {
    var count = 0
  }

  private final class MemoryByteSource: YlByteSource {
    let bytes: Data
    let probe: CancellationProbe
    private var offset = 0
    private var cancelled = false
    private(set) var seekCount = 0

    init(bytes: Data, probe: CancellationProbe = CancellationProbe()) {
      self.bytes = bytes
      self.probe = probe
    }

    var length: Int64? { Int64(bytes.count) }
    var supportsRandomAccess: Bool { true }
    var currentOffset: Int64 { Int64(offset) }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
      guard offset < bytes.count else { return 0 }
      let count = min(buffer.count, bytes.count - offset)
      bytes.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: offset..<(offset + count))
      offset += count
      return count
    }

    func seek(to offset: Int64) throws -> Int64 {
      seekCount += 1
      guard offset >= 0, offset <= Int64(bytes.count) else {
        throw YlByteSourceError.invalidOffset(
          expected: Int64(self.offset),
          actual: offset
        )
      }
      self.offset = Int(offset)
      return offset
    }

    func cancel() {
      guard !cancelled else { return }
      cancelled = true
      probe.count += 1
    }
    func handleMemoryWarning() {}
  }

  private func fixture() throws -> URL {
    try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mkv")
    )
  }

  func testNetworkOpenMatchesLocalStreamMetadata() throws {
    let url = try fixture()
    let bytes = try Data(contentsOf: url)
    let local = try YlOpenedMedia(recipe: .local(path: url.path, container: .matroska))
    let network = try YlOpenedMedia(byteSource: MemoryByteSource(bytes: bytes))
    defer {
      local.close()
      network.close()
    }

    XCTAssertEqual(network.info.stream_count, local.info.stream_count)
    XCTAssertEqual(network.info.duration_us, local.info.duration_us)
    for index in 0..<local.info.stream_count {
      var localStream = YLFStreamInfo()
      var networkStream = YLFStreamInfo()
      XCTAssertEqual(ylf_copy_stream_info(local.context, index, &localStream), 0)
      XCTAssertEqual(ylf_copy_stream_info(network.context, index, &networkStream), 0)
      XCTAssertEqual(networkStream.kind, localStream.kind)
      XCTAssertEqual(networkStream.codec, localStream.codec)
      XCTAssertEqual(networkStream.width, localStream.width)
      XCTAssertEqual(networkStream.height, localStream.height)
      XCTAssertEqual(networkStream.sample_rate, localStream.sample_rate)
    }
  }

  func testCallbackSourceOutlivesContextAndCloseCancelsExactlyOnce() throws {
    let probe = CancellationProbe()
    var source: MemoryByteSource? = MemoryByteSource(
      bytes: try Data(contentsOf: fixture()),
      probe: probe
    )
    weak var weakSource = source
    var media: YlOpenedMedia? = try YlOpenedMedia(byteSource: source!)
    source = nil

    XCTAssertNotNil(weakSource)
    media?.close()
    media?.close()
    media = nil

    XCTAssertEqual(probe.count, 1)
    XCTAssertNil(weakSource)
  }

  func testCancelInputWakesSourceBeforeContextIsClosed() throws {
    let probe = CancellationProbe()
    let source = MemoryByteSource(
      bytes: try Data(contentsOf: fixture()),
      probe: probe
    )
    let media = try YlOpenedMedia(byteSource: source)

    media.cancelInput()
    XCTAssertEqual(probe.count, 1)
    XCTAssertNotNil(media.context)

    media.close()
    XCTAssertEqual(probe.count, 1)
    XCTAssertNil(media.context)
  }

  func testCancelledControlOperationCannotReachFFmpegOrByteSourceSeek() throws {
    let source = MemoryByteSource(bytes: try Data(contentsOf: fixture()))
    let media = try YlOpenedMedia(byteSource: source)
    defer { media.close() }
    let seekCountBeforeCommand = source.seekCount
    let token = YlOpenCancellationToken()
    token.cancel()
    media.beginControlOperation(token)
    defer { media.endControlOperation() }

    XCTAssertThrowsError(try media.seek(toMediaTimeUs: 500_000)) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "network.cancelled")
    }
    XCTAssertEqual(source.seekCount, seekCountBeforeCommand)
  }

  func testHundredOpenReadCloseCyclesReleaseEveryPacket() throws {
    let bytes = try Data(contentsOf: fixture())
    for _ in 0..<100 {
      let media = try YlOpenedMedia(byteSource: MemoryByteSource(bytes: bytes))
      var packet: YLFPacketRef?
      XCTAssertEqual(ylf_read_packet(media.context, &packet), 0)
      XCTAssertNotNil(packet)
      media.close()
      XCTAssertEqual(ylf_debug_outstanding_packet_count(), 0)
    }
  }

  func testMediaSeekUsesByteSourceAndFFmpegTimeline() throws {
    let media = try YlOpenedMedia(
      byteSource: MemoryByteSource(bytes: try Data(contentsOf: fixture()))
    )
    defer { media.close() }

    XCTAssertEqual(try media.seek(toMediaTimeUs: 900_000), 900_000)
    var packet: YLFPacketRef?
    XCTAssertEqual(ylf_read_packet(media.context, &packet), 0)
    XCTAssertNotNil(packet)
    ylf_packet_release(&packet)
  }

  func testFlvOpenFailureUsesFormatSpecificError() {
    XCTAssertThrowsError(try YlOpenedMedia(
      recipe: .local(path: "/dev/null", container: .flv)
    )) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "container.flv_open_failed")
    }
  }
}
