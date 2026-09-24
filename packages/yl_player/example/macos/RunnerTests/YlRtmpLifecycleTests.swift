@testable import yl_player_apple
import Foundation
import XCTest
import YlFFmpegBridge

final class YlRtmpLifecycleTests: XCTestCase {
  func testRealAvioBlockedReadResumesSameContextAfterTemporaryInterrupt() throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "flv"))
    let bytes = try Data(contentsOf: url)
    let source = RtmpBlockingFlvSource(bytes: try repeatedFLV(bytes))
    let media = try YlOpenedMedia(byteSource: source)
    defer { source.cancel(); media.close() }
    let context = try XCTUnwrap(media.context)
    let interrupted = expectation(description: "real AVIO read interrupted")
    DispatchQueue.global().async {
      for _ in 0..<100000 {
        var packet: YLFPacketRef?
        let result = ylf_read_packet(context,&packet); ylf_packet_release(&packet)
        if result != 0 {
          XCTAssertEqual(result,Int32(YLFResultCallbackCancelled)); interrupted.fulfill(); return
        }
      }
      XCTFail("The AVIO reader did not reach the blocked callback"); interrupted.fulfill()
    }
    XCTAssertTrue(source.waitForBlockedRead())
    media.interruptRead(); wait(for: [interrupted],timeout:2)
    XCTAssertEqual(media.context,context)
    source.append(Data(bytes.dropFirst(13)))
    media.resumeReads()
    var packet: YLFPacketRef?
    XCTAssertEqual(ylf_read_packet(context,&packet),0)
    XCTAssertNotNil(packet); ylf_packet_release(&packet)
    XCTAssertEqual(source.cancellationCount,0)
    media.cancelInput(); XCTAssertEqual(source.cancellationCount,1)
  }
  func testSafeNativeRtmpErrorsNeverExposeServerText() {
    for code in ["network.rtmp_handshake_failed","network.rtmp_disconnected","network.rtmp_stream_unavailable","container.rtmp_track_layout_changed"] {
      let failure = YlAppleSafeDiagnostics.failure(NativePlayerError(category:"network",code:code,
        message:"rtmp://secret:password@host/app?token=private",diagnostic:"remote secret"),scope:.session)
      XCTAssertEqual(failure.code,code)
      XCTAssertFalse(failure.message.contains("secret")); XCTAssertFalse(failure.message.contains("private"))
      XCTAssertEqual(failure.retryable,["network.rtmp_handshake_failed","network.rtmp_disconnected"].contains(code))
    }
  }
  private func repeatedFLV(_ bytes: Data) throws -> Data {
    var tags: [(Data,UInt32)] = [], at = 13
    while at < bytes.count {
      guard bytes.count-at >= 15 else { throw YlByteSourceError.closed }
      let size = Int(bytes.rtmpUInt(at+1,3))
      guard at+size+15 <= bytes.count else { throw YlByteSourceError.closed }
      let tag = bytes.subdata(in:at..<at+size+15)
      let time = UInt32(tag.rtmpUInt(4,3)) | (UInt32(tag[7])<<24)
      if !(tag[0] == 9 && size >= 2 && tag[12] == 2) { tags.append((tag,time)) }
      at += size+15
    }
    var result = Data(bytes.prefix(13)); let span = (tags.map(\.1).max() ?? 0)+40
    for epoch in 0..<12 {
      for (original,time) in tags where epoch == 0 || original[0] != 18 {
        var tag = original; let stamp = time+UInt32(epoch)*span
        tag[4] = UInt8(truncatingIfNeeded:stamp>>16); tag[5] = UInt8(truncatingIfNeeded:stamp>>8)
        tag[6] = UInt8(truncatingIfNeeded:stamp); tag[7] = UInt8(stamp>>24); result.append(tag)
      }
    }
    return result
  }
}
private final class RtmpBlockingFlvSource: YlByteSource {
  private let condition = NSCondition()
  private var bytes: Data, offset = 0, blocked = false, interrupted = false, cancelled = false
  private(set) var cancellationCount = 0
  init(bytes: Data) { self.bytes = bytes }
  var length: Int64? { nil }
  var supportsRandomAccess: Bool { false }
  var currentOffset: Int64 { Int64(offset) }
  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    condition.lock(); defer { condition.unlock() }
    while offset == bytes.count && !interrupted && !cancelled {
      blocked = true; condition.broadcast(); condition.wait()
    }
    if interrupted || cancelled { throw YlByteSourceError.cancelled }
    let count = min(buffer.count,bytes.count-offset)
    bytes.copyBytes(to:buffer.bindMemory(to:UInt8.self),from:offset..<offset+count); offset += count; return count
  }
  func seek(to offset: Int64) throws -> Int64 { throw YlByteSourceError.failed(ylRtmpError("network.range_not_supported")) }
  func interruptRead() { condition.lock(); interrupted = true; condition.broadcast(); condition.unlock() }
  func resumeReads() { condition.lock(); interrupted = false; condition.broadcast(); condition.unlock() }
  func append(_ value: Data) { condition.lock(); bytes.append(value); condition.broadcast(); condition.unlock() }
  func cancel() { condition.lock(); if !cancelled { cancellationCount += 1 }; cancelled = true; condition.broadcast(); condition.unlock() }
  func handleMemoryWarning() {}
  func waitForBlockedRead() -> Bool {
    condition.lock(); defer { condition.unlock() }; let end = Date().addingTimeInterval(2)
    while !blocked { if !condition.wait(until:end) { return false } }; return true
  }
}
