from pathlib import Path
import sys
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift')
s=p.read_text();marker='  @MainActor func testHeldBodyServerHandlesSplitHeadersAndContinuesUntilPeerEOF()'
new='''  @MainActor func testCommittedMediaFailureRetainsCredentialHistoryThroughRestorationAndFreshLoad() async throws {
    let server = try DashHTTPServer(), other = try DashHTTPServer(), data = mpd
    defer { server.close(); other.close() }
    server.handler = { request in
      if request.path == "/movie.mpd" { return (200,["Content-Type":"application/dash+xml"],data) }
      if request.path == "/init.mp4" { return (302,["Location":other.url("/hop").absoluteString],Data()) }
      return (410,["Content-Type":"video/mp4"],Data())
    }
    other.handler = { _ in (302,["Location":server.url("/gone.mp4").absoluteString],Data()) }
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    try fixture.host.attach()
    func request(_ id:String,_ secret:String) -> AppleLoadRequest {
      var value = AppleHostFixture.request(id,url:server.url("/movie.mpd").absoluteString,format:.dash)
      value.source.request = .init(headers:["X-Client":"ordinary"],credentials:["Authorization":secret,"Cookie":secret,"X-Session":secret])
      return value
    }
    func loader() throws -> YlHlsResourceLoader {
      try XCTUnwrap((fixture.av.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegate as? YlHlsResourceLoader)
    }
    func initURL(_ loader:YlHlsResourceLoader) throws -> URL {
      let root = read(loader,try loader.encodedAssetURL()), video = read(loader,try child(root.received))
      let line = try XCTUnwrap(String(decoding:video.received,as:UTF8.self).split(separator:"\\n").first { $0.hasPrefix("#EXT-X-MAP:") })
      return try XCTUnwrap(line.split(separator:"\\\"").dropFirst().first.flatMap { URL(string:String($0)) })
    }
    // A successful Load reply acknowledges installation, not asynchronous media readiness.
    let accepted = try await fixture.host.load(request:request("failing","first-fixture"))
    let failedItem = try XCTUnwrap(fixture.av.currentItem), failedLoader = try loader()
    try await AppleHostCharacterizations.waitFor({ failedItem.status == .failed && fixture.callbacks.failures.contains { $0.sessionId == accepted.sessionId } },timeout:5)
    XCTAssertEqual(fixture.host.sessionId,accepted.sessionId)
    XCTAssertTrue(fixture.av.currentItem === failedItem)
    XCTAssertTrue(failedLoader.credentialContext.isStripped(server.url("/init.mp4").absoluteString))
    let failure = try XCTUnwrap(fixture.callbacks.failures.first { $0.sessionId == accepted.sessionId })
    XCTAssertEqual(failure.loadRequestId,"failing")
    let revision = failedLoader.credentialContext.revision
    fixture.host.suspend(); fixture.host.resume()
    try await AppleHostCharacterizations.waitFor { fixture.av.currentItem != nil && fixture.av.currentItem !== failedItem }
    let restored = try loader()
    XCTAssertEqual(fixture.host.sessionId,accepted.sessionId)
    XCTAssertTrue(restored.credentialContext === failedLoader.credentialContext)
    // Distinguish this evidence request from AVPlayer read-ahead and retries.
    var probe = URLRequest(url:try initURL(restored)); probe.setValue("bytes=1-2",forHTTPHeaderField:"Range")
    let (_,response) = try await URLSession.shared.data(for:probe)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,410)
    let retried = try XCTUnwrap(server.requests.last { $0.path == "/init.mp4" && $0.headers["range"] == "bytes=1-2" })
    for key in ["authorization","cookie","x-session"] { XCTAssertNil(retried.headers[key]) }
    XCTAssertEqual(retried.headers["x-client"],"ordinary")
    XCTAssertEqual(restored.credentialContext.revision,revision)
    let fresh = try await fixture.host.load(request:request("fresh","second-fixture"))
    let freshLoader = try loader()
    XCTAssertNotEqual(fresh.sessionId,accepted.sessionId)
    XCTAssertFalse(freshLoader.credentialContext === failedLoader.credentialContext)
    try await AppleHostCharacterizations.waitFor { server.requests.contains { $0.path == "/init.mp4" && $0.headers["authorization"] == "second-fixture" } }
    let sent = try XCTUnwrap(server.requests.first { $0.path == "/init.mp4" && $0.headers["authorization"] == "second-fixture" })
    XCTAssertEqual(sent.headers["cookie"],"second-fixture"); XCTAssertEqual(sent.headers["x-session"],"second-fixture")
    XCTAssertThrowsError(try fixture.host.pause(command:.init(sessionId:accepted.sessionId)))
    XCTAssertEqual(failedLoader.diagnosticProxySnapshot["cancelled"],1)
    XCTAssertEqual(restored.diagnosticProxySnapshot["cancelled"],1)
    XCTAssertEqual(failedLoader.credentialContext.revision,revision)
    for r in other.requests + server.requests.filter({ $0.path == "/gone.mp4" }) {
      for key in ["authorization","cookie","x-session"] { XCTAssertNil(r.headers[key]) }
    }
  }

'''
assert marker in s;p.write_text(s.replace(marker,new+marker))
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:Path(f'packages/yl_player/example/{platform}/RunnerTests/YlDashResourceLoaderTests.swift').write_bytes(native_test_source(p))
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');p.write_text(p.read_text().replace("{'ios': 850, 'macos': 894}","{'ios': 851, 'macos': 895}"))
Path('docs/superpowers/plans/2026-10-28-ios-postcommit-failure.md').write_text('''# iOS 提交后媒体失败的凭据生命周期

基线90be00d1；继续既有授权与集中验收策略，不发布。复用当前隔离工作树。Goal：补齐成功Load回复之后真实媒体失败、恢复、再次Load的凭据边界。Architecture：真实typed native host、AVPlayer与受控双源HTTP；源码无已确认缺陷时不修改生产逻辑。Tech Stack：Swift/XCTest/AVFoundation。Spec：上一轮ios-load-lifecycle报告剩余边界。

- [ ] 在canonical YlDashResourceLoaderTests新增真实HTTP410造成item失败的测试，双平台镜像同步。
- [ ] 验证原会话失败事件身份、恢复沿用剥离上下文、新Load使用独立上下文及旧session失效；若有失败先定位再修复。
- [ ] 最终受影响原生双平台、消费者镜像/来源与台账集中检查，一次独立复审，完整保留失败。

不改变2秒准备/5秒票据/双8秒窗/955000bit/s/2次预算/500与1000ms退避。此失败观察5秒为新合约等待上限，不改变ABR门槛。不冒充Dart桥接、长素材高档或音画连续性；不要求失败后自动回滚旧会话，公开Load已完成提交。
''')
