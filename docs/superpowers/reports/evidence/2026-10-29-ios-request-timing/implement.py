from pathlib import Path
p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsMediaProxy.swift');s=p.read_text()
s=s.replace('  static var diagnosticRequestObserver: (([String: Any]) -> Void)?','''  private static let diagnosticObserverLock = NSLock()
  private static var diagnosticObserver: (([String: Any]) -> Void)?
  static var diagnosticRequestObserver: (([String: Any]) -> Void)? {
    get { diagnosticObserverLock.withLock { diagnosticObserver } }
    set { diagnosticObserverLock.withLock { diagnosticObserver = newValue } }
  }
  private let diagnosticProxyID = UUID().uuidString
''')
s=s.replace('    var httpStatus: Int?','''    var httpStatus: Int?
    #if DEBUG
    var trace: YlHlsProxyRequestTrace?
    #endif''',1)
s=s.replace('      diagnosticCounters["admittedRequests", default: 0] += 1','''      if let observer = Self.diagnosticRequestObserver {
        taskRecords[task.taskIdentifier]?.trace = YlHlsProxyRequestTrace(
          proxyID: diagnosticProxyID, requestID: task.taskIdentifier, observer: observer)
      }
      diagnosticCounters["admittedRequests", default: 0] += 1''',1)
s=s.replace('  func cancelAll() {\n    let activeConnections', '''  func cancelAll() {
    #if DEBUG
    var traces: [YlHlsProxyRequestTrace] = []
    #endif
    let activeConnections''',1)
s=s.replace('      cancelled = true\n      taskRecords.removeAll()', '''      cancelled = true
      #if DEBUG
      traces = taskRecords.values.compactMap { $0.trace }
      #endif
      taskRecords.removeAll()''',1)
s=s.replace('    upstreamDiagnostics.clear()\n    listener.cancel()', '''    #if DEBUG
    traces.forEach { $0.finish(outcome: 1) }
    #endif
    upstreamDiagnostics.clear()
    listener.cancel()''',1)
s=s.replace('  private func close(_ connection: NWConnection) {\n    let task', '''  private func close(_ connection: NWConnection) {
    #if DEBUG
    var trace: YlHlsProxyRequestTrace?
    #endif
    let task''',1)
s=s.replace('        diagnosticCounters["closedWithActiveTask", default: 0] += 1','''        trace = taskRecords[task.taskIdentifier]?.trace
        diagnosticCounters["closedWithActiveTask", default: 0] += 1''',1)
s=s.replace('    task?.cancel()\n    connection.cancel()', '''    #if DEBUG
    trace?.finish(outcome: 1)
    #endif
    task?.cancel()
    connection.cancel()''',1)
s=s.replace('    record.httpStatus = response.statusCode', '''    #if DEBUG
    record.trace?.response(status: response.statusCode,
      serverID: response.value(forHTTPHeaderField: "X-Yl-Request-Id").flatMap(Int.init))
    #endif
    record.httpStatus = response.statusCode''',1)
s=s.replace('    sendHead(\n      status: response.statusCode,','''    #if DEBUG
    let sendStarted = record.trace?.enqueue()
    #endif
    sendHead(
      status: response.statusCode,''',1)
s=s.replace('''      guard let self, let dataTask else { return }
      self.responseSendDidComplete(''','''      guard let self, let dataTask else { return }
      #if DEBUG
      record.trace?.sent(started: sendStarted, bytes: 0, failed: error != nil)
      #endif
      self.responseSendDidComplete(''',1)
s=s.replace('    lock.withLock { diagnosticCounters["receivedBodyBytes", default: 0] += Double(data.count) }','''    record.trace?.body(bytes: data.count)
    lock.withLock { diagnosticCounters["receivedBodyBytes", default: 0] += Double(data.count) }''',1)
s=s.replace('''    dataTask.suspend()
    lock.withLock { record.pendingSends += 1 }''','''    #if DEBUG
    let sendStarted = record.trace?.enqueue()
    let sentBytes = data.count
    #endif
    dataTask.suspend()
    lock.withLock { record.pendingSends += 1 }''',1)
s=s.replace('''        guard let self, let dataTask else { return }
        self.responseSendDidComplete(''','''        guard let self, let dataTask else { return }
        #if DEBUG
        record.trace?.sent(started: sendStarted, bytes: sentBytes, failed: error != nil)
        #endif
        self.responseSendDidComplete(''',1)
s=s.replace('''      record.upstreamFinished = true
      record.upstreamError = error''','''      #if DEBUG
      record.trace?.point("upstreamComplete")
      #endif
      record.upstreamFinished = true
      record.upstreamError = error''',1)
