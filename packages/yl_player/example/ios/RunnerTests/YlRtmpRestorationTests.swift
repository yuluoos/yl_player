@testable import yl_player_media_core
@testable import yl_player_apple
import AVFoundation
import Foundation
import Network
import XCTest

@MainActor
final class YlRtmpRestorationTests: XCTestCase {
  func testCommittedCoordinatorRestorationRetriesTransientPrepareAndCompletesOriginalWaiter() async throws {
    let upstream = try YlRtmpFixturePeer(); defer { upstream.close() }
    let proxy = try RtmpRetryProxy(targetPort:upstream.port,reject:[2]); defer { proxy.close() }
    let (coordinator,source,owner) = fixture(proxy.port); defer { coordinator.dispose(); owner.dispose() }
    let identity = YlAppleSessionIdentity(sessionId:"retained-session",loadRequestId:"owned-load")
    try await load(coordinator,source,identity)
    coordinator.deactivate()
    try await activate(coordinator)
    XCTAssertTrue(coordinator.isActive)
    XCTAssertEqual(coordinator.identity,identity)
    XCTAssertEqual(proxy.acceptCount,3)
    XCTAssertEqual(source.rtmpRecovery.attempts,1)
  }
  func testExhaustedRestorationMakesOneExplicitAttemptAndInitialCandidateNeverRetries() async throws {
    let upstream = try YlRtmpFixturePeer(); defer { upstream.close() }
    let proxy = try RtmpRetryProxy(targetPort:upstream.port,reject:[2,3,4,5]); defer { proxy.close() }
    let (coordinator,source,owner) = fixture(proxy.port); defer { coordinator.dispose(); owner.dispose() }
    try await load(coordinator,source,.init(sessionId:"existing",loadRequestId:"load"))
    for _ in 0..<3 { _ = source.rtmpRecovery.nextDelay(after:ylRtmpError("network.rtmp_disconnected")) }
    coordinator.deactivate()
    do { try await activate(coordinator); XCTFail("Exhausted restore must fail") }
    catch { XCTAssertEqual((error as? NativePlayerError)?.code,"network.retry_exhausted") }
    XCTAssertEqual(proxy.acceptCount,2)
    let initial = try RtmpRetryProxy(targetPort:upstream.port,reject:[1,2,3,4]); defer { initial.close() }
    let (other,newSource,otherOwner) = fixture(initial.port); defer { other.dispose(); otherOwner.dispose() }
    do { try await load(other,newSource,.init(sessionId:"new",loadRequestId:"new")); XCTFail("Initial failure must fail") } catch {}
    XCTAssertEqual(initial.acceptCount,1); XCTAssertEqual(newSource.rtmpRecovery.attempts,0)
  }
  private func fixture(_ port:UInt16)->(YlAppleSessionCoordinator,YlAppleSourceDescriptor,YlAppleTextureOwner) {
    let output = AppleTestTexture(), owner = YlAppleTextureOwner(output:AppleTestTexture(),onFrame:{ _ in })
    let coordinator = YlAppleSessionCoordinator(playerId:91,
      services:.init(platform:.current,textureOutput:output,makeDisplayDriver:{ AppleClockDisplay(onTick:$0) }),
      configuration:.init(map:[:]),textureOwner:owner,
      videoSessionFactory: RtmpPolicyVideoFactory(),emit:{ _,_ in })
    let source = YlAppleSourceDescriptor(uri:"rtmp://127.0.0.1:\(port)/live/owned",kind:.network,
      loadOptions:.init(autoplay:false,decoderPolicy:.systemDefault))
    return (coordinator,source,owner)
  }
  private func load(_ coordinator:YlAppleSessionCoordinator,_ source:YlAppleSourceDescriptor,_ identity:YlAppleSessionIdentity) async throws {
    try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
      coordinator.load(.init(source:source),identity:identity,willCommit:{ _ in },didCommit:{},didRollback:{}) {
        if case let .failure(error) = $0 { print("RTMP restoration fixture failed: \(error.code)") }
        continuation.resume(with:$0.mapError { $0 as Error })
      }
    }
  }
  private func activate(_ coordinator:YlAppleSessionCoordinator) async throws {
    try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
      coordinator.beginActivation(forcePlay:false,willCommit:{ _ in },didCommit:{},didRollback:{}) {
        if case let .failure(error) = $0 { print("RTMP restoration fixture failed: \(error.code)") }
        continuation.resume(with:$0.mapError { $0 as Error })
      }
    }
  }
}
private final class RtmpRetryProxy {
  private let listener:NWListener
  private let queue=DispatchQueue(label:"yl.rtmp.retry.proxy")
  private let lock=NSLock()
  private var count=0, connections:[NWConnection]=[]
  private(set) var port:UInt16=0
  var acceptCount:Int { lock.lock();defer {lock.unlock()};return count }
  init(targetPort:UInt16,reject:Set<Int>) throws {
    listener=try NWListener(using:.tcp,on:.any)
    let ready=DispatchSemaphore(value:0)
    listener.stateUpdateHandler={ state in if case .ready=state { ready.signal() } }
    listener.newConnectionHandler={ [weak self] incoming in
      guard let self else { incoming.cancel();return }
      self.lock.lock();self.count += 1;let index=self.count;self.connections.append(incoming);self.lock.unlock()
      incoming.start(queue:self.queue)
      if reject.contains(index) { incoming.cancel();return }
      let outgoing=NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:targetPort)!,using:.tcp)
      self.lock.lock();self.connections.append(outgoing);self.lock.unlock()
      outgoing.stateUpdateHandler={ [weak self] state in
        if case .ready=state { self?.pump(incoming,outgoing);self?.pump(outgoing,incoming) }
      }
      outgoing.start(queue:self.queue)
    }
    listener.start(queue:queue)
    guard ready.wait(timeout:.now()+2) == .success,let port=listener.port?.rawValue else { listener.cancel();throw YlByteSourceError.closed }
    self.port=port
  }
  private func pump(_ from:NWConnection,_ to:NWConnection) {
    from.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self] data,_,eof,error in
      guard let self else {return}
      guard let data,!data.isEmpty,error==nil else {from.cancel();to.cancel();return}
      to.send(content:data,completion:.contentProcessed { error in
        if error==nil && !eof {self.pump(from,to)} else {from.cancel();to.cancel()}
      })
    }
  }
  func close() {listener.cancel();lock.lock();let owned=connections;connections.removeAll();lock.unlock();owned.forEach {$0.cancel()} }
}
