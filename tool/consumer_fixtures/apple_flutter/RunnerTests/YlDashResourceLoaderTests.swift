@testable import yl_player_apple
import AVFoundation
import Network
import XCTest

private final class DashLoaderProtocol: URLProtocol {
  static let lock = NSLock()
  static var handler: ((DashLoaderProtocol) -> Void)?
  static var requests: [URLRequest] = []
  static func configuration(_ handler: @escaping (DashLoaderProtocol) -> Void) -> URLSessionConfiguration {
    lock.lock(); self.handler = handler; requests = []; lock.unlock()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DashLoaderProtocol.self]
    return config
  }
  static var captured: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock(); Self.requests.append(request); let handler = Self.handler; Self.lock.unlock()
    handler?(self)
  }
  override func stopLoading() {}
  func respond(_ data: Data, status: Int = 200, headers: [String: String] = [:], finalURL: URL? = nil, finish: Bool = true) {
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: finalURL ?? request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    if finish { client?.urlProtocolDidFinishLoading(self) }
  }
}

private final class DashLoadingRequest: YlHlsLoadingRequest {
  let url: URL
  var requestedOffset: Int64 = 0
  var currentOffset: Int64 = 0
  var requestedLength = 0
  var requestsAllDataToEnd = true
  var received = Data()
  var error: NativePlayerError?
  var contentType: String?
  var contentLength: Int64 = 0
  var rangeSupported = false
  var finishCount = 0
  var redirectRequest: URLRequest?
  init(_ url: URL) { self.url = url }
  func setContentInformation(contentType: String?, contentLength: Int64, byteRangeAccessSupported: Bool) {
    self.contentType = contentType; self.contentLength = contentLength; rangeSupported = byteRangeAccessSupported
  }
  func redirect(to request: URLRequest) { redirectRequest = request }
  func respond(with data: Data) { received.append(data) }
  func finishLoading() { finishCount += 1 }
  func finishLoading(with error: NativePlayerError) { self.error = error; finishCount += 1 }
}

final class YlDashResourceLoaderTests: XCTestCase {
  private let origin = URL(string: "https://origin.test/root/movie.mpd?token=private")!
  private var mpd: Data { Data("""
    <MPD type="static" mediaPresentationDuration="PT4S"><Period><AdaptationSet mimeType="video/mp4"><Representation id="v" bandwidth="1000" codecs="avc1.64001f" width="320" height="180"><SegmentTemplate initialization="init.mp4" media="seg-$Number$.m4s" duration="2"/></Representation></AdaptationSet></Period></MPD>
    """.utf8) }
  private func prepare(_ config: URLSessionConfiguration, token: YlOpenCancellationToken = .init(), context: YlHlsCredentialContext = .init(), headers: [String: String] = [:], readTimeoutMs: Int = 500, retention: YlManagedBufferLedger.OpaqueHlsRetention? = nil) throws -> YlPreparedHlsAsset {
    try YlPreparedHlsAsset(originURL: origin, isDash: true, headers: headers, configuration: .init(map: ["connectTimeoutMs": 500, "readTimeoutMs": readTimeoutMs]), cancellationToken: token, credentialContext: context, sessionConfiguration: config, opaqueRetention: retention)
  }
  private func read(_ loader: YlHlsResourceLoader, _ url: URL) -> DashLoadingRequest {
    let request = DashLoadingRequest(url)
    XCTAssertTrue(loader.startLoading(request)); XCTAssertEqual(request.finishCount, 1)
    return request
  }
  private func child(_ master: Data) throws -> URL {
    try XCTUnwrap(String(data: master, encoding: .utf8)?.split(separator: "\n").last.flatMap { URL(string: String($0)) })
  }

