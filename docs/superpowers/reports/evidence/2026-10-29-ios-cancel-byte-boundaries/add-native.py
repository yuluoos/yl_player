from pathlib import Path
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift')
s=p.read_text();marker='  func testProxyRequestTimingRecordsRealCancellationBeforeUpstreamResponse() throws {'
new='''  func testUnoccupiedProxyCancellationPreservesTransportAndServerEvidence() throws {
    // Characterize the real EOF race with the production connection limit and
    // no preceding task. A held response prevents success before cancellation;
    // it does not occupy a connection before the tested request is admitted.
    var samples: [[String: Any]] = []
    for attempt in 0..<6 {
      let server = try DashHTTPServer(); defer { server.close() }
      let release = DispatchSemaphore(value: 0)
      defer { release.signal(); release.signal() }
      server.handler = { _ in
        XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        return (200, [:], Data([1, 2]))
      }
      let lock = NSLock(); var rows: [[String: Any]] = []
      let cancelled = expectation(description: "unoccupied cancellation settled")
      YlHlsMediaProxy.diagnosticRequestObserver = { row in
        lock.withLock { rows.append(row) }
        if row["requestID"] as? Double == 1 { cancelled.fulfill() }
      }
      defer { YlHlsMediaProxy.diagnosticRequestObserver = nil }
      let origin = server.url("/same-resource")
      let proxy = try YlHlsMediaProxy(originURL: origin, headers: [:], configuration: .init(map: [:]))
      defer { proxy.cancelAll() }
      XCTAssertEqual(proxy.diagnosticSnapshot["activeTasks"], 0)
      let url = try proxy.proxyURL(for: origin)
      let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(url.port!))!, using: .tcp)
      defer { client.cancel() }
      let ready = expectation(description: "unoccupied client ready")
      client.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
      client.start(queue: .global()); wait(for: [ready], timeout: 2)
      let request = "GET \\(url.path) HTTP/1.1\\r\\nHost: owned\\r\\nConnection: close\\r\\n\\r\\n"
      client.send(content: Data(request.utf8), contentContext: .finalMessage, isComplete: true,
        completion: .contentProcessed { XCTAssertNil($0) })
      wait(for: [cancelled], timeout: 3)
      let row = try XCTUnwrap(lock.withLock { rows.first })
      XCTAssertEqual(row["cancelCause"] as? Int, 2)
      XCTAssertEqual(row["outcome"] as? Int, 1)
      XCTAssertEqual(row["taskOutcome"] as? Int, 1)
      XCTAssertEqual(row["bodyBytes"] as? Int, 0)
      XCTAssertEqual(row["sentBodyBytes"] as? Int, 0)
      let metrics = try XCTUnwrap(row["metrics"] as? [String: Any])
      XCTAssertEqual(metrics["version"] as? Int, 3)
      XCTAssertEqual(proxy.diagnosticSnapshot["activeTasks"], 0)
      XCTAssertEqual(proxy.diagnosticSnapshot["activeRequestTraces"], 0)
      release.signal(); release.signal()
      let done = expectation(description: "same resource succeeds after unoccupied cancellation")
      URLSession.shared.dataTask(with: url) { data, _, error in
        XCTAssertNil(error); XCTAssertEqual(data, Data([1, 2])); done.fulfill()
      }.resume()
      wait(for: [done], timeout: 3)
      XCTAssertTrue(try XCTUnwrap(YlHlsMediaProxy.diagnosticRequestCapture).wait(timeout: 2))
      let captured = lock.withLock { rows }
      XCTAssertEqual(captured.count, 2)
      let followup = try XCTUnwrap(captured.first { $0["requestID"] as? Double == 2 })
      XCTAssertEqual(followup["taskOutcome"] as? Int, 0)
      XCTAssertEqual(followup["resourceToken"] as? String, row["resourceToken"] as? String)
      let followupID = try XCTUnwrap(followup["correlationID"] as? String)
      XCTAssertNotEqual(followupID, row["correlationID"] as? String)
      let parsed = server.requests.compactMap { $0.headers["x-yl-trace-id"] }
      XCTAssertEqual(parsed.filter { $0 == followupID }.count, 1)
      // Snapshot, not proof that a cancelled request can never arrive later.
      // Do not require no server request or a fixed transaction count: the
      // unoccupied transport race may legitimately reach either boundary.
      samples.append(["attempt": attempt, "trace": row, "followupTrace": followup,
        "parsedServerTraceIDs": parsed, "snapshotAfterExplicitFollowup": true])
    }
    let evidence: [String: Any] = ["scenario": "unoccupied-default-pool-cancel-then-explicit-same-url",
      "samples": samples, "capabilityAccepted": false, "physicalOutputVerified": false]
    let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
    attachment.name = "unoccupied-cancellation-evidence"; attachment.lifetime = .keepAlways
    XCTContext.runActivity(named: "Cancellation without a preceding occupied slot") { $0.add(attachment) }
  }

'''
assert marker in s;s=s.replace(marker,new+marker,1);p.write_text(s)
for platform in ('ios','macos'):
 Path(f'packages/yl_player/example/{platform}/RunnerTests/YlDashResourceLoaderTests.swift').write_text('@testable import yl_player_media_core\n'+s)
