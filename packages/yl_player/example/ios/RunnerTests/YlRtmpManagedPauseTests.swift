@testable import yl_player_media_core
@testable import yl_player_apple
import AVFoundation
import Foundation
import XCTest
import YlFFmpegBridge

@MainActor
final class YlRtmpManagedPauseTests: XCTestCase {
  func testRetiredDecoderCancelsStalePacketBeforeReportingInvariant() throws {
    let url=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"h264_aac",withExtension:"flv"))
    let prepared=try YlPreparedFallback(source:.init(uri:url.absoluteString,kind:.file,formatHint:.flv),requireHardwareProbe:false)
    let budget=try YlFallbackBufferBudget.make(configuration:.init(map:[:]),prepared:prepared)
    let video=YlVideoPipeline(format:prepared.videoFormat,bufferBudget:budget,factory:PauseVTFactory())
    try video.initializeDecoder();video.discardDecoder()
    let media=try prepared.takeMedia();defer {media.close()}
    var packet:YLFPacketRef?
    XCTAssertEqual(ylf_read_packet(try XCTUnwrap(media.context),&packet),0)
    let owned=try XCTUnwrap(packet)
    var cancelled=false
    XCTAssertNil(video.consume(packet:&packet,ownedPacket:owned,generation:1,hasAudio:false,
      compatibility:.init(platform:.current),shouldCancel:{true},onSubmitted:{XCTFail("stale packet submitted")},onCancelled:{cancelled=true}))
    XCTAssertTrue(cancelled,"a retired generation must cancel, not report missing-decoder invariant")
    XCTAssertNil(packet)
  }
  func testPublicLiveEdgeInterruptsPendingReadWithSameIdentityAndFreeAttempt() async throws {
    let peer=try YlRtmpFixturePeer(videoOnly:true);defer {peer.close()}
    let descriptor=YlAppleSourceDescriptor(uri:"rtmp://127.0.0.1:\(peer.port)/live/owned",kind:.network,
      loadOptions:.init(decoderPolicy:.systemDefault))
    var input:YlRtmpByteSource?
    let prepared=try YlPreparedFallback(source:descriptor,requireHardwareProbe:false,rtmpSourceFactory:{recipe in
      let value=YlRtmpByteSource(recipe:recipe);input=value;return value
    })
    let source=try XCTUnwrap(input);let factory=PauseVTFactory();var failures:[String]=[]
    let session=try YlManagedPlaybackSession(playerId:95,
      services:.init(platform:.current,textureOutput:AppleTestTexture(),makeDisplayDriver:{AppleClockDisplay(onTick:$0)}),
      configuration:.init(map:["audioPolicy":"appManaged"]),prepared:prepared,generation:1,
      videoSessionFactory:factory,loadRequestId:"same-load",emit:{if case .failure(let error)=$0.event {failures.append(error.code)}})
    defer {session.dispose()}
    try session.activate();try session.play()
    let deadline=Date().addingTimeInterval(3)
    while !(source.hasOutstandingRead && source.currentOffset >= peer.expectedFlvBytes) && Date()<deadline {try await Task.sleep(nanoseconds:5_000_000)}
    XCTAssertTrue(source.hasOutstandingRead);XCTAssertGreaterThanOrEqual(source.currentOffset,Int64(peer.expectedFlvBytes))
    let generation=session.recoveryGeneration,identity=session.channelGeneration
    try session.seekToLiveEdge()
    let reopened=Date().addingTimeInterval(2)
    while factory.creationThreads.count<2 && Date()<reopened {try await Task.sleep(nanoseconds:5_000_000)}
    XCTAssertEqual(peer.acceptCount,2);XCTAssertEqual(descriptor.rtmpRecovery.attempts,0)
    XCTAssertGreaterThan(session.recoveryGeneration,generation);XCTAssertEqual(session.channelGeneration,identity)
    XCTAssertEqual(session.playerId,95);XCTAssertTrue(failures.isEmpty)
    XCTAssertEqual(factory.creationThreads.last,false)
  }
  func testManagedPauseDuringBackoffRetainsOneReservedAttemptAndStopFencesResume() async throws {
    let peer=try YlRtmpFixturePeer(videoOnly:true);defer {peer.close()}
    let descriptor=YlAppleSourceDescriptor(uri:"rtmp://127.0.0.1:\(peer.port)/live/owned",kind:.network,
      loadOptions:.init(decoderPolicy:.systemDefault))
    var input:YlRtmpByteSource?
    let prepared=try YlPreparedFallback(source:descriptor,requireHardwareProbe:false,rtmpSourceFactory:{ recipe in
      let source=YlRtmpByteSource(recipe:recipe);input=source;return source
    })
    let source=try XCTUnwrap(input)
    var observed:[String]=[]
    let factory=PauseVTFactory(recoveryPreparationDelay:0.3)
    let session=try YlManagedPlaybackSession(playerId:94,
      services:.init(platform:.current,textureOutput:AppleTestTexture(),makeDisplayDriver:{AppleClockDisplay(onTick:$0)}),
      configuration:.init(map:["audioPolicy":"appManaged"]),prepared:prepared,generation:1,
      videoSessionFactory:factory,emit:{if case .failure(let e)=$0.event {observed.append(e.code)}})
    defer {session.dispose()}
    try session.activate();try session.play()
    let drainDeadline=Date().addingTimeInterval(3)
    while !(source.hasOutstandingRead && source.currentOffset >= peer.expectedFlvBytes) && Date()<drainDeadline {try await Task.sleep(nanoseconds:5_000_000)}
    XCTAssertGreaterThanOrEqual(source.currentOffset,Int64(peer.expectedFlvBytes))
    peer.disconnectCurrent()
    let reservationDeadline=Date().addingTimeInterval(2)
    while descriptor.rtmpRecovery.attempts==0 && Date()<reservationDeadline {try await Task.sleep(nanoseconds:5_000_000)}
    XCTAssertEqual(descriptor.rtmpRecovery.attempts,1,"active=\(session.isActive) generation=\(session.recoveryGeneration) failures=\(observed)")
    try session.pause();try await Task.sleep(nanoseconds:650_000_000)
    XCTAssertEqual(peer.acceptCount,1);XCTAssertEqual(descriptor.rtmpRecovery.attempts,1)
    try session.play()
    let reopenDeadline=Date().addingTimeInterval(2)
    while peer.acceptCount<2 && Date()<reopenDeadline {try await Task.sleep(nanoseconds:5_000_000)}
    XCTAssertEqual(peer.acceptCount,2);XCTAssertEqual(descriptor.rtmpRecovery.attempts,1)
    // Socket acceptance does not imply that asynchronous decoder preparation finished.
    // Keep the same overall reopen deadline instead of relying on a fixed delay.
    while factory.creationThreads.count<2 && Date()<reopenDeadline {try await Task.sleep(nanoseconds:5_000_000)}
    XCTAssertGreaterThanOrEqual(factory.creationThreads.count,2)
    XCTAssertEqual(factory.creationThreads.last,false,"resumed recovery must prepare off main")
    peer.disconnectCurrent()
    let secondDeadline=Date().addingTimeInterval(2)
    while descriptor.rtmpRecovery.attempts<2 && Date()<secondDeadline {try await Task.sleep(nanoseconds:5_000_000)}
    XCTAssertEqual(descriptor.rtmpRecovery.attempts,2)
    try session.pause();session.stop()
    try await Task.sleep(nanoseconds:1_100_000_000)
    XCTAssertEqual(peer.acceptCount,2);XCTAssertEqual(descriptor.rtmpRecovery.attempts,2)
  }
  func testManagedPauseSuspendsBlockedReadThenResumesSameConnectionAndStopCancels() async throws {
    let peer = try YlRtmpFixturePeer(videoOnly:true); defer {peer.close()}
    let descriptor = YlAppleSourceDescriptor(uri:"rtmp://127.0.0.1:\(peer.port)/live/owned",kind:.network,
      loadOptions:.init(decoderPolicy:.systemDefault))
    var input:YlRtmpByteSource?
    let prepared = try YlPreparedFallback(source:descriptor,requireHardwareProbe:false,rtmpSourceFactory:{ recipe in
      let source=YlRtmpByteSource(recipe:recipe,inactivityMs:300);input=source;return source
    })
    let source=try XCTUnwrap(input)
    var failures=0,retries=0
    let session=try YlManagedPlaybackSession(playerId:93,
      services:.init(platform:.current,textureOutput:AppleTestTexture(),makeDisplayDriver:{ AppleClockDisplay(onTick:$0) }),
      configuration:.init(map:["audioPolicy":"appManaged"]),prepared:prepared,generation:1,
      videoSessionFactory:PauseVTFactory(),emit:{ event in
        if case .failure = event.event {failures += 1}
        if case .retry = event.event {retries += 1}
      })
    defer {session.dispose()}
    try session.activate();try session.play()
    let deadline=Date().addingTimeInterval(3)
    while !(source.hasOutstandingRead && source.currentOffset >= peer.expectedFlvBytes) && Date()<deadline {try await Task.sleep(nanoseconds:5_000_000)}
    XCTAssertTrue(source.hasOutstandingRead,"managed demux must reach blocked socket read")
    XCTAssertGreaterThanOrEqual(source.currentOffset,Int64(peer.expectedFlvBytes),"all fixture media consumed before pause")
    try await Task.sleep(nanoseconds:100_000_000)
    try session.pause()
    try await Task.sleep(nanoseconds:450_000_000)
    XCTAssertEqual(descriptor.rtmpRecovery.attempts,0)
    XCTAssertEqual(retries,0);XCTAssertEqual(failures,0);XCTAssertEqual(peer.acceptCount,1)
    try session.play()
    try await Task.sleep(nanoseconds:60_000_000)
    XCTAssertEqual(descriptor.rtmpRecovery.attempts,0,"resume retains remaining active allowance")
    XCTAssertEqual(peer.acceptCount,1)
    try session.pause();try await Task.sleep(nanoseconds:400_000_000)
    XCTAssertEqual(descriptor.rtmpRecovery.attempts,0)
    try session.play()
    let remainingDeadline=Date().addingTimeInterval(0.25)
    while descriptor.rtmpRecovery.attempts==0 && Date()<remainingDeadline {try await Task.sleep(nanoseconds:5_000_000)}
    XCTAssertEqual(descriptor.rtmpRecovery.attempts,1,"resumed read must consume remaining allowance rather than reset or stay suspended")
    XCTAssertEqual(peer.acceptCount,1)
    try session.pause();session.stop()
    try await Task.sleep(nanoseconds:550_000_000)
    XCTAssertEqual(descriptor.rtmpRecovery.attempts,1);XCTAssertEqual(peer.acceptCount,1)
  }
}
private final class PauseVTFactory:YlVTSessionFactory {
  private let lock=NSLock()
  private var threads:[Bool]=[]
  private let recoveryPreparationDelay: TimeInterval
  init(recoveryPreparationDelay: TimeInterval = 0) { self.recoveryPreparationDelay = recoveryPreparationDelay }
  var creationThreads:[Bool] {lock.lock();defer {lock.unlock()};return threads}
  func makeSession(formatDescription:CMVideoFormatDescription,output:@escaping(YlVTDecodedImage)->Void)throws->YlVTSession {
    lock.lock(); let recovering = !threads.isEmpty; lock.unlock()
    // Accepting the socket is earlier than preparing its decoder. Exercise that gap.
    if recovering && recoveryPreparationDelay > 0 { Thread.sleep(forTimeInterval: recoveryPreparationDelay) }
    lock.lock();threads.append(Thread.isMainThread);lock.unlock();return PauseVTSession()
  }
}
private final class PauseVTSession:YlVTSession {
  let usesHardwareDecoder=true
  let hardwareEvidence=YlHardwareDecoderEvidence(mode:.hardware)
  func decode(_ sample:CMSampleBuffer,generation:UInt64,reservation:YlVideoDecodeReservation?)->OSStatus {reservation?.release();return noErr}
  func flush(){}
  func invalidate(){}
}