  func testProxyCancellationCannotInvalidateSessionDuringTaskAdmission() throws {
    let entered = expectation(description: "proxy reached URLSession task creation")
    let session = AdmissionRecordingSession(entered: entered)
    let proxy = try YlHlsMediaProxy(originURL: origin, headers: [:], configuration: .init(map: [:]), sessionFactory: { _, _, _ in session })
    defer { proxy.cancelAll() }
    let finished = expectation(description: "local connection closed")
    let url = try proxy.proxyURL(for: origin.deletingLastPathComponent().appendingPathComponent("segment.m4s"))
    URLSession.shared.dataTask(with: url) { _, _, _ in finished.fulfill() }.resume()
    wait(for: [entered], timeout: 3)
    let cancelled = expectation(description: "proxy cancellation finished")
    DispatchQueue.global().async {
      session.requestCancellation()
      proxy.cancelAll()
      cancelled.fulfill()
    }
    XCTAssertEqual(session.cancellationRequested.wait(timeout: .now() + 2), .success)
    // If invalidation can pass the in-flight admission, observe it before
    // releasing creation. Fixed code excludes it with the lifecycle lock.
    _ = session.invalidated.wait(timeout: .now() + 0.15)
    session.releaseCreation.signal()
    wait(for: [cancelled, finished], timeout: 3)
    XCTAssertEqual(session.events, ["create.enter", "cancel.request", "create.return", "resume", "invalidate", "cancel"])
    XCTAssertThrowsError(try proxy.proxyURL(for: origin))
  }

  func testLoaderCancellationCannotInvalidateSessionDuringTaskAdmission() throws {
    let entered = expectation(description: "loader reached URLSession task creation")
    let session = AdmissionRecordingSession(entered: entered)
    let loader = try YlHlsResourceLoader(originURL: origin, headers: [:], configuration: .init(map: [:]), sessionFactory: { _, _, _ in session })
    defer { loader.cancelAll() }
    let request = DashLoadingRequest(try loader.encodedAssetURL())
    let started = expectation(description: "startLoading returned")
    DispatchQueue.global().async { loader.startLoading(request); started.fulfill() }
    wait(for: [entered], timeout: 3)
    let cancelled = expectation(description: "loader cancellation finished")
    DispatchQueue.global().async {
      session.requestCancellation()
      loader.cancelAll()
      cancelled.fulfill()
    }
    XCTAssertEqual(session.cancellationRequested.wait(timeout: .now() + 2), .success)
    _ = session.invalidated.wait(timeout: .now() + 0.15)
    session.releaseCreation.signal()
    wait(for: [cancelled, started], timeout: 3)
    // Loader explicitly cancels its published task before session invalidation.
    XCTAssertEqual(session.events, ["create.enter", "cancel.request", "create.return", "resume", "cancel", "invalidate", "cancel"])
    XCTAssertEqual(request.finishCount, 1)
    XCTAssertEqual(request.error?.code, "network.cancelled")
  }

  func testPreflightCreatesPrivateMasterAndProxiesAllMediaWithoutCredentials() throws {
    let data = mpd
    let prepared = try prepare(DashLoaderProtocol.configuration { $0.respond(data, headers: ["Content-Type": "application/octet-stream"]) })
    defer { prepared.discard() }
    XCTAssertNotEqual(try YlHlsURLCodec.decode(prepared.asset.url), origin)
    let master = read(prepared.loader, prepared.asset.url)
    XCTAssertNil(master.error)
    XCTAssertEqual(master.contentLength, Int64(master.received.count))
    XCTAssertEqual(master.contentType, "com.apple.m3u-playlist")
    XCTAssertTrue(master.rangeSupported)
    let video = read(prepared.loader, try child(master.received))
    let text = try XCTUnwrap(String(data: video.received, encoding: .utf8))
    XCTAssertEqual(text.components(separatedBy: "http://127.0.0.1:").count - 1, 3)
    XCTAssertFalse(text.contains("origin.test")); XCTAssertTrue(text.contains("#EXT-X-ENDLIST"))
    XCTAssertEqual(DashLoaderProtocol.captured.count, 1)
    XCTAssertEqual(DashLoaderProtocol.captured.first?.url, origin)
  }

