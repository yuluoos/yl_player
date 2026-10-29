from pathlib import Path
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();mark='  func testUnoccupiedProxyCancellationPreservesTransportAndServerEvidence() throws {'
new='''  func testHalfClosedClientCanReceiveDirectResponseButProxyCancels() throws {
    let server = try DashHTTPServer(); defer { server.close() }
    server.handler = { _ in (200, [:], Data([1, 2, 3, 4])) }
    let lock = NSLock(); var traces: [[String: Any]] = []
    YlHlsMediaProxy.diagnosticRequestObserver = { row in lock.withLock { traces.append(row) } }
    defer { YlHlsMediaProxy.diagnosticRequestObserver = nil }
    let proxy = try YlHlsMediaProxy(originURL: server.url("/half-close"), headers: [:], configuration: .init(map: [:]))
    defer { proxy.cancelAll() }
    var observations: [[String: Any]] = []
    for proxied in [false, true] {
      let url = try proxied ? proxy.proxyURL(for: server.url("/half-close")) : server.url("/half-close")
      let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(url.port!))!, using: .tcp)
      defer { connection.cancel() }
      let ready = expectation(description: "half close ready")
      connection.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
      connection.start(queue: .global()); wait(for: [ready], timeout: 2)
      let received = expectation(description: "read side remains open after write EOF")
      var payload = Data(); var receiveFailed = false
      func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
          if let data { payload.append(data) }
          if complete || error != nil { receiveFailed = error != nil; received.fulfill() }
          else { read() }
        }
      }
      read()
      connection.send(content: Data("GET \\(url.path) HTTP/1.1\\r\\nHost: owned\\r\\nConnection: close\\r\\n\\r\\n".utf8),
        contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { XCTAssertNil($0) })
      wait(for: [received], timeout: 4)
      if !proxied {
        XCTAssertFalse(receiveFailed)
        XCTAssertEqual(Data(payload.suffix(4)), Data([1, 2, 3, 4]))
      } else {
        XCTAssertTrue(try XCTUnwrap(YlHlsMediaProxy.diagnosticRequestCapture).wait(timeout: 2))
        let row = try XCTUnwrap(lock.withLock { traces.first })
        XCTAssertEqual(row["cancelCause"] as? Int, 2)
        XCTAssertEqual(row["outcome"] as? Double, 1)
        // Characterization of an OPEN defect, not acceptance of half-close support.
        // Do not assert byte count: upstream response and EOF can race.
      }
      observations.append(["proxied": proxied, "receivedBytes": payload.count,
        "receivedExpectedBody": Data(payload.suffix(4)) == Data([1, 2, 3, 4]),
        "receiveFailed": receiveFailed, "clientReadSideKeptOpen": true])
    }
    let evidence: [String: Any] = ["scenario": "same-write-half-close-direct-and-proxy",
      "observations": observations, "traces": lock.withLock { traces },
      "halfCloseSupportAccepted": false, "historicalCauseProven": false, "capabilityAccepted": false]
    let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
    attachment.name = "half-close-direction-evidence"; attachment.lifetime = .keepAlways
    XCTContext.runActivity(named: "Write EOF does not establish loss of response interest") { $0.add(attachment) }
  }

'''
assert mark in s;s=s.replace(mark,new+mark);p.write_text(s)
for v in ('ios','macos'):Path(f'packages/yl_player/example/{v}/RunnerTests/YlDashResourceLoaderTests.swift').write_text('@testable import yl_player_media_core\n'+s)
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');s=p.read_text().replace("'ios': 879, 'macos': 923","'ios': 880, 'macos': 924");p.write_text(s)
p=Path('/private/tmp/yl-half-close/run.py');s=Path('/private/tmp/yl-cancel-byte-boundaries/run.py').read_text().replace('/private/tmp/yl-cancel-byte-boundaries','/private/tmp/yl-half-close').replace('testUnoccupiedProxyCancellationPreservesTransportAndServerEvidence','testHalfClosedClientCanReceiveDirectResponseButProxyCancels');p.write_text(s)
