import Foundation

/// Diagnostic-only scalar evidence; the endpoint's serial queue owns this value.
struct YlTimedVideoReadinessTrace {
  private(set) var values: [String: Double] = [:]
  private var count = 0

  mutating func recordCheck(requested: TimeInterval, entered: TimeInterval,
                            began: TimeInterval, returned: TimeInterval,
                            ready: Bool, threadID: UInt64) {
    let check = ["Requested": requested, "Entered": entered, "Began": began,
                 "Returned": returned, "Ready": ready ? 1.0 : 0.0,
                 "ThreadID": Double(threadID)]
    if count < 32 {
      for (key, value) in check { values["check\(count)\(key)"] = value }
    }
    for (key, value) in check { values["lastCheck\(key)"] = value }
    count += 1
    values["readyCheckCount"] = Double(count)
    values["omittedCheckCount"] = Double(max(0, count - 32))
  }

  mutating func recordRegistration(began: TimeInterval, returned: TimeInterval,
                                   threadID: UInt64) {
    values["registrationCount", default: 0] += 1
    values["firstRegistrationBegan"] = values["firstRegistrationBegan"] ?? began
    values["registrationBegan"] = began
    values["registrationReturned"] = returned
    values["registrationThreadID"] = Double(threadID)
  }

  mutating func recordCallback(entered: TimeInterval, stopReturned: TimeInterval,
                               readyReturned: TimeInterval, ready: Bool,
                               threadID: UInt64) {
    values["callbackCount", default: 0] += 1
    values["firstCallbackEntered"] = values["firstCallbackEntered"] ?? entered
    values["callbackEntered"] = entered
    values["callbackStopReturned"] = stopReturned
    values["callbackReadyReturned"] = readyReturned
    values["callbackReady"] = ready ? 1 : 0
    values["callbackThreadID"] = Double(threadID)
  }
}
