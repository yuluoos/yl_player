@testable import yl_player_media_core
@testable import yl_player_apple
import Foundation
import Network
import XCTest

final class YlRtmpRouteTests: XCTestCase {
  @MainActor
  func testPublicRtmpTimeSeekRejectsZeroAndPositiveWithoutChangingIntent() async throws {
    let peer = try YlRtmpFixturePeer(videoOnly:true); defer { peer.close() }
    let commands = YlAsyncCommandCoordinator()
    let fixture = AppleHostFixture(commandCoordinator:commands, videoSessionFactory: RtmpPolicyVideoFactory()); defer { fixture.host.close() }
    var request = AppleHostFixture.request("rtmp-seek",url:"rtmp://127.0.0.1:\(peer.port)/live/owned",format:.flv,autoplay:true)
    request.source.intent = .live
    let loaded = try await loadWithDiagnostics(fixture.host, request: request)
    try await AppleHostCharacterizations.waitFor { fixture.host.initialState.engine == .managedFallback }
    for position:Int64 in [0,900] {
      let before = fixture.host.initialState, intent = fixture.host.playbackIntent
      XCTAssertFalse(commands.hasCurrent)
      XCTAssertThrowsError(try fixture.host.seekTo(command:.init(sessionId:loaded.sessionId,positionMs:position))) {
        XCTAssertEqual(($0 as? PigeonError)?.code,"policy.unsupported")
      }
      XCTAssertFalse(commands.hasCurrent,"rejected seek must not enter the coordinator intent queue")
      XCTAssertEqual(fixture.host.playbackIntent,intent)
      XCTAssertEqual(fixture.host.initialState.revision,before.revision)
      XCTAssertEqual(fixture.host.initialState.timeline.positionMs,before.timeline.positionMs)
      XCTAssertEqual(fixture.host.sessionId,loaded.sessionId)
      XCTAssertNil(fixture.host.initialState.failure)
      XCTAssertEqual(peer.acceptCount,1)
    }
  }
  @MainActor
  func testPublicHttpFlvTimeSeekRetainsRangeRejectionWithoutChangingIntent() async throws {
    let url = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"h264_aac",withExtension:"flv"))
    let peer = try RtmpRouteHttpPeer(data:Data(contentsOf:url)); defer { peer.close() }
    let commands = YlAsyncCommandCoordinator()
    let fixture = AppleHostFixture(commandCoordinator:commands, videoSessionFactory: RtmpPolicyVideoFactory()); defer { fixture.host.close() }
    var request = AppleHostFixture.request("http-seek",url:peer.url.absoluteString,format:.flv)
    request.source.intent = .live
    let loaded = try await loadWithDiagnostics(fixture.host, request: request)
    try await AppleHostCharacterizations.waitFor { fixture.host.initialState.engine == .managedFallback }
    for position:Int64 in [0,900] {
      let before = fixture.host.initialState, intent = fixture.host.playbackIntent
      XCTAssertThrowsError(try fixture.host.seekTo(command:.init(sessionId:loaded.sessionId,positionMs:position))) {
        XCTAssertEqual(($0 as? PigeonError)?.code,"network.range_not_supported")
      }
      XCTAssertFalse(commands.hasCurrent)
      XCTAssertEqual(fixture.host.playbackIntent,intent)
      XCTAssertEqual(fixture.host.initialState.revision,before.revision)
      XCTAssertEqual(fixture.host.initialState.timeline.positionMs,before.timeline.positionMs)
      XCTAssertEqual(fixture.host.sessionId,loaded.sessionId)
      XCTAssertNil(fixture.host.initialState.failure)
    }
  }
  @MainActor
  private func loadWithDiagnostics(_ host: YlApplePlayerHost, request: AppleLoadRequest) async throws -> AppleLoadReply {
    do { return try await host.load(request: request) }
    catch {
      print("RTMP route fixture load failed: \((error as? PigeonError)?.code ?? "unknown")")
      throw error
    }
  }

  func testClassicRtmpAutomaticSelectsOwnedManagedRoute() {
    let result = YlEngineRouter.assess(.init(uri: "rtmp://127.0.0.1/live/stream", kind: .network))
    XCTAssertNil(result.rejection)
    XCTAssertEqual(result.engine, .managedFallback)
    XCTAssertEqual(result.candidate.map { String(describing: $0) }, "networkRtmp")
  }
  func testRtmpsSelectsOwnedManagedRoute() {
    let result = YlEngineRouter.assess(.init(uri: "rtmps://example.test/live/stream", kind: .network))
    XCTAssertNil(result.rejection)
    XCTAssertEqual(result.engine, .managedFallback)
    XCTAssertEqual(result.candidate.map { String(describing: $0) }, "networkRtmp")
  }
  func testRtmpRejectsUnsupportedPoliciesBeforeOpen() {
    var source = YlAppleSourceDescriptor(uri: "rtmp://example.test/live/stream", kind: .network)
    source.headers = ["Accept": "video/flv"]
    XCTAssertEqual(YlEngineRouter.assess(source).rejection?.code, "policy.unsupported")
    source.headers = [:]; source.intent = .onDemand
    XCTAssertEqual(YlEngineRouter.assess(source).rejection?.code, "policy.unsupported")
    source.intent = .live; source.loadOptions = .init(startPositionMs: 1)
    XCTAssertEqual(YlEngineRouter.assess(source).rejection?.code, "policy.unsupported")
    source.loadOptions = .init(bufferStrategy: .bounded, minDurationMs: 0, maxDurationMs: 1000, maxManagedBytes: 16000000)
    XCTAssertEqual(YlEngineRouter.assess(source).rejection?.code, "policy.unsupported")
  }
  @MainActor
  func testPublicHostAdmitsRtmpAndRtmpsBeforeRouting() throws {
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    var request = AppleHostFixture.request("rtmp",url:"rtmp://127.0.0.1/live/test",format:.automatic)
    request.source.intent = .live
    let allowed = try fixture.host.assess(request:.init(source:request.source,options:request.options))
    XCTAssertEqual(allowed.candidateEngine,.managedFallback)
    XCTAssertNil(allowed.rejection)
    request.source.format = .mp4
    let wrongFormat = try fixture.host.assess(request:.init(source:request.source,options:request.options))
    XCTAssertEqual(wrongFormat.rejection?.code,"container.unsupported")
    request.source.format = .automatic
    request.source.locator = "rtmps://127.0.0.1/live/test"
    let secure = try fixture.host.assess(request:.init(source:request.source,options:request.options))
    XCTAssertNil(secure.rejection)
    XCTAssertEqual(secure.candidateEngine, .managedFallback)
  }

  func testAutomaticRtmpsUsesLiveBufferDefaults() {
    let source = YlAppleSourceDescriptor(uri: "rtmps://example.test/live/stream", kind: .network,
      loadOptions: .init(bufferStrategy: .automatic))
    let configuration = PlayerConfiguration(map: [:]).forLoad(source)
    XCTAssertEqual(configuration.bufferMode, "stable")
  }

  func testSecureAddressUses443AndPreservesExplicitPortAndTcUrl() throws {
    let secure = try YlRtmpAddress("rtmps://media.example/live/stream?token=opaque")
    XCTAssertTrue(secure.secure)
    XCTAssertEqual(secure.port, 443)
    XCTAssertEqual(secure.tcURL, "rtmps://media.example/live")
    XCTAssertEqual(secure.playpath, "stream?token=opaque")
    XCTAssertEqual(try YlRtmpAddress("rtmps://media.example:8443/live/stream").port, 8443)
    XCTAssertEqual(try YlRtmpAddress("rtmp://media.example/live/stream").port, 1935)
  }

  func testRtmpsKeepsPolicyRejectionsAndTlsFailuresAreTerminal() {
    var source = YlAppleSourceDescriptor(uri: "rtmps://example.test/live/stream", kind: .network)
    source.headers = ["Authorization": "private"]
    XCTAssertEqual(YlEngineRouter.assess(source).rejection?.code, "policy.unsupported")
    source.headers = [:]; source.intent = .onDemand
    XCTAssertEqual(YlEngineRouter.assess(source).rejection?.code, "policy.unsupported")
    let error = ylRtmpError("network.rtmp_tls_failed")
    XCTAssertFalse(YlRtmpRecoveryBudget.isTransient(error))
    XCTAssertNil(YlRtmpRecoveryBudget().nextDelay(after: error))
  }

  func testExplicitIncompatibleFormatRejectsAsContainerBeforeOpen() {
    let source = YlAppleSourceDescriptor(uri: "rtmp://example.test/live/stream", kind: .network, formatHint: .mp4)
    XCTAssertEqual(YlEngineRouter.assess(source).rejection?.code, "container.unsupported")
  }

}

