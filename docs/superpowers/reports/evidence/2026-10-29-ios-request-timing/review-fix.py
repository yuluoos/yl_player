from pathlib import Path
p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsMediaProxy.swift');s=p.read_text()
s=s.replace('''  private static var diagnosticObserver: (([String: Any]) -> Void)?
  static var diagnosticRequestObserver: (([String: Any]) -> Void)? {
    get { diagnosticObserverLock.withLock { diagnosticObserver } }
    set { diagnosticObserverLock.withLock { diagnosticObserver = newValue } }
  }
  private let diagnosticProxyID = UUID().uuidString''','''  private static var diagnosticCapture: YlHlsProxyRequestCapture?
  static var diagnosticRequestCapture: YlHlsProxyRequestCapture? {
    diagnosticObserverLock.withLock { diagnosticCapture }
  }
  static var diagnosticRequestObserver: (([String: Any]) -> Void)? {
    get { diagnosticObserverLock.withLock { diagnosticCapture?.observer } }
    set { diagnosticObserverLock.withLock { diagnosticCapture = newValue.map(YlHlsProxyRequestCapture.init) } }
  }
  private let diagnosticProxyID = UUID().uuidString
  private var diagnosticSequence = 0
  private var diagnosticActiveTraces: [ObjectIdentifier: YlHlsProxyRequestTrace] = [:]''')
s=s.replace('      result["activeConnections"] = Double(connections.count)','      result["activeRequestTraces"] = Double(diagnosticActiveTraces.count)\n      result["activeConnections"] = Double(connections.count)',1)
s=s.replace('      traces = taskRecords.values.compactMap { $0.trace }','      traces = Array(diagnosticActiveTraces.values)',1)
s=s.replace('''      let task = session.dataTask(with: request)
      taskRecords[task.taskIdentifier]''','''      #if DEBUG
      let connectionID = ObjectIdentifier(connection)
      diagnosticSequence += 1
      let diagnosticTrace = Self.diagnosticRequestCapture?.makeTrace(
        proxyID: diagnosticProxyID, requestID: diagnosticSequence,
        didDeliver: { [weak self] in
          _ = self?.lock.withLock { self?.diagnosticActiveTraces.removeValue(forKey: connectionID) }
        })
      var taskRequest = request
      if let diagnosticTrace { taskRequest.setValue(diagnosticTrace.correlationID, forHTTPHeaderField: "X-Yl-Trace-Id") }
      #else
      let taskRequest = request
      #endif
      let task = session.dataTask(with: taskRequest)
      taskRecords[task.taskIdentifier]''',1)
s=s.replace('''      if let observer = Self.diagnosticRequestObserver {
        taskRecords[task.taskIdentifier]?.trace = YlHlsProxyRequestTrace(
          proxyID: diagnosticProxyID, requestID: task.taskIdentifier, observer: observer)
      }''','''      if let diagnosticTrace {
        taskRecords[task.taskIdentifier]?.trace = diagnosticTrace
        diagnosticActiveTraces[connectionID] = diagnosticTrace
      }''',1)
s=s.replace('''      let identifier = ObjectIdentifier(connection)
      connections.removeValue(forKey: identifier)''','''      let identifier = ObjectIdentifier(connection)
      #if DEBUG
      trace = diagnosticActiveTraces[identifier]
      #endif
      connections.removeValue(forKey: identifier)''',1)
s=s.replace('        trace = taskRecords[task.taskIdentifier]?.trace\n','',1)
s=s.replace('''  private let observer: ([String: Any]) -> Void
  init(proxyID:''','''  private let observer: ([String: Any]) -> Void
  let correlationID: String
  init(proxyID:''',1)
s=s.replace('''    self.observer = observer
    values = ["version": 1, "proxyID": proxyID''','''    self.observer = observer
    let correlationID = UUID().uuidString
    self.correlationID = correlationID
    values = ["version": 1, "correlationID": correlationID, "proxyID": proxyID''',1)
s+='''
#if DEBUG
/// Registration and stop share a lock. A sealed trace remains pending until its
/// observer has returned, so the test writer cannot close before the last append.
final class YlHlsProxyRequestCapture {
  private let lock = NSLock()
  private let pending = DispatchGroup()
  private var active = true
  let observer: ([String: Any]) -> Void
  init(observer: @escaping ([String: Any]) -> Void) { self.observer = observer }
  func makeTrace(proxyID: String, requestID: Int, didDeliver: @escaping () -> Void = {}) -> YlHlsProxyRequestTrace? {
    lock.withLock {
      guard active else { return nil }
      pending.enter()
      return YlHlsProxyRequestTrace(proxyID: proxyID, requestID: requestID) { [self] row in
        defer { didDeliver(); pending.leave() }
        observer(row)
      }
    }
  }
  func stop() { lock.withLock { active = false } }
  func wait(timeout: TimeInterval) -> Bool { pending.wait(timeout: .now() + timeout) == .success }
}
#endif
'''
p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();s=s.replace('''    YlHlsMediaProxy.diagnosticRequestObserver = { proxyBoundaryFile.append($0) }
    defer {
      YlHlsMediaProxy.diagnosticRequestObserver = nil
      proxyBoundaryFile.close()''','''    YlHlsMediaProxy.diagnosticRequestObserver = { proxyBoundaryFile.append($0) }
    let proxyBoundaryCapture = try XCTUnwrap(YlHlsMediaProxy.diagnosticRequestCapture)
    defer {
      YlHlsMediaProxy.diagnosticRequestObserver = nil
      proxyBoundaryCapture.stop()
      XCTAssertTrue(proxyBoundaryCapture.wait(timeout: 2), "Request boundary delivery did not drain")
      proxyBoundaryFile.close()''',1)
s=s.replace('''    XCTAssertEqual(proxy.diagnosticSnapshot["activeRequestTraces"], 1)
    proxy.cancelAll()
    release.signal()
    wait(for: [done], timeout: 3)''','''    XCTAssertEqual(proxy.diagnosticSnapshot["activeRequestTraces"], 1)
    let capture = try XCTUnwrap(YlHlsMediaProxy.diagnosticRequestCapture)
    capture.stop()
    XCTAssertNil(capture.makeTrace(proxyID: "stopped", requestID: 99))
    proxy.cancelAll()
    XCTAssertFalse(capture.wait(timeout: 0.01), "Sealed is not the same as delivered")
    release.signal()
    XCTAssertTrue(capture.wait(timeout: 2))
    XCTAssertEqual(proxy.diagnosticSnapshot["activeRequestTraces"], 0)
    wait(for: [done], timeout: 3)''',1)
s=s.replace('      guard let file else { return }\n','      guard let file else { writeFailed = true; return }\n',1);p.write_text(s)
