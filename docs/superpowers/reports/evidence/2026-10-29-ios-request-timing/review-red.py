from pathlib import Path
import subprocess,shutil
r=Path('/private/tmp/yl-request-timing')
(r/'pre-review-code.patch').write_bytes(subprocess.check_output(['git','diff','91ecf8f9']))
for f in ['packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsMediaProxy.swift','tool/playback_network/proxy_boundaries.py','tool/playback_network/test_proxy_boundaries.py']:
 p=r/'pre-review-sources'/f;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(Path(f).read_bytes())
(r/'initial-source-identity.json').write_bytes((r/'source-identity.json').read_bytes())
p=Path('tool/playback_network/test_proxy_boundaries.py');s=p.read_text();mark='    def test_input_is_preserved_and_failed_send_does_not_claim_all_bytes(self):';s=s.replace(mark,'''    def test_cancelled_pending_body_can_follow_completed_header_send(self):
        row = dict(self.trace, outcome=1, lastSend=10.3, lastSendComplete=10.21,
                   sendCount=2, sendCompletions=1, sentBodyBytes=0)
        result = summarize_proxy_boundaries([row], [self.server])
        self.assertEqual(result['outcomeCounts'], {'cancelled':1})

'''+mark);p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();mark='  func testProxyRequestTimingRecordsRealCancellationBeforeUpstreamResponse() throws {';s=s.replace(mark,'''  func testProxyRequestTimingRetainsTerminalOwnershipUntilObserverReturns() throws {
    let server = try DashHTTPServer(); defer { server.close() }
    server.handler = { _ in (200, ["X-Yl-Request-Id": "19"], Data([1, 2])) }
    let entered = expectation(description: "terminal observer entered")
    let release = DispatchSemaphore(value: 0); defer { release.signal() }
    YlHlsMediaProxy.diagnosticRequestObserver = { _ in
      entered.fulfill(); _ = release.wait(timeout: .now() + 4)
    }
    defer { YlHlsMediaProxy.diagnosticRequestObserver = nil }
    let proxy = try YlHlsMediaProxy(originURL: server.url("/media"), headers: [:], configuration: .init(map: [:]))
    defer { proxy.cancelAll() }
    let done = expectation(description: "downstream finished")
    URLSession.shared.dataTask(with: try proxy.proxyURL(for: server.url("/media"))) { _, _, _ in done.fulfill() }.resume()
    wait(for: [entered], timeout: 3)
    XCTAssertEqual(proxy.diagnosticSnapshot["activeTasks"], 0)
    XCTAssertEqual(proxy.diagnosticSnapshot["activeRequestTraces"], 1)
    proxy.cancelAll()
    release.signal()
    wait(for: [done], timeout: 3)
  }

'''+mark);p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');p.write_text(p.read_text().replace("'ios': 873, 'macos': 917","'ios': 874, 'macos': 918"))
