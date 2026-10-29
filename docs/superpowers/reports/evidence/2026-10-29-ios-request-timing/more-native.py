from pathlib import Path
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();mark='  func testProxyRequestTimingSealsCancellationAndIgnoresLateSendCompletion() {'
s=s.replace(mark,'''  func testProxyRequestTimingRecordsRealCancellationBeforeUpstreamResponse() throws {
    let server = try DashHTTPServer(); defer { server.close() }
    let entered = expectation(description: "upstream entered")
    let release = DispatchSemaphore(value: 0); defer { release.signal() }
    server.handler = { _ in
      entered.fulfill(); _ = release.wait(timeout: .now() + 4)
      return (200, ["X-Yl-Request-Id": "18"], Data([1, 2]))
    }
    let capturedLock = NSLock(); var captured: [[String: Any]] = []
    YlHlsMediaProxy.diagnosticRequestObserver = { row in capturedLock.withLock { captured.append(row) } }
    defer { YlHlsMediaProxy.diagnosticRequestObserver = nil }
    let proxy = try YlHlsMediaProxy(originURL: server.url("/media"), headers: [:], configuration: .init(map: [:]))
    defer { proxy.cancelAll() }
    let done = expectation(description: "cancelled downstream")
    URLSession.shared.dataTask(with: try proxy.proxyURL(for: server.url("/media"))) { _, _, error in
      XCTAssertNotNil(error); done.fulfill()
    }.resume()
    wait(for: [entered], timeout: 3)
    proxy.cancelAll(); release.signal()
    wait(for: [done], timeout: 3)
    let rows = capturedLock.withLock { captured }
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?["outcome"] as? Double, 1)
    XCTAssertNil(rows.first?["response"])
    XCTAssertNil(rows.first?["upstreamComplete"])
  }

'''+mark);p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');p.write_text(p.read_text().replace("'ios': 872, 'macos': 916","'ios': 873, 'macos': 917"))
p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsMediaProxy.swift');s=p.read_text().replace('record.trace?.finish(outcome: error == nil ? 0 : 2)','record.trace?.finish(outcome: error != nil ? 2 : (record.reportedFailure == nil ? 0 : 3))');p.write_text(s)
