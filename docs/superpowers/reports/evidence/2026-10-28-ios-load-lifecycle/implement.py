from pathlib import Path
import sys
p=Path('docs/superpowers/plans/2026-10-28-ios-load-lifecycle.md');p.write_text('''# iOS 公开Load凭据生命周期与同候选网络取消

基线6b699713。继续已有授权，系统排障/集中验收，不发布。原2秒准备、5秒票据、双8秒窗、955000bit/s、2次预算、500/1000ms退避均不改动。

- [ ] typed public load：旧Load代理实际跨源剥离；失败的新Load保留原session/context；成功新Load使用独立context并发送新Load自己的凭据，旧loader取消。
- [ ] 同一个DASH AVPlayer候选收到上游部分媒体数据后发生真实跨源剥离，原票据失效，候选detach/discard、实际上游任务/连接结束，预算不退款，已提交loader仍可读。
- [ ] 若现有实现正确，仅补齐可重复验收；发现问题先复现后修复。最终受影响原生双平台、镜像/夹具、台账统一验证，一次独立复审，保留完整失败。

范围：原生public API，不冒充Dart桥接或长素材ABR高档/物理连续性。测试服务器只使用固定合成凭据，不修改生产行为或原阈值。
''')
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();marker='  func testActualMPDRedirectCrossOriginReturnAndProxyRangesNeverRestoreCredentials() throws {'
t='''  @MainActor func testPublicLoadCredentialHistorySurvivesRollbackAndResetsOnlyOnCommit() async throws {
    let server = try DashHTTPServer(), other = try DashHTTPServer(), data = mpd
    defer { server.close(); other.close() }
    server.handler = { request in
      if request.path == "/movie.mpd" { return (200,[:],data) }
      if request.path == "/bad.mpd" { return (200,[:],Data("<MPD type=\\"dynamic\\"/>".utf8)) }
      if request.path == "/seg-1.m4s" { return (302,["Location":other.url("/hop").absoluteString],Data()) }
      return (200,[:],Data([1,2,3]))
    }
    other.handler = { _ in (302,["Location":server.url("/returned").absoluteString],Data()) }
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    func request(_ id:String,_ token:String,_ path:String = "/movie.mpd") -> AppleLoadRequestMessage {
      var request = AppleHostFixture.request(id,url:server.url(path).absoluteString,format:.dash)
      request.source.request = .init(headers:["X-Client":"ordinary"],credentials:["Authorization":token,"Cookie":token,"X-Session":token])
      return request
    }
    func loader() throws -> YlHlsResourceLoader {
      try XCTUnwrap((fixture.av.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegate as? YlHlsResourceLoader)
    }
    func segment(_ loader:YlHlsResourceLoader) throws -> URL {
      let root = read(loader,try loader.encodedAssetURL())
      let video = read(loader,try child(root.received))
      return try XCTUnwrap(String(decoding:video.received,as:UTF8.self).split(separator:"\\n").first { $0.hasPrefix("http:") }.flatMap { URL(string:String($0)) })
    }
    let first = try await fixture.host.load(request:request("first","first-fixture"))
    let oldItem = try XCTUnwrap(fixture.av.currentItem), oldLoader = try loader()
    let oldURL = try segment(oldLoader)
    let (_,response) = try await URLSession.shared.data(from:oldURL)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
    XCTAssertTrue(oldLoader.credentialContext.isStripped(server.url("/seg-1.m4s").absoluteString))
    let oldRevision = oldLoader.credentialContext.revision
    do { _ = try await fixture.host.load(request:request("failed","failed-fixture","/bad.mpd")); XCTFail("Malformed candidate committed") }
    catch let error as PigeonError { XCTAssertEqual(error.code,"container.dash_dynamic_unsupported") }
    XCTAssertEqual(fixture.host.sessionId,first.sessionId); XCTAssertTrue(fixture.av.currentItem === oldItem)
    XCTAssertTrue(try loader() === oldLoader)
    _ = try await URLSession.shared.data(from:oldURL)
    let afterRollback = try XCTUnwrap(server.requests.last { $0.path == "/seg-1.m4s" })
    XCTAssertNil(afterRollback.headers["authorization"]); XCTAssertNil(afterRollback.headers["cookie"])
    XCTAssertNil(afterRollback.headers["x-session"]); XCTAssertEqual(afterRollback.headers["x-client"],"ordinary")
    let second = try await fixture.host.load(request:request("second","second-fixture"))
    let newLoader = try loader()
    XCTAssertNotEqual(first.sessionId,second.sessionId)
    XCTAssertFalse(newLoader.credentialContext === oldLoader.credentialContext)
    XCTAssertEqual(newLoader.credentialContext.revision,0)
    _ = try await URLSession.shared.data(from:segment(newLoader))
    let afterCommit = try XCTUnwrap(server.requests.last { $0.path == "/seg-1.m4s" })
    XCTAssertEqual(afterCommit.headers["authorization"],"second-fixture")
    XCTAssertEqual(afterCommit.headers["cookie"],"second-fixture"); XCTAssertEqual(afterCommit.headers["x-session"],"second-fixture")
    XCTAssertEqual(oldLoader.credentialContext.revision,oldRevision)
    XCTAssertEqual(oldLoader.diagnosticProxySnapshot["cancelled"],1)
    for r in other.requests + server.requests.filter({ $0.path == "/returned" }) {
      XCTAssertNil(r.headers["authorization"]); XCTAssertNil(r.headers["cookie"]); XCTAssertNil(r.headers["x-session"])
    }
  }

  @MainActor func testSameDashCandidateRevocationCancelsPartiallyReceivedUpstream() async throws {
    let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL)
    let app = try XCTUnwrap(Bundle(url:frameworks.appendingPathComponent("App.framework")))
    let media = try XCTUnwrap(app.resourceURL).appendingPathComponent("flutter_assets/assets/test_media/dash_timeline/avc/init-0.m4s")
    let other = try DashHTTPServer(); other.handler = { _ in (200,[:],Data([1,2,3])) }
    let server = try DashHeldBodyServer(manifest:mpd,body:Data(contentsOf:media),redirect:other.url("/revoked"))
    defer { server.close(); other.close() }
    let context = YlHlsCredentialContext()
    let candidate = try AbrDiagnosticCandidatePreparation.prepareReplacement(originURL:server.url("/movie.mpd"),headers:[:],credentials:["Authorization":"fixture"],credentialContext:context)
    defer { candidate.discard() }
    let accepted = try AbrDiagnosticCandidatePreparation.prepareReplacement(originURL:server.url("/movie.mpd"),headers:[:],credentials:["Authorization":"fixture"],credentialContext:context)
    let active = try accepted.takeLoader(); defer { active.cancelAll() }
    let control = try YlHlsMediaProxy(originURL:server.url("/movie.mpd"),headers:[:],credentials:["Authorization":"fixture"],configuration:.init(map:[:]),credentialContext:context)
    defer { control.cancelAll() }
    var policy = AbrDiagnosticRecoveryPolicy()
    func sample(_ time:Double,width:Int = 320) -> AbrDiagnosticRecoveryPolicy.Sample {
      .init(time:time,generation:0,allowed:true,width:width,position:time,remaining:120-time,bufferAhead:10,
        bytes:Int64(time*200_000),transfer:time,requests:Int(time*4),overdue:1,credentialRevision:context.revision)
    }
    for (t,w) in [(0.0,640),(1.0,320),(9.0,320),(17.0,320)] { _ = policy.observe(sample(t,width:w)) }
    let ticket = try XCTUnwrap(policy.observe(sample(17.5))), epoch = ProcessInfo.processInfo.systemUptime
    var observedPartial = false, redirected = false, cleanup = 0
    let revoke = Task { @MainActor in
      do {
        try await AppleHostCharacterizations.waitFor({
          candidate.loader.diagnosticProxySnapshot["receivedBodyBytes",default:0]>0 &&
          candidate.loader.diagnosticProxySnapshot["activeTasks",default:0]>0
        },timeout:1.5)
        observedPartial = true
        let (_,response) = try await URLSession.shared.data(from:control.proxyURL(for:server.url("/revoke")))
        redirected = (response as? HTTPURLResponse)?.statusCode == 200
      } catch { XCTFail("Owned candidate did not reach partial upstream transfer and redirect") }
    }
    defer { revoke.cancel() }
    let result = await AbrDiagnosticPreroll.prepare(candidate.asset,position:.zero,deadlineUptime:epoch+2,
      allowed:{ policy.authorizes(ticket,sample(17.5+ProcessInfo.processInfo.systemUptime-epoch)) },
      cancelPending:{ cleanup += 1; candidate.discard() })
    await revoke.value
    XCTAssertTrue(observedPartial); XCTAssertTrue(redirected)
    XCTAssertEqual(result.outcome,"cancelled"); XCTAssertTrue(result.detached); XCTAssertNil(result.item)
    XCTAssertEqual(cleanup,1); XCTAssertEqual(policy.attempts,1)
    try await AppleHostCharacterizations.waitFor({
      let snap = candidate.loader.diagnosticProxySnapshot
      return snap["activeTasks"]==0 && snap["activeConnections"]==0 && snap["pendingSends"]==0 &&
        snap["cancelledCompletions",default:0]>0 && server.peerClosed>0
    },timeout:2)
    XCTAssertThrowsError(try candidate.takeLoader())
    XCTAssertNil(read(active,try active.encodedAssetURL()).error,"Cancelling candidate must not cancel committed loader")
    XCTAssertEqual(active.diagnosticProxySnapshot["cancelled"],0)
    XCTAssertFalse(policy.authorizes(ticket,sample(17.5+ProcessInfo.processInfo.systemUptime-epoch)))
    XCTAssertTrue(other.requests.allSatisfy { $0.headers["authorization"] == nil })
  }

'''
assert marker in s;s=s.replace(marker,t+marker,1)
# Dedicated fixture: completed HTTP headers plus a real fMP4 prefix; tail deliberately never sent.
s+='''
private final class DashHeldBodyServer {
  private let listener: NWListener
  private let lock = NSLock()
  private var connections: [NWConnection] = []
  private var closed = 0
  var peerClosed: Int { lock.lock(); defer { lock.unlock() }; return closed }
  func url(_ path:String) -> URL { URL(string:"http://127.0.0.1:\\(listener.port!.rawValue)\\(path)")! }
  init(manifest:Data,body:Data,redirect:URL) throws {
    listener = try NWListener(using:.tcp,on:.any)
    let ready = DispatchSemaphore(value:0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      self.lock.lock(); self.connections.append(connection); self.lock.unlock()
      connection.start(queue:DispatchQueue.global())
      connection.receive(minimumIncompleteLength:1,maximumLength:16384) { data,_,_,_ in
        guard let data else { connection.cancel(); return }
        let request = String(decoding:data,as:UTF8.self)
        let path = request.split(separator:" ").dropFirst().first.map(String.init) ?? ""
        if path == "/movie.mpd" {
          let header = "HTTP/1.1 200 OK\\r\\nContent-Length: \\(manifest.count)\\r\\nConnection: close\\r\\n\\r\\n"
          connection.send(content:Data(header.utf8)+manifest,completion:.contentProcessed { _ in connection.cancel() })
        } else if path == "/revoke" {
          connection.send(content:Data("HTTP/1.1 302 Found\\r\\nContent-Length: 0\\r\\nLocation: \\(redirect.absoluteString)\\r\\nConnection: close\\r\\n\\r\\n".utf8),completion:.contentProcessed { _ in connection.cancel() })
        } else {
          let header = "HTTP/1.1 200 OK\\r\\nContent-Type: video/mp4\\r\\nContent-Length: \\(body.count)\\r\\nConnection: close\\r\\n\\r\\n"
          connection.send(content:Data(header.utf8)+body.prefix(64),completion:.contentProcessed { _ in })
          connection.receive(minimumIncompleteLength:1,maximumLength:1024) { _,_,complete,error in
            if complete || error != nil { self.lock.lock(); self.closed += 1; self.lock.unlock(); connection.cancel() }
          }
        }
      }
    }
    listener.start(queue:DispatchQueue(label:"yl.test.held-body"))
    guard ready.wait(timeout:.now()+3) == .success else { listener.cancel(); throw NSError(domain:"HeldBody",code:1) }
  }
  func close() {
    listener.cancel(); lock.lock(); let pending = connections; connections.removeAll(); lock.unlock()
    pending.forEach { $0.cancel() }
  }
  deinit { close() }
}
''';p.write_text(s)
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path(f'packages/yl_player/example/{platform}/RunnerTests')/p.name).write_bytes(native_test_source(p))
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');p.write_text(p.read_text().replace("{'ios': 847, 'macos': 891}","{'ios': 849, 'macos': 893}"))
