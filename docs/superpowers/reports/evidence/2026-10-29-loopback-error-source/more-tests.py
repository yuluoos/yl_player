from pathlib import Path
p=Path('tool/playback_network/test_proxy_boundaries.py');s=p.read_text().replace("[{'proxyRequestSamplingVersion':7}]","[{'proxyRequestSamplingVersion':8}]");p.write_text(s)
p=Path('tool/playback_network/test_bandwidth_diagnostics.py');s=p.read_text();anchor='        policy=dict(elapsed=1';s=s.replace(anchor,'        proxy.update(version=7,cancelSource=0,cancelErrorDomain=0,cancelErrorCode=0)\n'+anchor).replace('dict(proxyRequestSamplingVersion=6)','dict(proxyRequestSamplingVersion=7)').replace("['proxy']['version'],6)","['proxy']['version'],7)");p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();anchor='  func testProxyRequestTimingSealsCancellationAndIgnoresLateSendCompletion() {'
tests='''  func testProxyErrorSourceFreezesBeforeLateCallbackAndTaskSettlement() throws {
    let cases: [(Int, NWError?, Int, Int)] = [
      (1, .posix(.ECONNRESET), 1, 54), (2, .dns(-65538), 2, -65538),
      (3, .tls(-9806), 3, -9806), (3, nil, 4, 0)
    ]
    for (source, error, domain, code) in cases {
      var rows: [[String: Any]] = []
      let trace = YlHlsProxyRequestTrace(proxyID: "test-proxy", requestID: 1,
        resourceToken: String(repeating: "a", count: 64)) { rows.append($0) }
      trace.attachTask(); trace.body(bytes: 8)
      trace.finish(outcome: 1, cancelCause: 3, cancelSource: source, error: error)
      trace.finish(outcome: 1, cancelCause: 3, cancelSource: 1, error: .posix(.EBADF))
      trace.finish(outcome: 0); trace.body(bytes: 20)
      XCTAssertTrue(rows.isEmpty)
      trace.taskCompleted(outcome: 1); trace.taskCompleted(outcome: 0)
      XCTAssertEqual(rows.count, 1)
      XCTAssertEqual(rows[0]["cancelSource"] as? Int, source)
      XCTAssertEqual(rows[0]["cancelErrorDomain"] as? Int, domain)
      XCTAssertEqual(rows[0]["cancelErrorCode"] as? Int, code)
      XCTAssertEqual(rows[0]["bodyBytes"] as? Double, 8)
      XCTAssertEqual(rows[0]["taskOutcome"] as? Int, 1)
      XCTAssertEqual(rows[0]["outcome"] as? Double, 1)
      XCTAssertEqual(Set(rows[0].keys).intersection(["error", "localizedDescription", "url"]), [])
    }
  }

  func testProxyResetRecordsRealLoopbackErrorAndReclaimsTask() throws {
    let server = try DashHTTPServer(); defer { server.close() }
    let entered = expectation(description: "upstream held for real downstream reset")
    let release = DispatchSemaphore(value: 0); defer { release.signal() }
    server.handler = { _ in
      entered.fulfill(); _ = release.wait(timeout: .now() + 5)
      return (200, [:], Data([1, 2]))
    }
    let lock = NSLock(); var rows: [[String: Any]] = []
    YlHlsMediaProxy.diagnosticRequestObserver = { row in lock.withLock { rows.append(row) } }
    defer { YlHlsMediaProxy.diagnosticRequestObserver = nil }
    let proxy = try YlHlsMediaProxy(originURL: server.url("/held"), headers: [:], configuration: .init(map: [:]))
    defer { proxy.cancelAll() }
    let url = try proxy.proxyURL(for: server.url("/held"))
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(fd, 0); guard fd >= 0 else { return }
    var open = true; defer { if open { Darwin.close(fd) } }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(url.port!).bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    XCTAssertEqual(connected, 0); guard connected == 0 else { return }
    let request = Data("GET \\(url.path) HTTP/1.1\\r\\nHost: owned\\r\\n\\r\\n".utf8)
    XCTAssertEqual(request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }, request.count)
    wait(for: [entered], timeout: 3)
    var reset = linger(l_onoff: 1, l_linger: 0)
    XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size)), 0)
    Darwin.close(fd); open = false
    XCTAssertTrue(try XCTUnwrap(YlHlsMediaProxy.diagnosticRequestCapture).wait(timeout: 3))
    let captured = lock.withLock { rows }
    XCTAssertEqual(captured.count, 1)
    let row = try XCTUnwrap(captured.first)
    XCTAssertEqual(row["outcome"] as? Double, 1)
    XCTAssertEqual(row["cancelCause"] as? Int, 3)
    XCTAssertTrue([1, 3].contains(row["cancelSource"] as? Int ?? -1), "OS callback order is not fixed")
    XCTAssertEqual(row["cancelErrorDomain"] as? Int, 1)
    XCTAssertEqual(row["cancelErrorCode"] as? Int, 54)
    XCTAssertEqual(row["taskOutcome"] as? Int, 1)
    XCTAssertEqual(proxy.diagnosticSnapshot["activeTasks"], 0)
    XCTAssertEqual(proxy.diagnosticSnapshot["activeConnections"], 0)
    XCTAssertEqual(proxy.diagnosticSnapshot["connectionDeadlines"], 0)
    let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
    attachment.name = "loopback-reset-error-source"; attachment.lifetime = .keepAlways
    XCTContext.runActivity(named: "Real reset records first observed error callback") { $0.add(attachment) }
  }

'''
assert anchor in s;s=s.replace(anchor,tests+anchor);p.write_text(s)
for platform in ('ios','macos'):Path(f'packages/yl_player/example/{platform}/RunnerTests/{p.name}').write_text('@testable import yl_player_media_core\n'+s)
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');p.write_text(p.read_text().replace("{'ios': 881, 'macos': 925}","{'ios': 883, 'macos': 927}"))
