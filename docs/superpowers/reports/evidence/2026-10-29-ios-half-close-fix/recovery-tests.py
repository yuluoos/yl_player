from pathlib import Path
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();a=s.index('  func testQueuedProxyCancellation');b=s.index('  func testHalfClosedClientReceives',a)
s=s[:a]+'''  private func halfClosedClient(_ url: URL, done: XCTestExpectation) -> NWConnection {
    let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(url.port!))!, using: .tcp)
    let ready = expectation(description: "half closed client ready")
    client.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
    client.start(queue: .global()); wait(for: [ready], timeout: 2)
    var payload = Data()
    func read() {
      client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
        XCTAssertNil(error)
        if let data { payload.append(data) }
        if complete || error != nil {
          XCTAssertEqual(Data(payload.suffix(2)), Data([1, 2])); done.fulfill()
        } else { read() }
      }
    }
    read()
    client.send(content: Data("GET \\(url.path) HTTP/1.1\\r\\nHost: owned\\r\\nConnection: close\\r\\n\\r\\n".utf8),
      contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { XCTAssertNil($0) })
    return client
  }

  func testQueuedHalfClosedRequestReceivesResponseAfterSlotRelease() throws {
    let server = try DashHTTPServer(); defer { server.close() }
    let held = expectation(description: "first upstream slot held")
    let release = DispatchSemaphore(value: 0); defer { release.signal() }
    server.handler = { request in
      if request.path == "/held" { held.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 6), .success) }
      return (200, [:], Data([1, 2]))
    }
    let proxy = try YlHlsMediaProxy(originURL: server.url("/held"), headers: [:], configuration: .init(map: [:]), sessionFactory: { config, delegate, queue in
      config.httpMaximumConnectionsPerHost = 1
      return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
    })
    defer { proxy.cancelAll() }
    let firstDone = expectation(description: "first body")
    let first = halfClosedClient(try proxy.proxyURL(for: server.url("/held")), done: firstDone); defer { first.cancel() }
    wait(for: [held], timeout: 2)
    let secondDone = expectation(description: "queued half closed body")
    let second = halfClosedClient(try proxy.proxyURL(for: server.url("/queued")), done: secondDone); defer { second.cancel() }
    let admitted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in proxy.diagnosticSnapshot["activeTasks"] == 2 }, object: nil)
    wait(for: [admitted], timeout: 2)
    XCTAssertEqual(server.requests.map(\\.path), ["/held"])
    release.signal(); wait(for: [firstDone, secondDone], timeout: 3)
    XCTAssertEqual(server.requests.map(\\.path), ["/held", "/queued"])
    let drained = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      proxy.diagnosticSnapshot["activeConnections"] == 0 && proxy.diagnosticSnapshot["activeTasks"] == 0 && proxy.diagnosticSnapshot["connectionDeadlines"] == 0
    }, object: nil)
    wait(for: [drained], timeout: 2)
  }

'''+s[b:]
a=s.index('  func testUnoccupiedProxyCancellation');b=s.index('  func testProxyRequestTimingRecordsRealCancellation',a)
s=s[:a]+'''  func testProxyDeadlineReclaimsSilentClosedAndNonReadingClients() throws {
    var samples: [[String: Any]] = []
    for mode in 0..<4 {
      let server = try DashHTTPServer(); defer { server.close() }
      let entered = expectation(description: "upstream entered")
      let release = DispatchSemaphore(value: 0); defer { release.signal() }
      server.handler = { _ in
        entered.fulfill()
        if mode != 3 { _ = release.wait(timeout: .now() + 6) }
        return (200, [:], mode == 3 ? Data(repeating: 7, count: 8 * 1024 * 1024) : Data([1, 2]))
      }
      let lock = NSLock(); var rows: [[String: Any]] = []
      YlHlsMediaProxy.diagnosticRequestObserver = { row in lock.withLock { rows.append(row) } }
      defer { YlHlsMediaProxy.diagnosticRequestObserver = nil }
      let proxy = try YlHlsMediaProxy(originURL: server.url("/held"), headers: [:],
        configuration: .init(map: ["connectTimeoutMs": 80, "readTimeoutMs": 420]), sessionFactory: { config, delegate, queue in
          // Force the independent proxy deadline, not Foundation's timeout.
          config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 30
          return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        })
      defer { proxy.cancelAll() }
      let url = try proxy.proxyURL(for: server.url("/held"))
      let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(url.port!))!, using: .tcp)
      defer { client.cancel() }
      let ready = expectation(description: "deadline client ready")
      client.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
      let started = ProcessInfo.processInfo.systemUptime
      client.start(queue: .global()); wait(for: [ready], timeout: 2)
      let request = mode == 2 ? "GET /" : "GET \\(url.path) HTTP/1.1\\r\\nHost: owned\\r\\n\\r\\n"
      client.send(content: Data(request.utf8), completion: .contentProcessed { XCTAssertNil($0) })
      if mode != 2 { wait(for: [entered], timeout: 2) }
      if mode == 1 { client.cancel() }
      let drained = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        proxy.diagnosticSnapshot["activeConnections"] == 0 && proxy.diagnosticSnapshot["activeTasks"] == 0 && proxy.diagnosticSnapshot["connectionDeadlines"] == 0
      }, object: nil)
      wait(for: [drained], timeout: 2)
      XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2.5)
      XCTAssertTrue(try XCTUnwrap(YlHlsMediaProxy.diagnosticRequestCapture).wait(timeout: 2))
      let captured = lock.withLock { rows }
      XCTAssertEqual(captured.count, mode == 2 ? 0 : 1)
      if mode == 0 { XCTAssertEqual(captured.first?["cancelCause"] as? Int, 4) }
      samples.append(["mode": mode, "elapsed": ProcessInfo.processInfo.systemUptime - started,
        "snapshot": proxy.diagnosticSnapshot, "traces": captured])
    }
    let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: ["samples": samples, "capabilityAccepted": false], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
    attachment.name = "bounded-connection-reclamation"; attachment.lifetime = .keepAlways
    XCTContext.runActivity(named: "Independent deadline reclaims stalled exchanges") { $0.add(attachment) }
  }

'''+s[b:]
# Keep the existing cancellation ownership contract explicit: owner cancellation
# remains immediate; peer closure can now settle through the configured deadline.
a=s.index('  func testProxyRequestTimingRecordsRealCancellation');b=s.index('  func testProxyRequestTimingSealsCancellation',a);t=s[a:b].replace('configuration: .init(map: [:])','configuration: .init(map: ["connectTimeoutMs": 80, "readTimeoutMs": 420]), sessionFactory: { config, delegate, queue in\n        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 30\n        return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)\n      })').replace('      })\n      defer','      }\n      defer')
t=t.replace('[2, 3].contains','[3, 4].contains');s=s[:a]+t+s[b:];p.write_text(s)
for v in ('ios','macos'):Path(f'packages/yl_player/example/{v}/RunnerTests/YlDashResourceLoaderTests.swift').write_text('@testable import yl_player_media_core\n'+s)
