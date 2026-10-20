@testable import yl_player_media_core
@testable import yl_player_apple
import Foundation
import Network
import Security
import XCTest

final class YlRtmpDemandTests: XCTestCase {
  private let config = Data([0x17,0,0,0,0,1,66,0,30,0xff,0xe1,0,2,0x67,0x42,1,0,2,0x68,0xce])
  private let coded = Data([0x17,1,0,0,0,0,0,0,2,0x65,0x88])
  private func commands() throws -> Data {
    var wire = Data()
    wire.append(try command(["_result",1.0,NSNull(),["code":"NetConnection.Connect.Success"]],stream:0))
    wire.append(try command(["_result",2.0,NSNull(),1.0],stream:0))
    wire.append(try command(["onStatus",0.0,NSNull(),["code":"NetStream.Play.Start","level":"status"]],stream:1))
    return wire
  }
  private func command(_ values:[Any],stream:UInt32)throws->Data {
    wire(type:20,stream:stream,payload:try YlRtmpAmf.encode(values))
  }
  private func wire(type:Int,stream:UInt32=1,time:UInt32=0,payload:Data)->Data {
    var result = Data([type <= 6 ? 2 : 3]); result.rtmpBE(UInt64(time),3)
    result.rtmpBE(UInt64(payload.count),3); result.append(UInt8(type))
    for shift in 0..<4 { result.append(UInt8(truncatingIfNeeded:stream>>(shift*8))) }
    for at in stride(from:0,to:payload.count,by:128) {
      if at > 0 { result.append(type <= 6 ? 0xc2 : 0xc3) }
      result.append(payload.subdata(in:at..<min(at+128,payload.count)))
    }
    return result
  }
  private func startup()throws->Data {
    try commands()+wire(type:9,payload:config)+wire(type:9,time:100,payload:coded)
  }
  private func source(_ peer:RtmpScriptPeer,setupMs:Int=10000,inactivityMs:Int=15000)throws->YlRtmpByteSource {
    .init(recipe:.init(address:try YlRtmpAddress("rtmp://127.0.0.1:\(peer.port)/live/test"),recovery:.init(),
      bufferScope:try YlManagedBufferLedger().makeScope(maxBytes:nil)),setupMs:setupMs,inactivityMs:inactivityMs)
  }
  private func read(_ source:YlRtmpByteSource)throws->Data {
    var buffer = [UInt8](repeating:0,count:65536)
    let n = try buffer.withUnsafeMutableBytes { try source.read(into:$0) }; return Data(buffer.prefix(n))
  }
  func testExplicitAmfDenialIsPermanentAndServerTextIsNotExposed() throws {
    let denial = try command(["_error",1.0,NSNull(),["code":"NetConnection.Connect.Rejected","description":"private-url-token"]],stream:0)
    let peer = try RtmpScriptPeer(prefix:denial); defer { peer.close() }
    let source = try source(peer); defer { source.cancel() }
    XCTAssertThrowsError(try read(source)) {
      guard case let YlByteSourceError.failed(error) = $0 else { return XCTFail("Missing typed denial") }
      XCTAssertEqual(error.code,"network.rtmp_stream_unavailable")
      XCTAssertFalse(YlRtmpRecoveryBudget.isTransient(error)); XCTAssertFalse(error.message.contains("private"))
    }
  }
  func testOpeningDeadlineContinuesThroughRealAvioDiscoveryAfterFirstKeyframe() throws {
    let peer = try RtmpScriptPeer(prefix:startup()); defer { peer.close() }
    let source = try source(peer,setupMs:180); defer { source.cancel() }
    let start = Date()
    XCTAssertThrowsError(try YlOpenedMedia(byteSource:source)) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code,"network.rtmp_handshake_failed")
    }
    XCTAssertLessThan(Date().timeIntervalSince(start),1)
  }
  func testConfigurationOnlyCannotCompleteSetup() throws {
    let peer = try RtmpScriptPeer(prefix:commands()+wire(type:9,payload:config)); defer { peer.close() }
    let source = try source(peer,setupMs:120); defer { source.cancel() }
    XCTAssertThrowsError(try read(source)) {
      guard case let YlByteSourceError.failed(error) = $0 else { return XCTFail("Missing timeout") }
      XCTAssertEqual(error.code,"network.rtmp_handshake_failed")
    }
  }
  func testTemporaryInterruptPreservesPartialChunkHeaderAndPayloadOnSameSocket() throws {
    for split in [1,17] {
      let next = wire(type:9,time:200,payload:coded)
      let peer = try RtmpScriptPeer(prefix:startup()+next.prefix(split),suffix:Data(next.dropFirst(split)))
      defer { peer.close() }
      let source = try source(peer); defer { source.cancel() }
      for _ in 0..<3 { _ = try read(source) }; try source.finishPreparation()
      XCTAssertTrue(peer.waitUntilPrefixSent())
      let interrupted = expectation(description:"interrupt partial chunk")
      DispatchQueue.global().async {
        do { _ = try self.read(source); XCTFail("Partial read should be interrupted") }
        catch YlByteSourceError.cancelled {}
        catch { XCTFail("Unexpected \(type(of:error))") }
        interrupted.fulfill()
      }
      // Source read demand has started; peer deliberately withholds the remainder.
      Thread.sleep(forTimeInterval:0.03); source.interruptRead(); wait(for:[interrupted],timeout:1)
      source.resumeReads(); peer.releaseSuffix()
      let tag = try read(source)
      XCTAssertEqual(tag[6],200); XCTAssertEqual(tag.subdata(in:11..<22),coded)
      XCTAssertEqual(peer.acceptCount,1)
    }
  }
  func testConsumerIdleDoesNotSpendInactivityBudget() throws {
    let peer = try RtmpScriptPeer(prefix:startup(),suffix:wire(type:9,time:200,payload:coded)); defer { peer.close() }
    let source = try source(peer,inactivityMs:100); defer { source.cancel() }
    for _ in 0..<3 { _ = try read(source) }; try source.finishPreparation()
    Thread.sleep(forTimeInterval:0.22)
    peer.releaseSuffix(); XCTAssertEqual(try read(source)[6],200)
    let start = Date()
    XCTAssertThrowsError(try read(source)) {
      guard case let YlByteSourceError.failed(error) = $0 else { return XCTFail("Missing inactivity timeout") }
      XCTAssertEqual(error.code,"network.rtmp_disconnected")
    }
    XCTAssertGreaterThan(Date().timeIntervalSince(start),0.06)
    XCTAssertLessThan(Date().timeIntervalSince(start),0.5)
  }
  func testRepeatedConfigurationDoesNotResetActiveDemandBudget() throws {
    var wire = try startup()
    for _ in 0..<12000 { wire.append(self.wire(type:9,time:100,payload:config)) }
    let peer = try RtmpScriptPeer(prefix:wire); defer { peer.close() }
    let source = try source(peer,inactivityMs:20); defer { source.cancel() }
    for _ in 0..<3 { _ = try read(source) }; try source.finishPreparation()
    var count = 0
    XCTAssertThrowsError(try { while count < 12000 { _ = try read(source); count += 1 } }()) {
      guard case let YlByteSourceError.failed(error) = $0 else { return XCTFail("Missing aggregate active-demand timeout") }
      XCTAssertEqual(error.code,"network.rtmp_disconnected")
    }
    XCTAssertLessThan(count,12000)
  }
}