private final class RtmpRouteHttpPeer {
  private let listener:NWListener
  private let queue=DispatchQueue(label:"yl.rtmp.route.http",qos:.userInitiated)
  private let lock=NSLock()
  private var connections:[NWConnection]=[]
  var url:URL { URL(string:"http://127.0.0.1:\(listener.port!.rawValue)/fixture.flv")! }
  init(data:Data) throws {
    listener=try NWListener(using:.tcp,on:.any)
    let ready=DispatchSemaphore(value:0)
    listener.stateUpdateHandler={if case .ready=$0 {ready.signal()}}
    listener.newConnectionHandler={ [weak self] connection in
      guard let self else {connection.cancel();return}
      self.lock.lock();self.connections.append(connection);self.lock.unlock()
      connection.start(queue:self.queue)
      connection.receive(minimumIncompleteLength:1,maximumLength:16384) { bytes,_,_,_ in
        guard let bytes,!bytes.isEmpty else {connection.cancel();return}
        var response=Data("HTTP/1.1 200 OK\r\nContent-Type: video/x-flv\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(data)
        connection.send(content:response,completion:.contentProcessed {_ in connection.cancel()})
      }
    }
    listener.start(queue:queue)
    guard ready.wait(timeout:.now()+2) == .success,listener.port != nil else {
      listener.cancel();throw YlByteSourceError.closed
    }
  }
  func close() {
    listener.cancel();lock.lock();let owned=connections;connections.removeAll();lock.unlock()
    owned.forEach {$0.cancel()}
  }
}