  func testRegistryMissAndWrongKindNeverReachNetworkOrRedirect() throws {
    let data = mpd
    let prepared = try prepare(DashLoaderProtocol.configuration { $0.respond(data) })
    defer { prepared.discard() }
    let plain = try YlHlsURLCodec.decode(prepared.asset.url)
    for url in [try YlHlsURLCodec.encode(plain.appendingPathComponent("missing"), kind: .manifest), try YlHlsURLCodec.encode(plain, kind: .media), try YlHlsURLCodec.encode(origin, kind: .manifest), try YlHlsURLCodec.encode(plain, kind: .key)] {
      let request = read(prepared.loader, url)
      XCTAssertEqual(request.error?.code, "container.hls_url_invalid")
      XCTAssertNil(request.redirectRequest); XCTAssertTrue(request.received.isEmpty)
    }
    XCTAssertEqual(DashLoaderProtocol.captured.count, 1)
  }

  func testVirtualManifestRangesClampHugeLengthAndUseCurrentOffset() throws {
    let data = mpd
    let prepared = try prepare(DashLoaderProtocol.configuration { $0.respond(data) })
    defer { prepared.discard() }
    let full = read(prepared.loader, prepared.asset.url).received
    for (offset, length) in [(4, 5), (7, Int.max), (full.count + 9, 5)] {
      let request = DashLoadingRequest(prepared.asset.url)
      request.requestedOffset = 2; request.currentOffset = Int64(offset); request.requestedLength = length; request.requestsAllDataToEnd = false
      prepared.loader.startLoading(request)
      let expected = Data(full.dropFirst(min(offset, full.count)).prefix(length))
      XCTAssertEqual(request.received, expected); XCTAssertNil(request.error)
      XCTAssertEqual(request.contentLength, Int64(full.count)); XCTAssertEqual(request.finishCount, 1)
    }
    XCTAssertEqual(DashLoaderProtocol.captured.count, 1)
  }

  func testCandidateDiscardDoesNotCancelTransferredSessionAndNamespacesDiffer() throws {
    let data = mpd
    let config = DashLoaderProtocol.configuration { $0.respond(data) }
    let active = try prepare(config)
    let retained = try active.takeLoader()
    defer { retained.cancelAll() }
    let candidate = try prepare(config)
    XCTAssertNotEqual(active.asset.url, candidate.asset.url)
    candidate.discard(); active.discard()
    XCTAssertEqual(read(candidate.loader, candidate.asset.url).error?.code, "network.cancelled")
    XCTAssertNil(read(retained, active.asset.url).error)
    XCTAssertThrowsError(try active.takeLoader())
    retained.cancelAll()
    XCTAssertEqual(read(retained, active.asset.url).error?.code, "network.cancelled")
  }

  func testRoot403IsSafeAndMalformedOrOversizedMPDFailBeforeAsset() throws {
    for scenario in ["403", "invalid", "declared-limit", "stream-limit"] {
      let config = DashLoaderProtocol.configuration { source in
        switch scenario {
        case "403": source.respond(Data("secret signed-url".utf8), status: 403)
        case "declared-limit": source.respond(Data(), headers: ["Content-Length": String(2 * 1024 * 1024 + 1)])
        case "stream-limit": source.respond(Data(repeating: 32, count: 2 * 1024 * 1024 + 1))
        default: source.respond(Data("<MPD>secret signed-url".utf8))
        }
      }
      XCTAssertThrowsError(try prepare(config)) { error in
        let native = error as? NativePlayerError
        XCTAssertEqual(native?.code, scenario == "403" ? "network.http_forbidden" : scenario.contains("limit") ? "resource.dash_manifest_too_large" : "container.unsupported")
        XCTAssertFalse(String(describing: native).contains("secret"))
        XCTAssertFalse(String(describing: native).contains("signed-url"))
      }
    }
  }

