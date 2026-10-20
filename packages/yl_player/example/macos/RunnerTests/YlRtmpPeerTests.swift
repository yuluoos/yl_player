@testable import yl_player_media_core
@testable import yl_player_apple
import Foundation
import XCTest
import YlFFmpegBridge

/// Canonical runs own an in-process fixture peer; an explicit test-runner
/// environment may select the independent MediaMTX companion instead.
final class YlRtmpPeerTests: XCTestCase {
  func testSocketFixturePreparesClassicAvcAacAndFreshEpoch() throws {
    let peer = try YlRtmpFixturePeer(); defer { peer.close() }
    let source = YlAppleSourceDescriptor(uri:"rtmp://127.0.0.1:\(peer.port)/live/owned",kind:.network)
    for _ in 0..<2 {
      let prepared = try YlPreparedFallback(source:source,requireHardwareProbe:false)
      defer { prepared.discard() }
      XCTAssertTrue(prepared.sourceRecipe.isRtmp)
      XCTAssertTrue(prepared.sourceRecipe.rtmpRecovery === source.rtmpRecovery)
      XCTAssertEqual(Int(prepared.videoStream.codec),YLFCodecH264)
      XCTAssertEqual(prepared.audioStreams.count,1)
      XCTAssertEqual(Int(prepared.audioStreams[0].codec),YLFCodecAAC)
      XCTAssertEqual(prepared.audioStreams[0].sample_rate,48000)
      XCTAssertFalse(prepared.isSeekable)
      let media = try prepared.takeMedia(); defer { media.close() }
      XCTAssertFalse(media.supportsRandomAccess)
      var packet: YLFPacketRef?
      XCTAssertEqual(ylf_read_packet(media.context,&packet),0)
      XCTAssertNotNil(packet); ylf_packet_release(&packet)
    }
    XCTAssertEqual(source.rtmpRecovery.attempts,0,"Explicit fresh epochs do not spend the automatic budget")
  }
  func testBareEofDoesNotInventStreamDenial() throws {
    let peer = try RtmpScriptPeer(prefix:Data(),closeOnConnect:true); defer { peer.close() }
    let source = YlAppleSourceDescriptor(uri:"rtmp://127.0.0.1:\(peer.port)/live/missing-private-token",kind:.network)
    XCTAssertThrowsError(try YlPreparedFallback(source:source,requireHardwareProbe:false)) {
      let error = $0 as? NativePlayerError
      XCTAssertEqual(error?.code,"network.rtmp_handshake_failed")
      XCTAssertTrue(YlRtmpRecoveryBudget.isTransient(error!))
      XCTAssertFalse(String(describing:$0).contains("private-token"))
    }
    XCTAssertEqual(source.rtmpRecovery.attempts,0)
  }
}