s=s.replace('''    case .badGateway:
      send(''','''    case .badGateway:
      #if DEBUG
      record.trace?.finish(outcome: 3)
      #endif
      send(''',1)
s=s.replace('''    case .finishChunked:
      record.connection.send(''','''    case .finishChunked:
      #if DEBUG
      let sendStarted = record.trace?.enqueue()
      #endif
      record.connection.send(''',1)
s=s.replace('''completion: .contentProcessed(retainingPayloadCompletion { [weak self] _ in
          self?.close(record.connection)''','''completion: .contentProcessed(retainingPayloadCompletion { [weak self] error in
          #if DEBUG
          record.trace?.sent(started: sendStarted, bytes: 0, failed: error != nil)
          record.trace?.finish(outcome: error == nil ? 0 : 2)
          #endif
          self?.close(record.connection)''',1)
s=s.replace('''    case .close:
      close(record.connection)''','''    case .close:
      #if DEBUG
      record.trace?.finish(outcome: error == nil && record.reportedFailure == nil ? 0 : 3)
      #endif
      close(record.connection)''',1)
s=s.replace('''    if error != nil {
      close(record.connection)''','''    if error != nil {
      #if DEBUG
      record.trace?.finish(outcome: 2)
      #endif
      close(record.connection)''',1)
s+='''
#if DEBUG
/// One bounded record per admitted request, enabled only by an explicit observer.
/// Completion is sealed before invoking the observer; late callbacks are ignored.
final class YlHlsProxyRequestTrace {
  private let lock = NSLock()
  private var sealed = false
  private var values: [String: Any]
  private let observer: ([String: Any]) -> Void
  init(proxyID: String, requestID: Int, observer: @escaping ([String: Any]) -> Void) {
    self.observer = observer
    values = ["version": 1, "proxyID": proxyID, "requestID": Double(requestID),
      "admission": ProcessInfo.processInfo.systemUptime,
      "bodyBytes": 0.0, "sentBodyBytes": 0.0, "bodyCallbacks": 0.0,
      "sendCount": 0.0, "sendCompletions": 0.0, "sendFailures": 0.0,
      "sendWaitSum": 0.0, "sendWaitMax": 0.0]
  }
  private func update(_ action: (inout [String: Any], Double) -> Void) {
    lock.withLock {
      guard !sealed else { return }
      action(&values, ProcessInfo.processInfo.systemUptime)
    }
  }
  func point(_ name: String) { update { $0[name] = $1 } }
  func response(status: Int, serverID: Int?) {
    update { v, now in
      v["response"] = now; v["httpStatus"] = Double(status)
      if let serverID, serverID > 0 && serverID <= 10000 { v["serverRequestID"] = Double(serverID) }
    }
  }
  func body(bytes: Int) {
    update { v, now in
      if v["firstBody"] == nil { v["firstBody"] = now }
      v["lastBody"] = now
      v["bodyBytes"] = (v["bodyBytes"] as? Double ?? 0) + Double(bytes)
      v["bodyCallbacks"] = (v["bodyCallbacks"] as? Double ?? 0) + 1
    }
  }
  func enqueue() -> Double {
    let now = ProcessInfo.processInfo.systemUptime
    update { v, _ in
      if v["firstSend"] == nil { v["firstSend"] = now }
      v["lastSend"] = now; v["sendCount"] = (v["sendCount"] as? Double ?? 0) + 1
    }
    return now
  }
  func sent(started: Double?, bytes: Int, failed: Bool) {
    update { v, now in
      v["lastSendComplete"] = now
      v["sendCompletions"] = (v["sendCompletions"] as? Double ?? 0) + 1
      v["sendFailures"] = (v["sendFailures"] as? Double ?? 0) + (failed ? 1 : 0)
      if !failed { v["sentBodyBytes"] = (v["sentBodyBytes"] as? Double ?? 0) + Double(bytes) }
      if let started {
        let wait = max(0, now - started)
        v["sendWaitSum"] = (v["sendWaitSum"] as? Double ?? 0) + wait
        v["sendWaitMax"] = max(v["sendWaitMax"] as? Double ?? 0, wait)
      }
    }
  }
  func finish(outcome: Int) {
    let row = lock.withLock { () -> [String: Any]? in
      guard !sealed else { return nil }
      sealed = true; values["terminal"] = ProcessInfo.processInfo.systemUptime
      values["outcome"] = Double(outcome)
      return values
    }
    if let row { observer(row) }
  }
}
#endif
'''
p.write_text(s)
