from pathlib import Path
p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsMediaProxy.swift');s=p.read_text();needle='  func urlSession(\n    _ session: URLSession,\n    task: URLSessionTask,\n    didCompleteWithError'
s=s.replace(needle,'''  #if DEBUG
  func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
    let trace = lock.withLock { taskRecords[task.taskIdentifier]?.trace }
    trace?.metrics(metrics)
  }
  #endif

'''+needle)
s=s.replace('values = ["version": 1,','values = ["version": 2, "metrics": NSNull(),')
needle='  func point(_ name: String) { update { $0[name] = $1 } }'
s=s.replace(needle,'''  // Date pairs stay within the Foundation clock; never subtract them from uptime.
  static func interval(from start: Date?, to end: Date?) -> Double? {
    guard let start, let end else { return nil }
    let seconds = end.timeIntervalSince(start)
    return seconds.isFinite && seconds >= 0 ? seconds : nil
  }
  func metrics(_ metrics: URLSessionTaskMetrics) {
    func duration(_ start: Date?, _ end: Date?) -> Any {
      Self.interval(from: start, to: end).map { $0 as Any } ?? NSNull()
    }
    let transactions: [[String: Any]] = metrics.transactionMetrics.prefix(32).map { t in
      let protocolCode: Int
      switch t.networkProtocolName {
      case "http/1.0", "http/1.1": protocolCode = 1
      case "h2": protocolCode = 2
      case "h3": protocolCode = 3
      default: protocolCode = 0
      }
      return ["fetchSeconds": duration(t.fetchStartDate, t.responseEndDate),
        "fetchToRequestSeconds": duration(t.fetchStartDate, t.requestStartDate),
        "dnsSeconds": duration(t.domainLookupStartDate, t.domainLookupEndDate),
        "connectSeconds": duration(t.connectStartDate, t.connectEndDate),
        "tlsSeconds": duration(t.secureConnectionStartDate, t.secureConnectionEndDate),
        "requestSeconds": duration(t.requestStartDate, t.requestEndDate),
        "responseWaitSeconds": duration(t.requestEndDate, t.responseStartDate),
        "responseSeconds": duration(t.responseStartDate, t.responseEndDate),
        "reused": t.isReusedConnection ? 1 : 0, "protocolCode": protocolCode,
        "fetchType": t.resourceFetchType.rawValue]
    }
    update { v, _ in
      v["metrics"] = ["taskSeconds": duration(metrics.taskInterval.start, metrics.taskInterval.end),
        "transactionCount": metrics.transactionMetrics.count, "redirectCount": metrics.redirectCount,
        "truncated": metrics.transactionMetrics.count > 32 ? 1 : 0, "transactions": transactions]
    }
  }
'''+needle);p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text().replace('"proxyRequestSamplingVersion": 1','"proxyRequestSamplingVersion": 2')
needle='  func testProxyRequestTimingCorrelatesOwnedServerWithoutResourceIdentity'
pos=s.index(needle)
s=s[:pos]+'''  func testProxyTransactionDurationPreservesUnavailableAndInvalidDates() {
    let start = Date(timeIntervalSince1970: 100)
    XCTAssertNil(YlHlsProxyRequestTrace.interval(from: nil, to: start))
    XCTAssertNil(YlHlsProxyRequestTrace.interval(from: start, to: nil))
    XCTAssertNil(YlHlsProxyRequestTrace.interval(from: start, to: start.addingTimeInterval(-1)))
    XCTAssertNil(YlHlsProxyRequestTrace.interval(from: start, to: Date(timeIntervalSince1970: .infinity)))
    XCTAssertEqual(YlHlsProxyRequestTrace.interval(from: start, to: start), 0)
    XCTAssertEqual(YlHlsProxyRequestTrace.interval(from: start, to: start.addingTimeInterval(2)), 2)
  }

'''+s[pos:];p.write_text(s)
import sys
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter')
from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:Path(f'packages/yl_player/example/{platform}/RunnerTests/{p.name}').write_bytes(native_test_source(p))
