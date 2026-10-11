import Foundation

@main
enum ReadinessTraceTests {
  static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: message, code: 1) }
  }

  static func main() throws {
    // A long queue wait and a slow ready getter must not become indistinguishable.
    var trace = YlTimedVideoReadinessTrace()
    trace.recordCheck(requested: 10, entered: 10.08, began: 10.081,
                      returned: 10.082, ready: false, threadID: 410)
    trace.recordCheck(requested: 10.09, entered: 10.09, began: 10.091,
                      returned: 10.119, ready: true, threadID: 411)
    try require(trace.values["check0Requested"] == 10, "queue request time missing")
    try require(trace.values["check0Entered"] == 10.08, "queue entry time missing")
    try require(trace.values["check0Began"] == 10.081, "getter start time missing")
    try require(trace.values["check1Returned"] == 10.119, "getter return time missing")
    try require(trace.values["check0Ready"] == 0 && trace.values["check1Ready"] == 1, "observed readiness lost")
    try require(trace.values["check0ThreadID"] == 410 && trace.values["check1ThreadID"] == 411, "thread pool handoff lost")

    // Registration and callback stop/read work are distinct from callback delivery.
    trace.recordRegistration(began: 10.083, returned: 10.084, threadID: 410)
    trace.recordCallback(entered: 10.11, stopReturned: 10.112,
                         readyReturned: 10.113, ready: true, threadID: 415)
    try require(trace.values["registrationReturned"] == 10.084, "registration boundary missing")
    try require(trace.values["callbackEntered"] == 10.11, "callback entry missing")
    try require(trace.values["callbackStopReturned"] == 10.112, "stopRequesting boundary missing")
    try require(trace.values["callbackReadyReturned"] == 10.113, "callback ready read boundary missing")
    try require(trace.values["callbackThreadID"] == 415, "callback thread missing")
    trace.recordRegistration(began: 10.12, returned: 10.121, threadID: 416)
    trace.recordCallback(entered: 10.13, stopReturned: 10.131,
                         readyReturned: 10.132, ready: false, threadID: 417)
    try require(trace.values["firstRegistrationBegan"] == 10.083 && trace.values["registrationCount"] == 2, "repeated registration hidden")
    try require(trace.values["firstCallbackEntered"] == 10.11 && trace.values["callbackCount"] == 2, "repeated callback hidden")
    try require(trace.values["callbackReady"] == 0 && trace.values["callbackThreadID"] == 417, "latest callback observation stale")

    // A pathological wait cannot grow unbounded or silently lose its final check.
    var prolonged = YlTimedVideoReadinessTrace()
    for index in 0..<10_000 {
      let time = Double(index)
      prolonged.recordCheck(requested: time, entered: time, began: time,
                            returned: time, ready: index == 9_999, threadID: 500)
    }
    try require(prolonged.values["readyCheckCount"] == 10_000, "total count truncated")
    try require(prolonged.values["check0Returned"] == 0, "first observation overwritten")
    try require(prolonged.values["lastCheckReturned"] == 9_999, "final observation lost")
    try require(prolonged.values["lastCheckReady"] == 1, "final ready state lost")
    try require((prolonged.values["omittedCheckCount"] ?? 0) > 0, "truncation hidden")
    try require(prolonged.values.count < 220, "diagnostic memory grows with wait length")
    try require(YlTimedVideoReadinessTrace().values.isEmpty, "new frame inherits previous evidence")
    print("Readiness evidence boundaries, thread handoff, bounded retention: PASS")
  }
}
