@testable import yl_player_media_core
@testable import yl_player_apple
import CoreMedia
import Foundation
import XCTest

/// Self-contained canonical fixture peer. The separately recorded MediaMTX
/// interoperability run exercises the same production source against an independent server.
final class YlRtmpFixturePeer {
  private let peer: RtmpScriptPeer?
  let port: UInt16
  private(set) var expectedFlvBytes=0
  init(videoOnly: Bool = false, repetitions: Int = 8, tlsIdentity: Data? = nil) throws {
    if tlsIdentity == nil, !videoOnly, repetitions == 8, let raw = ProcessInfo.processInfo.environment["YL_RTMP_EXTERNAL_PEER_PORT"],
       let port = UInt16(raw), port > 0 {
      self.port = port; peer = nil; return
    }
    func wire(_ type:Int,_ stream:UInt32,_ time:UInt32,_ payload:Data)->Data {
      var result=Data([3]);result.rtmpBE(UInt64(time),3);result.rtmpBE(UInt64(payload.count),3);result.append(UInt8(type))
      for shift in 0..<4 {result.append(UInt8(truncatingIfNeeded:stream>>(shift*8)))}
      for at in stride(from:0,to:payload.count,by:128) {
        if at>0 {result.append(0xc3)}
        result.append(payload.subdata(in:at..<min(at+128,payload.count)))
      }
      return result
    }
    var output=Data()
    for (stream,values):(UInt32,[Any]) in [
      (0,["_result",1.0,NSNull(),["code":"NetConnection.Connect.Success"]]),
      (0,["_result",2.0,NSNull(),1.0]),
      (1,["onStatus",0.0,NSNull(),["code":"NetStream.Play.Start","level":"status"]])] {
      output.append(wire(20,stream,0,try YlRtmpAmf.encode(values)))
    }
    let url=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"h264_aac",withExtension:"flv"))
    let bytes=try Data(contentsOf:url);var tags:[(Int,UInt32,Data)]=[],at=13
    while at<bytes.count {
      guard bytes.count-at>=15 else {throw YlByteSourceError.closed}
      let n=Int(bytes.rtmpUInt(at+1,3));guard at+n+15<=bytes.count else {throw YlByteSourceError.closed}
      let type=Int(bytes[at]),time=UInt32(bytes.rtmpUInt(at+4,3))|(UInt32(bytes[at+7])<<24)
      let payload=bytes.subdata(in:at+11..<at+11+n)
      if (type == 9 || (type == 8 && !videoOnly)) && !(type==9 && payload.count>=2 && payload[1]==2) {tags.append((type,time,payload))}
      at += n+15
    }
    let span=(tags.map {$0.1}.max() ?? 0)+40
    for epoch in 0..<repetitions {for (type,time,payload) in tags {output.append(wire(type,1,time+UInt32(epoch)*span,payload))}}
    expectedFlvBytes=13+repetitions*tags.reduce(0) {$0+$1.2.count+15}
    let owned=try RtmpScriptPeer(prefix:output,tlsIdentity:tlsIdentity); peer=owned; port=owned.port
  }
  var acceptCount: Int { peer?.acceptCount ?? 0 }
  func disconnectCurrent() {peer?.disconnectCurrent()}
  func close() {peer?.close()}
}

/// Seek/retry policy tests need a committed managed session, not a physical
/// hardware decoder. Keep the real transport/demux/session behavior and replace
/// only the VideoToolbox boundary, as the managed-pause tests already do.
/// This fixture emits no images and must not be used as decoded-frame evidence.
struct RtmpPolicyVideoFactory: YlVTSessionFactory {
  func makeSession(formatDescription: CMVideoFormatDescription,
                   output: @escaping (YlVTDecodedImage) -> Void) throws -> YlVTSession {
    RtmpPolicyVideoSession()
  }
}

private final class RtmpPolicyVideoSession: YlVTSession {
  let usesHardwareDecoder = true
  let hardwareEvidence = YlHardwareDecoderEvidence(mode: .hardware)
  func decode(_ sample: CMSampleBuffer, generation: UInt64,
              reservation: YlVideoDecodeReservation?) -> OSStatus {
    reservation?.release()
    return noErr
  }
  func flush() {}
  func invalidate() {}
}