final class RtmpScriptPeer {
  private let listener: NWListener
  private let queue = DispatchQueue(label:"yl.rtmp.script.peer")
  private let condition = NSCondition()
  private var connection:NWConnection?, prefixSent = false
  private var count = 0
  private(set) var port:UInt16 = 0
  private let prefix:Data, suffix:Data
  var acceptCount:Int { condition.lock(); defer { condition.unlock() }; return count }
  init(prefix:Data,suffix:Data=Data(),closeOnConnect:Bool=false,tlsIdentity:Data?=nil)throws {
    self.prefix = prefix; self.suffix = suffix
    let parameters: NWParameters
    if let tlsIdentity {
      var imported: CFArray?
      var options: [String: Any] = [kSecImportExportPassphrase as String: "local-test-only"]
      if #available(macOS 15, iOS 18, *) { options[kSecImportToMemoryOnly as String] = true }
      else {
        #if os(macOS)
        throw XCTSkip("Isolated TLS fixture requires macOS15 memory-only PKCS12 import")
        #endif
      }
      guard SecPKCS12Import(tlsIdentity as CFData, options as CFDictionary, &imported) == errSecSuccess,
            let first = (imported as? [[String: Any]])?.first,
            let identity = first[kSecImportItemIdentity as String] else { throw YlByteSourceError.closed }
      let tls = NWProtocolTLS.Options()
      sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity as! SecIdentity)!)
      sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
      parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    } else { parameters = .tcp }
    listener = try NWListener(using:parameters,on:.any)
    let ready = DispatchSemaphore(value:0)
    listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      self.condition.lock(); self.connection = connection; self.count += 1; self.condition.unlock()
      connection.start(queue:self.queue)
      if closeOnConnect { connection.cancel(); return }
      self.exact(connection,1537) { c0c1 in
        guard c0c1.count == 1537 && c0c1[0] == 3 else { connection.cancel(); return }
        let s1 = Data(repeating:0,count:1536)
        connection.send(content:Data([3])+s1,completion:.contentProcessed { error in
          guard error == nil else { return }
          self.exact(connection,1536) { c2 in
            guard c2 == s1 else { connection.cancel(); return }
            connection.send(content:Data(c0c1.dropFirst())+self.prefix,completion:.contentProcessed { _ in
              self.condition.lock(); self.prefixSent = true; self.condition.broadcast(); self.condition.unlock()
            })
          }
        })
      }
    }
    listener.start(queue:queue)
    guard ready.wait(timeout:.now()+2) == .success,let port=listener.port?.rawValue else { listener.cancel(); throw YlByteSourceError.closed }
    self.port = port
  }
  private func exact(_ connection:NWConnection,_ n:Int,_ accumulated:Data=Data(),completion:@escaping(Data)->Void) {
    connection.receive(minimumIncompleteLength:1,maximumLength:n-accumulated.count) { [weak self] data,_,eof,error in
      guard let self,let data,!data.isEmpty,error == nil else { return }
      let bytes = accumulated+data
      if bytes.count == n { completion(bytes) }
      else if !eof { self.exact(connection,n,bytes,completion:completion) }
    }
  }
  func waitUntilPrefixSent()->Bool {
    condition.lock(); defer { condition.unlock() }; let end = Date().addingTimeInterval(1)
    while !prefixSent { if !condition.wait(until:end) { return false } }; return true
  }
  func releaseSuffix() { condition.lock(); let c=connection; condition.unlock(); c?.send(content:suffix,completion:.contentProcessed { _ in }) }
  func disconnectCurrent() { condition.lock(); let socket=connection; condition.unlock(); socket?.cancel() }
  func close() { listener.cancel(); condition.lock(); let c=connection; condition.unlock(); c?.cancel() }
}