  func testPreflightCancellationUnblocksAndCannotPublishLateAsset() {
    let started = expectation(description: "MPD request")
    let complete = expectation(description: "cancelled preparation")
    let token = YlOpenCancellationToken()
    let config = DashLoaderProtocol.configuration { _ in started.fulfill() }
    DispatchQueue.global().async {
      do { _ = try self.prepare(config, token: token); XCTFail("Cancelled preflight must fail") }
      catch { XCTAssertEqual((error as? NativePlayerError)?.code, "network.cancelled") }
      complete.fulfill()
    }
    wait(for: [started], timeout: 2)
    token.cancel()
    wait(for: [complete], timeout: 2)
    XCTAssertEqual(DashLoaderProtocol.captured.count, 1)
  }

  func testRecreatedLoaderRetainsStrippingWithoutStrippingSyntheticOrigin() throws {
    let data = mpd
    let context = YlHlsCredentialContext()
    context.strip(origin.absoluteString)
    context.strip("https://origin.test/root/init.mp4")
    let prepared = try prepare(DashLoaderProtocol.configuration { source in
      XCTAssertNil(source.request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertEqual(source.request.value(forHTTPHeaderField: "X-Client"), "ordinary")
      source.respond(data)
    }, context: context, headers: ["Authorization": "secret", "X-Client": "ordinary"])
    defer { prepared.discard() }
    let master = read(prepared.loader, prepared.asset.url)
    let video = read(prepared.loader, try child(master.received))
    XCTAssertEqual(String(decoding: video.received, as: UTF8.self).components(separatedBy: "credentialsStripped=1").count - 1, 3)
    XCTAssertTrue(context.isStripped("https://origin.test/root/seg-2.m4s"))
    XCTAssertFalse(context.isStripped(try YlHlsURLCodec.decode(prepared.asset.url).absoluteString))
  }

  func testLargeExpandedRegistryFailsAndReleasesLoaderRetention() throws {
    let ledger = YlManagedBufferLedger()
    // Small MPD expands to a playlist well beyond the 2 MiB/4 MiB registry
    // bounds once every real resource has a loopback proxy address.
    let data = Data(String(decoding: mpd, as: UTF8.self).replacingOccurrences(of: "PT4S", with: "PT100000S").replacingOccurrences(of: "duration=\"2\"", with: "duration=\"1\"").utf8)
    try autoreleasepool {
      XCTAssertThrowsError(try prepare(DashLoaderProtocol.configuration { $0.respond(data) }, readTimeoutMs: 15_000, retention: ledger.acquireOpaqueHlsRetention())) { error in
        XCTAssertEqual((error as? NativePlayerError)?.code, "container.unsupported")
      }
    }
    let deadline = Date().addingTimeInterval(3)
    var scope: YlManagedBufferScope?
    while scope == nil && Date() < deadline {
      scope = try? ledger.makeScope(maxBytes: 1024)
      if scope == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    XCTAssertNotNil(scope, "Failed compilation must release its opaque retention")
  }

  func testDiscardReleasesPrivateRegistryLoaderAndOpaqueRetention() throws {
    let data = mpd
    let ledger = YlManagedBufferLedger()
    weak var loader: YlHlsResourceLoader?
    try autoreleasepool {
      let prepared = try prepare(DashLoaderProtocol.configuration { $0.respond(data) }, retention: ledger.acquireOpaqueHlsRetention())
      loader = prepared.loader
      XCTAssertThrowsError(try ledger.makeScope(maxBytes: 1024))
      prepared.discard()
    }
    let deadline = Date().addingTimeInterval(3)
    while loader != nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    XCTAssertNil(loader)
    XCTAssertNoThrow(try ledger.makeScope(maxBytes: 1024))
  }

  func testActualMPDRedirectCrossOriginReturnAndProxyRangesNeverRestoreCredentials() throws {
    let data = mpd
    let other = try DashHTTPServer()
    let server = try DashHTTPServer()
    defer { server.close(); other.close() }
    other.handler = { _ in (302, ["Location": server.url("/final/movie.mpd").absoluteString], Data()) }
    server.handler = { request in
      if request.path == "/root.mpd" { return (302, ["Location": other.url("/hop").absoluteString], Data()) }
      if request.path == "/final/movie.mpd" { return (200, [:], data) }
      if request.headers["range"] == "bytes=2-4" { return (206, ["Content-Range": "bytes 2-4/6"], Data([2, 3, 4])) }
      return (200, [:], Data([0, 1, 2, 3, 4, 5]))
    }
    let context = YlHlsCredentialContext()
    func prepareNetwork() throws -> YlPreparedHlsAsset {
      try YlPreparedHlsAsset(originURL: server.url("/root.mpd"), isDash: true,
        headers: ["Authorization": "secret", "Cookie": "secret", "X-Client": "ordinary"], credentials: ["X-Session": "private"],
        configuration: .init(map: [:]), cancellationToken: .init(), credentialContext: context)
    }
    let prepared = try prepareNetwork()
    defer { prepared.discard() }
    let master = read(prepared.loader, prepared.asset.url)
    let video = read(prepared.loader, try child(master.received))
    let text = String(decoding: video.received, as: UTF8.self)
    let mapLine = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("#EXT-X-MAP:") })
    let initURL = try XCTUnwrap(mapLine.split(separator: "\"").dropFirst().first.flatMap { URL(string: String($0)) })
    let mediaURL = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("http:") }.flatMap { URL(string: String($0)) })
    for url in [initURL, mediaURL] {
      let done = expectation(description: "proxied range")
      var request = URLRequest(url: url); request.setValue("bytes=2-4", forHTTPHeaderField: "Range")
      URLSession.shared.dataTask(with: request) { body, response, error in
        XCTAssertNil(error); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(body, Data([2, 3, 4])); done.fulfill()
      }.resume()
      wait(for: [done], timeout: 4)
    }
    XCTAssertEqual(server.requests.first?.headers["authorization"], "secret")
    XCTAssertEqual(server.requests.first?.headers["x-session"], "private")
    let descendants = Array(server.requests.dropFirst()) + other.requests
    XCTAssertTrue(descendants.contains { $0.path == "/final/init.mp4" })
    XCTAssertTrue(descendants.contains { $0.path == "/final/seg-1.m4s" })
    for request in descendants {
      XCTAssertNil(request.headers["authorization"]); XCTAssertNil(request.headers["cookie"])
      XCTAssertNil(request.headers["x-session"]); XCTAssertEqual(request.headers["x-client"], "ordinary")
    }
    XCTAssertTrue(context.isStripped(server.url("/root.mpd").absoluteString))
    XCTAssertTrue(context.isStripped(server.url("/final/init.mp4").absoluteString))
    let restored = try prepareNetwork(); defer { restored.discard() }
    XCTAssertNil(server.requests.last { $0.path == "/root.mpd" }?.headers["authorization"])
    XCTAssertNotEqual(prepared.asset.url, restored.asset.url)
  }

  @MainActor
  func testInactiveBackendCannotRegainPlaybackIntentFromDelayedPlayerRate() throws {
    let player = ResidualRatePlayer()
    let backend = YlAvPlayerBackend(playerId: 94,
      services: .init(platform: .current, textureOutput: AppleTestTexture(),
        makeDisplayDriver: { AppleClockDisplay(onTick: $0) }),
      configuration: PlayerConfiguration(map: ["audioPolicy": "appManaged"]), player: player, emit: { _ in })
    defer { backend.dispose() }
    try backend.activate()
    player.rate = 1
    XCTAssertTrue(backend.playbackIntent)
    backend.deactivate()
    XCTAssertFalse(backend.isActive)
    XCTAssertEqual(player.rate, 1, "Models a late native rate observation after pause/deactivation")
    XCTAssertFalse(backend.playbackIntent, "An inactive backend cannot regain intent from retired native output")
  }

  @MainActor
  func testActiveDashPlayDoesNotRefetchOrCancelPendingCandidate() async throws {
    try await assertActivePlayPreservesPendingCandidate(format: .dash)
  }

  @MainActor
  func testActiveHeaderedHlsPlayDoesNotRefetchOrCancelPendingCandidate() async throws {
    try await assertActivePlayPreservesPendingCandidate(format: .hls)
  }

  @MainActor
  private func assertActivePlayPreservesPendingCandidate(format: AppleMediaFormat) async throws {
    let data = format == .dash ? mpd : Data("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n".utf8)
    let goodPath = format == .dash ? "/good.mpd" : "/good.m3u8"
    let held = expectation(description: "malformed candidate response held")
    let release = DispatchSemaphore(value: 0); defer { release.signal() }
    let server = try DashHTTPServer(); defer { server.close() }
    server.handler = { request in
      if request.path == goodPath { return (200, ["Content-Type": format == .dash ? "application/dash+xml" : "application/vnd.apple.mpegurl"], data) }
      if request.path == "/candidate.mpd" {
        held.fulfill(); _ = release.wait(timeout: .now() + 8)
        return (200, [:], Data("<MPD type=\"dynamic\"/>".utf8))
      }
      return (404, [:], Data())
    }
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    var source = AppleHostFixture.request("accepted", url: server.url(goodPath).absoluteString, format: format)
    source.source.request = .init(headers: ["X-Client": "ordinary"], credentials: ["X-Session": "private"])
    let accepted = try await fixture.host.load(request: source)
    let item = try XCTUnwrap(fixture.av.currentItem)
    let asset = try XCTUnwrap(item.asset as? AVURLAsset)
    let originalLoader = try XCTUnwrap(asset.resourceLoader.delegate as? YlHlsResourceLoader)
    XCTAssertTrue(fixture.host.isActive)
    let pending = Task { try await fixture.host.load(request: AppleHostFixture.request("candidate", url: server.url("/candidate.mpd").absoluteString, format: .dash)) }
    await fulfillment(of: [held], timeout: 3)
    try fixture.host.pause(command: .init(sessionId: accepted.sessionId))
    try await fixture.host.play(command: .init(sessionId: accepted.sessionId))
    XCTAssertEqual(fixture.host.sessionId, accepted.sessionId)
    XCTAssertTrue(fixture.av.currentItem === item, "Active play must keep the accepted item")
    XCTAssertEqual(server.requests.filter { $0.path == goodPath }.count, 1, "Active play cannot refetch the accepted source")
    release.signal()
    do { _ = try await pending.value; XCTFail("Malformed candidate committed") }
    catch let error as PigeonError { XCTAssertEqual(error.code, "container.unsupported", "Accepted-session controls must not supersede a pending Load") }
    try fixture.host.pause(command: .init(sessionId: accepted.sessionId))
    try await fixture.host.play(command: .init(sessionId: accepted.sessionId))
    XCTAssertTrue(fixture.av.currentItem === item)
    XCTAssertEqual(server.requests.filter { $0.path == goodPath }.count, 1)
    fixture.host.suspend(); fixture.host.resume()
    try await AppleHostCharacterizations.waitFor { fixture.host.isActive && fixture.av.currentItem != nil && fixture.av.currentItem !== item }
    let restored = try XCTUnwrap((fixture.av.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegate as? YlHlsResourceLoader)
    XCTAssertFalse(originalLoader === restored)
    XCTAssertTrue(originalLoader.credentialContext === restored.credentialContext)
    XCTAssertEqual(server.requests.filter { $0.path == goodPath }.count, 2, "Inactive resume must rebuild exactly once")
    XCTAssertEqual(fixture.host.sessionId, accepted.sessionId)
  }

  @MainActor
  func testStopDuringMPDPreflightAllowsNewLoadAndIgnoresLateResponse() async throws {
    let data = mpd
    let held = expectation(description: "MPD response held")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let server = try DashHTTPServer(); defer { server.close() }
    server.handler = { request in
      if request.path == "/held.mpd" { held.fulfill(); _ = release.wait(timeout: .now() + 6) }
      return (200, [:], data)
    }
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    let pending = Task { try await fixture.host.load(request: AppleHostFixture.request("held", url: server.url("/held.mpd").absoluteString, format: .dash)) }
    await fulfillment(of: [held], timeout: 3)
    try await fixture.host.stop()
    do { _ = try await pending.value; XCTFail("Stopped MPD committed") }
    catch let error as PigeonError { XCTAssertEqual(error.code, "network.cancelled") }
    XCTAssertNil(fixture.host.sessionId)
    let fresh = try await fixture.host.load(request: AppleHostFixture.request("fresh", url: server.url("/fresh.mpd").absoluteString, format: .dash))
    let current = fixture.av.currentItem
    release.signal()
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(fixture.host.sessionId, fresh.sessionId)
    XCTAssertTrue(fixture.av.currentItem === current)
  }

  @MainActor
  func testCoordinatorKeepsDashSessionOnInvalidReplacementAndRebuildsPrivateAssetOnResume() async throws {
    let data = mpd
    let server = try DashHTTPServer(); defer { server.close() }
    server.handler = { request in
      if request.path == "/good.mpd" { return (200, [:], data) }
      if request.path == "/bad.mpd" { return (200, [:], Data("<MPD type=\"dynamic\"/>".utf8)) }
      return (404, [:], Data())
    }
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    let accepted = try await fixture.host.load(request: AppleHostFixture.request("dash", url: server.url("/good.mpd").absoluteString, format: .dash))
    let item = try XCTUnwrap(fixture.av.currentItem)
    let originalPrivateURL = try XCTUnwrap((item.asset as? AVURLAsset)?.url)
    XCTAssertNotEqual(try YlHlsURLCodec.decode(originalPrivateURL), server.url("/good.mpd"))
    do { _ = try await fixture.host.load(request: AppleHostFixture.request("bad", url: server.url("/bad.mpd").absoluteString, format: .dash)); XCTFail("Invalid DASH committed") }
    catch let error as PigeonError { XCTAssertEqual(error.code, "container.unsupported") }
    XCTAssertEqual(fixture.host.sessionId, accepted.sessionId)
    XCTAssertTrue(fixture.av.currentItem === item)
    fixture.host.suspend(); fixture.host.resume()
    try await AppleHostCharacterizations.waitFor { fixture.av.currentItem != nil && fixture.av.currentItem !== item }
    let restoredURL = try XCTUnwrap((fixture.av.currentItem?.asset as? AVURLAsset)?.url)
    XCTAssertNotEqual(originalPrivateURL, restoredURL)
    XCTAssertEqual(try YlHlsURLCodec.resourceKind(restoredURL), .manifest)
    XCTAssertEqual(fixture.host.sessionId, accepted.sessionId)
    XCTAssertEqual(server.requests.filter { $0.path == "/good.mpd" }.count, 2)
    try await fixture.host.stop()
    XCTAssertNil(fixture.av.currentItem); XCTAssertNil(fixture.host.sessionId)
  }

  func testCrossOriginBaseURLReturnSeedsStickyContext() throws {
    let data = Data("""
      <MPD type="static" mediaPresentationDuration="PT4S"><BaseURL>https://foreign.test/</BaseURL><Period><BaseURL>https://origin.test/returned/</BaseURL><AdaptationSet mimeType="video/mp4"><Representation id="v" bandwidth="1000" codecs="avc1.64001f" width="320" height="180"><SegmentTemplate initialization="init.mp4" media="seg-$Number$.m4s" duration="2"/></Representation></AdaptationSet></Period></MPD>
      """.utf8)
    let context = YlHlsCredentialContext()
    let prepared = try prepare(DashLoaderProtocol.configuration { $0.respond(data) }, context: context, headers: ["Authorization": "secret", "X-Client": "ordinary"])
    defer { prepared.discard() }
    XCTAssertTrue(context.isStripped("https://origin.test/returned/init.mp4"))
    XCTAssertTrue(context.isStripped("https://origin.test/returned/seg-1.m4s"))
    XCTAssertEqual(DashLoaderProtocol.captured.first?.value(forHTTPHeaderField: "Authorization"), "secret")
    XCTAssertEqual(DashLoaderProtocol.captured.first?.value(forHTTPHeaderField: "X-Client"), "ordinary")
    XCTAssertFalse(context.isStripped(try YlHlsURLCodec.decode(prepared.asset.url).absoluteString))
  }
}

