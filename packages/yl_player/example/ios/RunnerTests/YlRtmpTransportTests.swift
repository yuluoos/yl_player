@testable import yl_player_media_core
@testable import yl_player_media_delivery
@testable import yl_player_apple
import Foundation
import Network
import XCTest
import AVFoundation
import QuartzCore
import YlFFmpegBridge

final class YlRtmpTransportTests: XCTestCase {
  func testRtmpsRejectsUntrustedCertificateTerminally() throws {
    let peer = try YlRtmpFixturePeer(tlsIdentity: ManagedTLSFixture.localhost)
    defer { peer.close() }
    let source = YlRtmpByteSource(recipe: .init(
      address: try YlRtmpAddress("rtmps://127.0.0.1:\(peer.port)/live/private-token"),
      recovery: .init(), bufferScope: try YlManagedBufferLedger().makeScope(maxBytes: nil)), setupMs: 1000)
    defer { source.cancel() }
    var buffer = [UInt8](repeating: 0, count: 64)
    XCTAssertThrowsError(try buffer.withUnsafeMutableBytes { try source.read(into: $0) }) {
      guard case let YlByteSourceError.failed(error) = $0 else { return XCTFail("Expected TLS failure") }
      XCTAssertEqual(error.code, "network.rtmp_tls_failed")
      XCTAssertFalse(YlRtmpRecoveryBudget.isTransient(error))
      XCTAssertFalse(error.message.contains("private-token"))
    }
    XCTAssertEqual(peer.acceptCount, 1)
  }

