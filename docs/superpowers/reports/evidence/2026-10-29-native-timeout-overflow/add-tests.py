from pathlib import Path
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift')
s=p.read_text();anchor='  func testProxyBoundarySnapshotTracksRealRequestAndCancellationWithoutResourceIdentity() throws {'
test='''  func testExtremeNativeTimeoutsKeepProxyAndPreflightUsable() throws {
    // Native options intentionally preserve values above the map's 60s cap.
    // Integer addition before conversion used to trap for both extrema.
    let cases: [(Int64, Int64, Double, Double)] = [
      (.max, .max, 9_223_372_036_854_776, 18_446_744_073_709_552),
      (.min, .min, 0.001, 0.001),
      (90_000, 120_000, 120, 210),
      (10_000, 15_000, 15, 25),
      (0, 0, 0.001, 0.001)
    ]
    for (connect, read, requestSeconds, resourceSeconds) in cases {
      let config = YlNetworkConfiguration(connectTimeoutMs: connect, readTimeoutMs: read,
        maxRetries: 0, baseRetryDelayMs: 0, maxRetryDelayMs: 0, maxRedirects: 0)
      var sessions = 0
      let factory: (URLSessionConfiguration, URLSessionDelegate, OperationQueue) -> URLSession = { value, delegate, queue in
        sessions += 1
        XCTAssertEqual(value.timeoutIntervalForRequest, requestSeconds, accuracy: max(0.000_001, requestSeconds * 1e-15))
        XCTAssertEqual(value.timeoutIntervalForResource, resourceSeconds, accuracy: max(0.000_001, resourceSeconds * 1e-15))
        return URLSession(configuration: value, delegate: delegate, delegateQueue: queue)
      }
      let server = try DashHTTPServer(); defer { server.close() }
      server.handler = { _ in (200, [:], Data([1, 2, 3, 4])) }
      let proxy = try YlHlsMediaProxy(originURL: server.url("/media"), headers: [:],
        configuration: config, sessionFactory: factory)
      defer { proxy.cancelAll() }
      let loader = try YlHlsResourceLoader(originURL: origin, isDash: true, headers: [:],
        configuration: config, sessionFactory: factory)
      defer { loader.cancelAll() }
      let snapshot = YlDashManifestSnapshot(data: mpd, effectiveURL: origin,
        credentialsStripped: false, indexes: [:])
      try loader.preflight(cancellationToken: .init(), snapshot: snapshot)
      XCTAssertEqual(loader.dashSnapshot?.data, mpd)
      XCTAssertEqual(sessions, 2)
      if connect == Int64.max {
        let done = expectation(description: "extreme timeout proxy still responds")
        URLSession.shared.dataTask(with: try proxy.proxyURL(for: server.url("/media"))) { body, _, error in
          XCTAssertNil(error); XCTAssertEqual(body, Data([1, 2, 3, 4])); done.fulfill()
        }.resume()
        wait(for: [done], timeout: 4)
        proxy.cancelAll()
        XCTAssertEqual(proxy.diagnosticSnapshot["activeConnections"], 0)
        XCTAssertEqual(proxy.diagnosticSnapshot["connectionDeadlines"], 0)
      }
    }
  }

'''
assert anchor in s
p.write_text(s.replace(anchor,test+anchor))
for platform in ('ios','macos'):
 Path(f'packages/yl_player/example/{platform}/RunnerTests/{p.name}').write_text('@testable import yl_player_media_core\n'+p.read_text())