private final class DashHTTPServer {
  struct Request { let path: String; let headers: [String: String] }
  typealias Response = (Int, [String: String], Data)
  private let listener: NWListener
  private let lock = NSLock()
  private var log: [Request] = []
  private var responseHandler: ((Request) -> Response)?
  var handler: ((Request) -> Response)? {
    get { lock.lock(); defer { lock.unlock() }; return responseHandler }
    set { lock.lock(); responseHandler = newValue; lock.unlock() }
  }
  var requests: [Request] { lock.lock(); defer { lock.unlock() }; return log }
  func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")! }
  init() throws {
    listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { [weak self] connection in
      connection.start(queue: DispatchQueue.global())
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
        guard let self, let data, !data.isEmpty else { connection.cancel(); return }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        let path = lines[0].split(separator: " ").dropFirst().first.map(String.init) ?? ""
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
          guard let colon = line.firstIndex(of: ":") else { continue }
          headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = Request(path: path, headers: headers)
        self.lock.lock(); self.log.append(request); let handler = self.responseHandler; self.lock.unlock()
        let (status, extra, body) = handler?(request) ?? (404, [:], Data())
        var header = "HTTP/1.1 \(status) Response\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (key, value) in extra { header += "\(key): \(value)\r\n" }
        connection.send(content: Data((header + "\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
      }
    }
    listener.start(queue: DispatchQueue(label: "yl.test.dash.http"))
    guard ready.wait(timeout: .now() + 3) == .success else { listener.cancel(); throw NSError(domain: "DashTestServer", code: 1) }
  }
  func close() { handler = nil; listener.cancel() }
  deinit { close() }
}

/// Records the URLSession admission/invalidation contract without triggering
/// Foundation's fatal Objective-C exception on the intentionally broken path.
private final class AdmissionRecordingSession: URLSession, @unchecked Sendable {
  let releaseCreation = DispatchSemaphore(value: 0)
  let cancellationRequested = DispatchSemaphore(value: 0)
  let invalidated = DispatchSemaphore(value: 0)
  private let entered: XCTestExpectation
  private let eventLock = NSLock()
  private var recorded: [String] = []
  private lazy var recordedTask = AdmissionRecordingTask { [weak self] in self?.record($0) }
  var events: [String] { eventLock.lock(); defer { eventLock.unlock() }; return recorded }
  init(entered: XCTestExpectation) { self.entered = entered; super.init() }
  private func record(_ event: String) { eventLock.lock(); recorded.append(event); eventLock.unlock() }
  func requestCancellation() { record("cancel.request"); cancellationRequested.signal() }
  override func dataTask(with request: URLRequest) -> URLSessionDataTask {
    record("create.enter"); entered.fulfill()
    if releaseCreation.wait(timeout: .now() + 4) != .success { record("gate.timeout") }
    record("create.return")
    return recordedTask
  }
  override func invalidateAndCancel() {
    record("invalidate"); recordedTask.cancel(); invalidated.signal()
  }
}

private final class AdmissionRecordingTask: URLSessionDataTask, @unchecked Sendable {
  private let record: (String) -> Void
  init(record: @escaping (String) -> Void) { self.record = record; super.init() }
  override var taskIdentifier: Int { 42 }
  override func resume() { record("resume") }
  override func cancel() { record("cancel") }
}

/// Native rate callbacks can lag the command that retired an item. Keep that
/// observation nonzero deterministically while exercising real backend state.
private final class ResidualRatePlayer: AVPlayer {
  private var observedRate: Float = 0
  override var rate: Float {
    get { observedRate }
    set { observedRate = newValue }
  }
  override func pause() {}
}
