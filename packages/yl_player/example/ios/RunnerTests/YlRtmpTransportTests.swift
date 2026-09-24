@testable import yl_player_apple
import Foundation
import Network
import XCTest

final class YlRtmpTransportTests: XCTestCase {
  func testAbsoluteSetupDeadlineWithSilentRealSocket() throws {
    let peer = try RtmpSilentPeer(); defer { peer.close() }
    let source = try makeSource(port: peer.port, setupMs: 120)
    defer { source.cancel() }
    let start = Date()
    var bytes = [UInt8](repeating: 0, count: 64)
    XCTAssertThrowsError(try bytes.withUnsafeMutableBytes { try source.read(into: $0) }) { error in
      guard case let YlByteSourceError.failed(native) = error else { return XCTFail("Expected a typed setup deadline: \(type(of: error))") }
      XCTAssertEqual(native.code, "network.rtmp_handshake_failed")
    }
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.08)
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    XCTAssertTrue(peer.didAccept)
  }
  func testCancelWakesBlockedHandshakeAndPreCancelledSourceDoesNotConnect() throws {
    let peer = try RtmpSilentPeer(); defer { peer.close() }
    let source = try makeSource(port: peer.port)
    let finished = expectation(description: "blocked read cancels")
    DispatchQueue.global().async {
      var bytes = [UInt8](repeating: 0, count: 64)
      do { _ = try bytes.withUnsafeMutableBytes { try source.read(into: $0) }; XCTFail("Expected cancellation") }
      catch YlByteSourceError.cancelled {}
      catch { XCTFail("Unexpected \(type(of: error))") }
      finished.fulfill()
    }
    XCTAssertTrue(peer.waitForAccept())
    source.cancel(); wait(for: [finished], timeout: 1)
    let second = try RtmpSilentPeer(); defer { second.close() }
    let cancelled = try makeSource(port: second.port); cancelled.cancel()
    var buffer = [UInt8](repeating: 0, count: 1)
    XCTAssertThrowsError(try buffer.withUnsafeMutableBytes { try cancelled.read(into: $0) }) {
      guard case YlByteSourceError.cancelled = $0 else { return XCTFail("Expected cancellation") }
    }
    XCTAssertFalse(second.didAccept)
  }
  func testInterruptWakesConsumerWithoutClosingHandshakeSocket() throws {
    let peer = try RtmpSilentPeer(); defer { peer.close() }
    let source = try makeSource(port: peer.port); defer { source.cancel() }
    let interrupted = expectation(description: "temporary interrupt")
    DispatchQueue.global().async {
      var bytes = [UInt8](repeating: 0, count: 64)
      do { _ = try bytes.withUnsafeMutableBytes { try source.read(into: $0) }; XCTFail("Expected interrupt") }
      catch YlByteSourceError.cancelled {}
      catch { XCTFail("Unexpected \(type(of: error))") }
      interrupted.fulfill()
    }
    XCTAssertTrue(peer.waitForAccept()); source.interruptRead()
    wait(for: [interrupted], timeout: 1)
    source.resumeReads()
    XCTAssertFalse(peer.didClose)
  }

  func testWorkspaceAdmissionFailsBeforeConnectAndCancellationReleasesReservation() throws {
    let peer = try RtmpSilentPeer(); defer { peer.close() }
    let ledger = YlManagedBufferLedger(maxBytes:16*1024*1024)
    let rejected = YlRtmpByteSource(recipe:.init(address:try YlRtmpAddress("rtmp://127.0.0.1:\(peer.port)/app/play"),
      recovery:.init(),bufferScope:try ledger.makeScope(maxBytes:nil)))
    var bytes = [UInt8](repeating:0,count:1)
    XCTAssertThrowsError(try bytes.withUnsafeMutableBytes { try rejected.read(into:$0) }) {
      guard case let YlByteSourceError.failed(error) = $0 else { return XCTFail("Expected admission failure") }
      XCTAssertEqual(error.code,"resource.exhausted")
    }
    XCTAssertFalse(peer.didAccept); XCTAssertEqual(ledger.snapshot.currentBytes,0)
    let owned = YlManagedBufferLedger()
    let source = YlRtmpByteSource(recipe:.init(address:try YlRtmpAddress("rtmp://127.0.0.1:\(peer.port)/app/play"),
      recovery:.init(),bufferScope:try owned.makeScope(maxBytes:nil)))
    let readFinished = expectation(description:"cancelled reader")
    DispatchQueue.global().async {
      var b = [UInt8](repeating:0,count:1); _ = try? b.withUnsafeMutableBytes { try source.read(into:$0) }
      readFinished.fulfill()
    }
    XCTAssertTrue(peer.waitForAccept()); XCTAssertGreaterThan(owned.snapshot.currentBytes,0)
    source.cancel(); wait(for:[readFinished],timeout:1)
    let end = Date().addingTimeInterval(1)
    while owned.snapshot.currentBytes != 0 && Date() < end { Thread.sleep(forTimeInterval:0.005) }
    XCTAssertEqual(owned.snapshot.currentBytes,0)
  }
  private func makeSource(port: UInt16, setupMs: Int = 10000) throws -> YlRtmpByteSource {
    YlRtmpByteSource(recipe: .init(address: try YlRtmpAddress("rtmp://127.0.0.1:\(port)/live/test"),
      recovery: .init(), bufferScope: try YlManagedBufferLedger().makeScope(maxBytes: nil)), setupMs: setupMs)
  }
}

private final class RtmpSilentPeer {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "yl.rtmp.test.peer")
  private let condition = NSCondition()
  private var connection: NWConnection?
  private var accepted = false, closed = false
  private(set) var port: UInt16 = 0
  var didAccept: Bool { condition.lock(); defer { condition.unlock() }; return accepted }
  var didClose: Bool { condition.lock(); defer { condition.unlock() }; return closed }
  init() throws {
    listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      self.condition.lock(); self.connection = connection; self.accepted = true; self.condition.broadcast(); self.condition.unlock()
      connection.start(queue: self.queue)
      self.receive(connection)
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now()+2) == .success, let port = listener.port?.rawValue else {
      listener.cancel(); throw YlByteSourceError.closed
    }
    self.port = port

  }
  private func receive(_ connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, eof, error in
      guard let self else { return }
      if eof || error != nil { self.condition.lock(); self.closed = true; self.condition.unlock() }
      else { self.receive(connection) }
    }
  }
  func waitForAccept() -> Bool {
    condition.lock(); defer { condition.unlock() }
    let end = Date().addingTimeInterval(1)
    while !accepted { if !condition.wait(until: end) { return false } }; return true
  }
  func close() { listener.cancel(); condition.lock(); let c = connection; condition.unlock(); c?.cancel() }
}
