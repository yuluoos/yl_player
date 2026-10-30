from pathlib import Path
p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsMediaProxy.swift');s=p.read_text();s=s.replace('  private var diagnosticActiveTraces: [ObjectIdentifier: YlHlsProxyRequestTrace] = [:]','  private var diagnosticActiveTraces: [ObjectIdentifier: YlHlsProxyRequestTrace] = [:]\n  private var diagnosticTaskTraces: [Int: YlHlsProxyRequestTrace] = [:]');s=s.replace('''        taskRecords[task.taskIdentifier]?.trace = diagnosticTrace
        diagnosticActiveTraces[connectionID] = diagnosticTrace''','''        diagnosticTrace.attachTask()
        taskRecords[task.taskIdentifier]?.trace = diagnosticTrace
        diagnosticTaskTraces[task.taskIdentifier] = diagnosticTrace
        diagnosticActiveTraces[connectionID] = diagnosticTrace''');s=s.replace('let trace = lock.withLock { taskRecords[task.taskIdentifier]?.trace }','let trace = lock.withLock { diagnosticTaskTraces[task.taskIdentifier] }');needle='''  ) {
    let outcome = lock.withLock { () -> (TaskRecord, Error?)? in''';repl='''  ) {
    #if DEBUG
    // Cancelling playback removes TaskRecord immediately. Diagnostic ownership
    // survives until Foundation delivers metrics and its terminal callback.
    let diagnosticTrace = lock.withLock { diagnosticTaskTraces.removeValue(forKey: task.taskIdentifier) }
    let diagnosticError = error as NSError?
    diagnosticTrace?.taskCompleted(outcome: error == nil ? 0 :
      (diagnosticError?.domain == NSURLErrorDomain && diagnosticError?.code == NSURLErrorCancelled ? 1 : 2))
    #endif
    let outcome = lock.withLock { () -> (TaskRecord, Error?)? in''';assert needle in s;s=s.replace(needle,repl)
s=s.replace('/// Completion is sealed before invoking the observer; late callbacks are ignored.','/// Transport completion freezes send/body fields. Delivery additionally waits\n/// for the attached Foundation task; late transport callbacks stay ignored.')
s=s.replace('  private var sealed = false\n  private var values:', '  private var sealed = false\n  private var downstreamFinished = false\n  private var taskPending = false\n  private var values:')
s=s.replace('values = ["version": 3,','values = ["version": 4,')
s=s.replace('''  private func update(_ action: (inout [String: Any], Double) -> Void) {
    lock.withLock {
      guard !sealed else { return }
      action''','''  private func update(allowAfterDownstream: Bool = false, _ action: (inout [String: Any], Double) -> Void) {
    lock.withLock {
      guard !sealed && (allowAfterDownstream || !downstreamFinished) else { return }
      action''')
s=s.replace('''    update { v, _ in
      v["metrics"]''','''    update(allowAfterDownstream: true) { v, _ in
      v["metrics"]''')
start=s.index('  func finish(outcome: Int) {',s.index('final class YlHlsProxyRequestTrace'))
end=s.index('\n}\n#endif',start)
s=s[:start]+'''  func attachTask() {
    lock.withLock { if !sealed && !downstreamFinished { taskPending = true } }
  }
  private func completedRow() -> [String: Any]? {
    guard !sealed && downstreamFinished && !taskPending else { return nil }
    sealed = true; values["terminal"] = ProcessInfo.processInfo.systemUptime
    return values
  }
  func taskCompleted(outcome: Int) {
    let row = lock.withLock { () -> [String: Any]? in
      guard !sealed && taskPending else { return nil }
      taskPending = false
      values["taskComplete"] = ProcessInfo.processInfo.systemUptime
      values["taskOutcome"] = outcome
      return completedRow()
    }
    if let row { observer(row) }
  }
  func finish(outcome: Int) {
    let row = lock.withLock { () -> [String: Any]? in
      guard !sealed && !downstreamFinished else { return nil }
      downstreamFinished = true
      values["downstreamTerminal"] = ProcessInfo.processInfo.systemUptime
      values["outcome"] = Double(outcome)
      return completedRow()
    }
    if let row { observer(row) }
  }'''+s[end:];p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text().replace('"proxyRequestSamplingVersion": 3','"proxyRequestSamplingVersion": 4').replace('XCTAssertEqual(row["version"] as? Int, 3)','XCTAssertEqual(row["version"] as? Int, 4)');start=s.index('  func testProxyRequestTimingSealsCancellationAndIgnoresLateSendCompletion()');end=s.index('\n  func ',start+10);part=s[start:end].replace('    trace.response(status:', '    trace.attachTask()\n    trace.response(status:').replace('''    trace.finish(outcome: 0)
    XCTAssertEqual(rows.count, 1)''','''    trace.finish(outcome: 0)
    XCTAssertTrue(rows.isEmpty, "Cancellation delivery waits for task settlement, not late sends")
    trace.taskCompleted(outcome: 1)
    trace.taskCompleted(outcome: 0)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0]["taskOutcome"] as? Int, 1)''');s=s[:start]+part+s[end:];p.write_text(s)
for platform in ['ios','macos']:Path('packages/yl_player/example',platform,'RunnerTests/YlDashResourceLoaderTests.swift').write_text('@testable import yl_player_media_core\n'+s)
