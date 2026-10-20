@testable import yl_player_media_core
@testable import yl_player_apple
import Foundation
import XCTest

final class YlRtmpProtocolTests: XCTestCase {
  func testFmtThreeNewMessageInheritsNonzeroAbsoluteDelta() throws {
    let wire = Data([3,0,0,7,0,0,1,9,1,0,0,0,0x17,0xc3,0x27])
    var offset = 0
    let reader = YlRtmpChunkReader { count in
      guard offset + count <= wire.count else { throw YlByteSourceError.closed }
      defer { offset += count }; return wire.subdata(in: offset..<offset+count)
    }
    let first = try reader.next(), second = try reader.next()
    XCTAssertEqual(first.timestamp, 7)
    XCTAssertEqual(second.timestamp, 14)
    XCTAssertEqual(second.payload, Data([0x27]))
  }
  func testAmfReadsKnownConnectResultAndRejectsTruncatedString() throws {
    let bytes = Data([2,0,7] + Array("_result".utf8) + [0,0x3f,0xf0,0,0,0,0,0,0,5,3,0,4] + Array("code".utf8) + [2,0,3] + Array("yes".utf8) + [0,0,9])
    let values = try YlRtmpAmf.decode(bytes)
    XCTAssertEqual(values[0] as? String, "_result")
    XCTAssertEqual(values[1] as? Double, 1)
    XCTAssertEqual((values[3] as? [String: Any])?["code"] as? String, "yes")
    XCTAssertThrowsError(try YlRtmpAmf.decode(Data([2,0,4,65])))
  }
  func testFlvStartupFlagsAndCompositionOffsetArePreserved() throws {
    let stream = YlRtmpFlvStream()
    let config = Data([0x17,0,0,0,0,1,66,0,30,0xff,0xe1,0,2,0x67,0x42,1,0,2,0x68,0xce])
    _ = try stream.accept(.init(type: 9, stream: 1, timestamp: 0, payload: config))
    XCTAssertEqual(try stream.header(), Data([70,76,86,1,1,0,0,0,9,0,0,0,0]))
    let coded = Data([0x17,1,0xff,0xff,0xfe,0,0,0,2,0x65,0x88])
    let tag = try XCTUnwrap(stream.accept(.init(type: 9, stream: 1, timestamp: 19, payload: coded)))
    XCTAssertEqual(tag.subdata(in: 11..<22), coded)
    XCTAssertEqual(tag[6], 19)
    _ = try stream.accept(.init(type: 9, stream: 1, timestamp: 20, payload: config))
    XCTAssertThrowsError(try stream.accept(.init(type: 8, stream: 1, timestamp: 20, payload: Data([0xaf,0,0x11,0x90])))) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "container.rtmp_track_layout_changed")
    }
  }
  func testMalformedPayloadPrecedesTimestampEpochAndValidResetPrecedesLayoutChange() throws {
    let stream = YlRtmpFlvStream()
    let config = Data([0x17,0,0,0,0,1,66,0,30,0xff,0xe1,0,2,0x67,0x42,1,0,2,0x68,0xce])
    _ = try stream.accept(.init(type: 9, stream: 1, timestamp: 9000, payload: config))
    _ = try stream.header()
    XCTAssertThrowsError(try stream.accept(.init(type: 9, stream: 1, timestamp: 0, payload: Data([0x17,0])))) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "network.protocol_unsupported")
    }
    var changed = config; changed[8] = 31
    XCTAssertThrowsError(try stream.accept(.init(type: 9, stream: 1, timestamp: 0, payload: changed))) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "network.rtmp_disconnected")
    }
  }
  func testRtmpAddressPreservesRawAppPlaypathAndRetryBudgetSurvivesCopies() throws {
    let address = try YlRtmpAddress("rtmp://example.test:1935/ap%70/path%2fmore+literal?key=%2B+")
    XCTAssertEqual(address.app, "ap%70")
    XCTAssertEqual(address.playpath, "path%2fmore+literal?key=%2B+")
    let source = YlAppleSourceDescriptor(uri: "rtmp://example.test/live/x", kind: .network)
    let copied = source
    let transient = NativePlayerError(category: "network", code: "network.rtmp_disconnected", message: "")
    XCTAssertEqual(source.rtmpRecovery.nextDelay(after: transient), 500)
    XCTAssertEqual(copied.rtmpRecovery.nextDelay(after: transient), 1000)
    XCTAssertEqual(source.rtmpRecovery.nextDelay(after: transient), 2000)
    XCTAssertNil(copied.rtmpRecovery.nextDelay(after: transient))
    XCTAssertNil(YlRtmpRecoveryBudget().nextDelay(after: .init(category: "network", code: "network.protocol_unsupported", message: "")))
  }
  func testExtendedTimestampsInterleaveAndChunkLimits() throws {
    // cs3 fmt0 extended timestamp=0x1000000, length=3, chunk size=2;
    // cs4 interleaves a complete message before cs3's fmt3 continuation.
    let wire = Data([3,255,255,255,0,0,3,9,1,0,0,0,1,0,0,0,17,18,
      4,0,0,2,0,0,1,8,1,0,0,0,33,195,1,0,0,0,19])
    var offset = 0
    let reader = YlRtmpChunkReader { n in
      guard offset+n <= wire.count else { throw YlByteSourceError.closed }
      defer { offset += n }; return wire.subdata(in:offset..<offset+n)
    }
    try reader.setChunkSize(2)
    let audio = try reader.next(); XCTAssertEqual(audio.payload,Data([33]))
    XCTAssertEqual(reader.allocatedBytes,3)
    let video = try reader.next(); XCTAssertEqual(video.payload,Data([17,18,19]))
    XCTAssertEqual(video.timestamp,0x1000000); XCTAssertEqual(reader.allocatedBytes,0)
    XCTAssertThrowsError(try reader.setChunkSize(0))
    XCTAssertThrowsError(try reader.setChunkSize(65537))
    let huge = Data([3,0,0,0,64,0,1,9,1,0,0,0]); var pos = 0
    let oversized = YlRtmpChunkReader { n in defer { pos += n }; return huge.subdata(in:pos..<pos+n) }
    XCTAssertThrowsError(try oversized.next()) { XCTAssertEqual(($0 as? NativePlayerError)?.code,"resource.exhausted") }
    XCTAssertEqual(oversized.allocatedBytes,0)
  }
  func testAbortReleasesPartialPayloadAndRetainsChunkHistory() throws {
    // A partial cs3 video precedes a complete abort control on cs2.
    let wire=Data([3,0,0,7,0,0,3,9,1,0,0,0,17,18,
      2,0,0,0,0,0,4,2,0,0,0,0,0,0,194,0,3,
      195,33,34,195,35])
    var offset=0
    let reader=YlRtmpChunkReader { n in
      defer {offset += n};return wire.subdata(in:offset..<offset+n)
    }
    try reader.setChunkSize(2)
    let abort=try reader.next()
    XCTAssertEqual(abort.type,2);XCTAssertEqual(reader.allocatedBytes,3)
    reader.abort(Int(abort.payload.rtmpUInt(0,4)))
    XCTAssertEqual(reader.allocatedBytes,0)
    let next=try reader.next()
    XCTAssertEqual(next.timestamp,14);XCTAssertEqual(next.stream,1)
    XCTAssertEqual(next.payload,Data([33,34,35]));XCTAssertEqual(reader.allocatedBytes,0)
  }
  func testPeerBandwidthCreditNeverRequiresRecursiveReads() throws {
    var sent = Data(); let flow = YlRtmpFlowControl { sent.append($0) }
    XCTAssertEqual(try flow.bandwidth(3080,mode:0),3080)
    try flow.write(.init(type:3,stream:0,timestamp:0,payload:Data([0,0,0,1])))
    XCTAssertEqual(sent.count,7); XCTAssertEqual(flow.pendingBytes,9)
    try flow.acknowledge(3073)
    XCTAssertEqual(sent.count,16); XCTAssertEqual(flow.pendingBytes,0)
    XCTAssertEqual(try flow.bandwidth(100,mode:1),100)
    XCTAssertNil(try flow.bandwidth(500,mode:2))
    XCTAssertThrowsError(try flow.acknowledge(100000))
  }
  func testAmfDepthEntryAndUtf8BoundsRejectBeforeUnboundedAllocation() {
    XCTAssertThrowsError(try YlRtmpAmf.decode(Data([12,0,0,64,1]))) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code,"resource.exhausted")
    }
    XCTAssertThrowsError(try YlRtmpAmf.decode(Data([2,0,1,255])))
    XCTAssertThrowsError(try YlRtmpAmf.decode(Data(repeating:5,count:257))) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code,"resource.exhausted")
    }
    var deep = Data()
    for _ in 0..<10 { deep.append(contentsOf:[10,0,0,0,1]) }; deep.append(5)
    XCTAssertThrowsError(try YlRtmpAmf.decode(deep))
  }
  func testRtmpUriMalformedLexicalFormsAreRejected() {
    for value in ["rtmp://h/app/", "rtmp://h/app", "rtmp://u:p@h/app/play", "rtmp://h:/app/play",
      "rtmp://h:0/app/play", "rtmp://h/app/play#x", "rtmp://h/ap%0a/play", "rtmp://h/app/play%zz"] {
      XCTAssertThrowsError(try YlRtmpAddress(value),value) {
        XCTAssertEqual(($0 as? NativePlayerError)?.code,"source.invalid_uri")
      }
    }
  }

  func testOpaqueEscapedBytesRemainValidWhileEscapedControlsAreRejected() throws {
    let address = try YlRtmpAddress("rtmp://example.test/ap%FF/play%FE?x=%ff+")
    XCTAssertEqual(address.app,"ap%FF"); XCTAssertEqual(address.playpath,"play%FE?x=%ff+")
    for value in ["%00","%1F","%7f","%C2%80","%c2%9f"] {
      XCTAssertThrowsError(try YlRtmpAddress("rtmp://example.test/app/play?x="+value))
    }
  }

}