  func testRtmpsAirPlayRejectsUntrustedCertificateWithoutRetry() throws {
    let peer = try YlRtmpFixturePeer(tlsIdentity: ManagedTLSFixture.localhost)
    defer { peer.close() }
    let source = YlAppleSourceDescriptor(uri: "rtmps://127.0.0.1:\(peer.port)/live/private-token", kind: .network)
    XCTAssertThrowsError(try YlAirPlayLiveRemux.prepare(input: try YlAppleDeliveryInput.make(source: source, configuration: PlayerConfiguration(map: [:]), live: true), token: YlOpenCancellationToken())) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "network.rtmp_tls_failed")
    }
    XCTAssertEqual(peer.acceptCount, 1)
  }

  func testRtmpsEncryptedHandshakeDemuxesAvcAacAndFreshEpoch() throws {
    let peer = try YlRtmpFixturePeer(tlsIdentity: ManagedTLSFixture.localhost)
    defer { peer.close() }
    let source = YlAppleSourceDescriptor(uri: "rtmps://127.0.0.1:\(peer.port)/live/owned", kind: .network)
    for _ in 0..<2 {
      let prepared = try YlPreparedFallback(source: source, requireHardwareProbe: false,
        rtmpSourceFactory: Self.anchoredSource)
      defer { prepared.discard() }
      XCTAssertTrue(prepared.sourceRecipe.isRtmp)
      XCTAssertEqual(Int(prepared.videoStream.codec), YLFCodecH264)
      XCTAssertEqual(prepared.audioStreams.count, 1)
      XCTAssertEqual(Int(prepared.audioStreams[0].codec), YLFCodecAAC)
      XCTAssertFalse(prepared.isSeekable)
      let media = try prepared.takeMedia(); defer { media.close() }
      var packet: YLFPacketRef?
      XCTAssertEqual(ylf_read_packet(media.context, &packet), 0)
      XCTAssertNotNil(packet); ylf_packet_release(&packet)
    }
    XCTAssertEqual(peer.acceptCount, 2)
    XCTAssertEqual(source.rtmpRecovery.attempts, 0)
  }

  func testRtmpsWrongHostnameStopsOrdinaryRestorationWithoutSpendingBudget() throws {
    let peer = try YlRtmpFixturePeer(tlsIdentity: ManagedTLSFixture.mismatch)
    defer { peer.close() }
    let source = YlAppleSourceDescriptor(uri: "rtmps://127.0.0.1:\(peer.port)/live/private-token", kind: .network)
    XCTAssertThrowsError(try source.rtmpRecovery.prepareRestoration(token: YlOpenCancellationToken()) {
      try YlPreparedFallback(source: source, requireHardwareProbe: false, rtmpSourceFactory: Self.anchoredSource)
    }) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "network.rtmp_tls_failed")
      XCTAssertFalse(String(describing: $0).contains("private-token"))
    }
    XCTAssertEqual(source.rtmpRecovery.attempts, 0)
    XCTAssertEqual(peer.acceptCount, 1)
  }

  func testRtmpsSilentTLSHandshakeHasAbsoluteDeadlineAndCancelsPromptly() throws {
    let peer = try RtmpSilentPeer(); defer { peer.close() }
    let recipe = YlRtmpRequestRecipe(address: try YlRtmpAddress("rtmps://127.0.0.1:\(peer.port)/live/test"),
      recovery: .init(), bufferScope: try YlManagedBufferLedger().makeScope(maxBytes: nil))
    let source = YlRtmpByteSource(recipe: recipe, setupMs: 150)
    defer { source.cancel() }
    let start = Date()
    var buffer = [UInt8](repeating: 0, count: 64)
    XCTAssertThrowsError(try buffer.withUnsafeMutableBytes { try source.read(into: $0) }) {
      guard case let YlByteSourceError.failed(error) = $0 else { return XCTFail("Expected setup deadline") }
      XCTAssertEqual(error.code, "network.rtmp_handshake_failed")
    }
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.10)
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    XCTAssertTrue(peer.didAccept)

    let second = try RtmpSilentPeer(); defer { second.close() }
    let cancellable = YlRtmpByteSource(recipe: .init(
      address: try YlRtmpAddress("rtmps://127.0.0.1:\(second.port)/live/test"), recovery: .init(),
      bufferScope: try YlManagedBufferLedger().makeScope(maxBytes: nil)))
    defer { cancellable.cancel() }
    let finished = expectation(description: "TLS setup cancellation wakes blocked read")
    DispatchQueue.global().async {
      var bytes = [UInt8](repeating: 0, count: 64)
      do { _ = try bytes.withUnsafeMutableBytes { try cancellable.read(into: $0) }; XCTFail("Expected cancellation") }
      catch YlByteSourceError.cancelled {}
      catch { XCTFail("Unexpected \(type(of: error))") }
      finished.fulfill()
    }
    XCTAssertTrue(second.waitForAccept()); cancellable.cancel()
    wait(for: [finished], timeout: 1)
  }

  func testRtmpsAirPlayWrongHostnameIsTerminalWithoutRetry() throws {
    let peer = try YlRtmpFixturePeer(tlsIdentity: ManagedTLSFixture.mismatch)
    defer { peer.close() }
    let source = YlAppleSourceDescriptor(uri: "rtmps://127.0.0.1:\(peer.port)/live/test", kind: .network)
    XCTAssertThrowsError(try YlAirPlayLiveRemux.prepare(input: try YlAppleDeliveryInput.make(source: source, configuration: PlayerConfiguration(map: [:]), live: true), token: YlOpenCancellationToken(),
      rtmpSourceFactory: Self.anchoredSource)) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "network.rtmp_tls_failed")
    }
    XCTAssertEqual(peer.acceptCount, 1)
  }

  @MainActor
  func testRtmpsAirPlayProducesDecodedVideoAndReconnectsWithNewPeriod() async throws {
    let peer = try YlRtmpFixturePeer(repetitions: 32, tlsIdentity: ManagedTLSFixture.localhost)
    defer { peer.close() }
    let source = YlAppleSourceDescriptor(uri: "rtmps://127.0.0.1:\(peer.port)/live/test", kind: .network)
    let media = try await Task.detached {
      try YlAirPlayLiveRemux.prepare(input: try YlAppleDeliveryInput.make(source: source, configuration: PlayerConfiguration(map: [:]), live: true),
        token: YlOpenCancellationToken(), rtmpSourceFactory: Self.anchoredSource)
    }.value
    let item = AVPlayerItem(url: media.url)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    item.add(output)
    let player = AVPlayer(playerItem: item)
    player.isMuted = true
    defer { player.pause(); player.replaceCurrentItem(with: nil); withExtendedLifetime(media) {} }
    player.play()
    let deadline = Date().addingTimeInterval(15)
    var frame: CVPixelBuffer?
    while (frame == nil || item.status != .readyToPlay), Date() < deadline, item.status != .failed {
      frame = output.copyPixelBuffer(forItemTime: output.itemTime(forHostTime: CACurrentMediaTime()), itemTimeForDisplay: nil) ?? frame
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertEqual(item.status, .readyToPlay, "\(String(describing: item.error))")
    XCTAssertNotNil(frame, "Encrypted RTMP must produce actual decoded HLS video")
    if let frame { XCTAssertGreaterThan(CVPixelBufferGetWidth(frame), 0) }
    XCTAssertEqual(peer.acceptCount, 1)
    func playlist() async throws -> String {
      let (data, response) = try await URLSession.shared.data(for: URLRequest(url: media.url,
        cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3))
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
      return String(decoding: data, as: UTF8.self)
    }
    let before = try await playlist()
    XCTAssertFalse(before.contains("#EXT-X-ENDLIST"))
    let oldMaps = Set(before.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-MAP:") }.map(String.init))
    peer.disconnectCurrent()
    var recovered = ""
    let reconnectDeadline = Date().addingTimeInterval(15)
    while Date() < reconnectDeadline {
      recovered = try await playlist()
      let maps = Set(recovered.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-MAP:") }.map(String.init))
      if peer.acceptCount == 2, !maps.subtracting(oldMaps).isEmpty { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertEqual(peer.acceptCount, 2)
    XCTAssertTrue(recovered.contains("#EXT-X-DISCONTINUITY\n"))
    let newMaps = Set(recovered.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-MAP:") }.map(String.init))
    XCTAssertFalse(newMaps.subtracting(oldMaps).isEmpty)
    XCTAssertFalse(recovered.contains("#EXT-X-ENDLIST"))
  }

  private static func anchoredSource(_ recipe: YlRtmpRequestRecipe) -> YlRtmpByteSource {
    YlRtmpByteSource(recipe: recipe, configureTLS: { ManagedTLSFixture.anchor($0, hostname: recipe.address.host) })
  }

  @MainActor
  func testOpeningTrafficArrivesBeforeSessionCommitAndStopsAfterCancellation() async throws {
    let peer = try RtmpSilentPeer(initialBytes: Data([3]))
    defer { peer.close() }
    let fixture = AppleHostFixture()
    defer { fixture.host.close() }
    try fixture.host.attach()
    var request = AppleHostFixture.request("traffic-opening",
      url: "rtmp://127.0.0.1:\(peer.port)/live/test", format: .flv)
    request.source.intent = .live
    let loading = Task { try await fixture.host.load(request: request) }
    for _ in 0..<150 where fixture.callbacks.traffic.last?.1 != 1 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertNil(fixture.host.sessionId, "Traffic does not commit the pending playback session")
    XCTAssertEqual(fixture.callbacks.traffic.last?.0, "traffic-opening")
    XCTAssertEqual(fixture.callbacks.traffic.last?.1, 1, "Received handshake payload is observable while opening")
    try await fixture.host.stop()
    _ = try? await loading.value
    let count = fixture.callbacks.traffic.count
    try await Task.sleep(nanoseconds: 1_100_000_000)
    XCTAssertEqual(fixture.callbacks.traffic.count, count)
  }

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
  init(initialBytes: Data? = nil) throws {
    listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      self.condition.lock(); self.connection = connection; self.accepted = true; self.condition.broadcast(); self.condition.unlock()
      connection.start(queue: self.queue)
      if let initialBytes { connection.send(content: initialBytes, completion: .contentProcessed { _ in }) }
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
