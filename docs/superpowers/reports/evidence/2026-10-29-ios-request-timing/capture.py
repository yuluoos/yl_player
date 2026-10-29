from pathlib import Path
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();mark='    let processProof: [String: Any] = [';insert='''    let proxyBoundaryFile = try AbrProxyBoundaryFile(directory.appendingPathComponent("proxy-requests.jsonl"))
    YlHlsMediaProxy.diagnosticRequestObserver = { proxyBoundaryFile.append($0) }
    defer {
      YlHlsMediaProxy.diagnosticRequestObserver = nil
      proxyBoundaryFile.close()
      XCTAssertFalse(proxyBoundaryFile.failed)
    }
''';assert s.count(mark)==1;s=s.replace(mark,insert+mark)
s=s.replace('"proxySamplingVersion": 1, "proxy":','"proxyRequestSamplingVersion": 1, "proxySamplingVersion": 1, "proxy":',1)
mark='  func testProxyRequestTimingCorrelatesOwnedServerWithoutResourceIdentity() throws {'
s=s.replace(mark,'''  func testProxyRequestTimingSealsCancellationAndIgnoresLateSendCompletion() {
    var rows: [[String: Any]] = []
    let trace = YlHlsProxyRequestTrace(proxyID: "test-proxy", requestID: 1) { rows.append($0) }
    trace.response(status: 200, serverID: -1)
    trace.body(bytes: 8)
    let start = trace.enqueue()
    trace.finish(outcome: 1)
    trace.sent(started: start, bytes: 8, failed: false)
    trace.point("upstreamComplete")
    trace.finish(outcome: 0)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0]["outcome"] as? Double, 1)
    XCTAssertEqual(rows[0]["sendCount"] as? Double, 1)
    XCTAssertEqual(rows[0]["sendCompletions"] as? Double, 0)
    XCTAssertNil(rows[0]["serverRequestID"])
    XCTAssertNil(rows[0]["upstreamComplete"])
    XCTAssertEqual(rows[0]["sentBodyBytes"] as? Double, 0)
  }

'''+mark)
s+='''
private final class AbrProxyBoundaryFile: @unchecked Sendable {
  private let lock = NSLock()
  private var file: FileHandle?
  private var bytes = 0
  private var rows = 0
  private var writeFailed = false
  var failed: Bool { lock.withLock { writeFailed } }
  init(_ url: URL) throws {
    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    file = try FileHandle(forWritingTo: url)
  }
  func append(_ row: [String: Any]) {
    lock.withLock {
      guard let file else { return }
      do {
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])
        guard rows < 10000, bytes + data.count <= 16 * 1024 * 1024 else {
          writeFailed = true; return
        }
        try file.write(contentsOf: data); rows += 1; bytes += data.count
      } catch { writeFailed = true }
    }
  }
  func close() {
    lock.withLock {
      do { try file?.close() } catch { writeFailed = true }
      file = nil
    }
  }
}
''';p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');s=p.read_text().replace("'ios': 870, 'macos': 914","'ios': 872, 'macos': 916");p.write_text(s)
p=Path('tool/playback_network/abr_device.py');s=p.read_text().replace("'production-command-events.json', 'signals.jsonl')","'production-command-events.json', 'signals.jsonl', 'proxy-requests.jsonl')");p.write_text(s)
p=Path('tool/playback_network/network_profile.py');s=p.read_text().replace("            self.send_header('X-Yl-Profile-Id', s.profile.id)","            self.send_header('X-Yl-Request-Id', str(row['requestId']))\n            self.send_header('X-Yl-Profile-Id', s.profile.id)");p.write_text(s)
