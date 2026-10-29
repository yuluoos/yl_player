from pathlib import Path
r=Path('/private/tmp/yl-request-timing');old=Path('/private/tmp/yl-resume-timeout')
for name in ['run.py','qualified-device.py','local.py','readiness.py']:
 (r/name).write_text((old/name).read_text().replace('/private/tmp/yl-resume-timeout','/private/tmp/yl-request-timing'))
p=Path('docs/superpowers/plans/2026-10-29-ios-request-timing.md');p.write_text('''# iOS 请求级上游与回环边界

基线91ecf8f9，继续既有工作树和集中验收，不发布。

DEBUG显式探针启用请求级观测；默认无事件、无全局事件历史。每个请求一次终止记录，包含单调时钟边界、字节/发送计数、取消/错误结果。随机代理标识与数字请求编号关联测试服务器，禁止URL、凭据和任意头值进入日志。采集器独立保存，严格校验有界、丢失、重复和错误数据；观测不修改生产触发、退避或门槛。

- [ ] 原生请求边界合约红绿、隐私/取消/迟到边界及采集导出。
- [ ] 请求ID关联与离线逐请求诊断、定向回归。
- [ ] 最终原生矩阵及原配置/单变量对照真机采集，依据证据修复能确认的问题。
- [ ] 独立综合复审、完整失败与结果归档、台账核对，缺设备/授权项继续保留。
''')
p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsMediaProxy.swift');s=p.read_text();mark='  // Numeric, per-proxy debug observations only.';s=s.replace(mark,'  static var diagnosticRequestObserver: (([String: Any]) -> Void)?\n'+mark);p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();mark='  func testProxyBoundarySnapshotTracksRealRequestAndCancellationWithoutResourceIdentity() throws {'
test='''  func testProxyRequestTimingCorrelatesOwnedServerWithoutResourceIdentity() throws {
    let server = try DashHTTPServer(); defer { server.close() }
    server.handler = { _ in (200, ["X-Yl-Request-Id": "17"], Data([1, 2, 3, 4])) }
    let boundary = expectation(description: "one request boundary")
    let capturedLock = NSLock()
    var captured: [[String: Any]] = []
    YlHlsMediaProxy.diagnosticRequestObserver = { row in
      capturedLock.withLock { captured.append(row) }; boundary.fulfill()
    }
    defer { YlHlsMediaProxy.diagnosticRequestObserver = nil }
    let proxy = try YlHlsMediaProxy(originURL: server.url("/private?token=secret"),
      headers: ["Authorization": "secret"], configuration: .init(map: [:]))
    defer { proxy.cancelAll() }
    let bodyDone = expectation(description: "proxied body")
    URLSession.shared.dataTask(with: try proxy.proxyURL(for: server.url("/private?token=secret"))) { body, _, error in
      XCTAssertNil(error); XCTAssertEqual(body, Data([1, 2, 3, 4])); bodyDone.fulfill()
    }.resume()
    wait(for: [bodyDone, boundary], timeout: 4)
    let rows = capturedLock.withLock { captured }
    XCTAssertEqual(rows.count, 1)
    guard let row = rows.first else { return }
    XCTAssertEqual(row["serverRequestID"] as? Double, 17)
    XCTAssertEqual(row["bodyBytes"] as? Double, 4)
    XCTAssertEqual(row["sentBodyBytes"] as? Double, 4)
    XCTAssertEqual(row["outcome"] as? Double, 0)
    for (before, after) in [("admission", "response"), ("response", "firstBody"),
      ("firstBody", "lastBody"), ("lastBody", "upstreamComplete"),
      ("lastSendComplete", "terminal"), ("upstreamComplete", "terminal")] {
      XCTAssertLessThanOrEqual(try XCTUnwrap(row[before] as? Double), try XCTUnwrap(row[after] as? Double))
    }
    let serialized = String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self)
    for secret in ["secret", "private", "Authorization", "http:"] { XCTAssertFalse(serialized.contains(secret)) }
    proxy.cancelAll()
    XCTAssertEqual(capturedLock.withLock { captured.count }, 1)
  }

''';assert mark in s;s=s.replace(mark,test+mark);p.write_text(s)
