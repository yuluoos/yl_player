import Foundation

struct TestFailure: Error { let message: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw TestFailure(message: message) }
}
func evidence(_ time: UInt64, _ delay: UInt64 = 50, _ quantum: UInt64 = 20,
              route: UInt64 = 1) -> AudioRetirementPrototype.Evidence {
  .init(observedUs: time, downstreamUs: delay, quantumUs: quantum, route: route)
}
func drain(_ queue: AudioRetirementPrototype, _ now: UInt64) {
  for callback in queue.poll(nowUs: now) { callback() }
}

let tests: [(String, () throws -> Void)] = [
  ("deadline_and_duplicate_delivery", {
    let q = AudioRetirementPrototype(generation: 1, route: 1)
    q.observe(evidence(100), nowUs: 100)
    var count = 0
    let t = AudioRetirementPrototype.Ticket(generation: 1) { count += 1 }
    try require(q.rendered(t, atUs: 100, nowUs: 100), "first admission")
    try require(!q.rendered(t, atUs: 100, nowUs: 100), "duplicate admission")
    drain(q, 169); try require(count == 0, "early callback")
    drain(q, 170); drain(q, 180)
    try require(!q.rendered(t, atUs: 100, nowUs: 180), "retired ticket reused")
    try require(count == 1 && q.pendingCount == 0, "not exactly once")
  }),
  ("host_deadline_without_player_time_or_rate", {
    let q = AudioRetirementPrototype(generation: 1, route: 1)
    q.observe(evidence(100), nowUs: 100)
    var count = 0
    _ = q.rendered(.init(generation: 1) { count += 1 }, atUs: 100, nowUs: 100)
    // The model uses host time; no paused player timestamp or rate scaling is needed.
    q.observe(evidence(150), nowUs: 150)
    drain(q, 170)
    try require(count == 1, "in-flight completion incorrectly frozen")
  }),
  ("latency_increase_extends_and_decrease_never_shortens", {
    let q = AudioRetirementPrototype(generation: 1, route: 1)
    q.observe(evidence(100), nowUs: 100)
    var count = 0
    _ = q.rendered(.init(generation: 1) { count += 1 }, atUs: 100, nowUs: 100)
    q.observe(evidence(120,100), nowUs: 120)
    q.observe(evidence(140,10), nowUs: 140)
    drain(q, 170); try require(count == 0, "deadline shortened")
    drain(q, 220); try require(count == 1, "extended deadline missing")
  }),
  ("unknown_latency_blocks_until_confirmed_stop", {
    let q = AudioRetirementPrototype(generation: 1, route: 1)
    q.observe(evidence(100), nowUs: 100)
    var count = 0
    _ = q.rendered(.init(generation: 1) { count += 1 }, atUs: 100, nowUs: 100)
    q.observe(nil, nowUs: 110)
    q.observe(evidence(120), nowUs: 120)
    drain(q, 1000)
    try require(count == 0 && q.failure == .unknownLatency && q.pendingCount == 1, "unknown latency admitted")
    q.resetAfterOutputStop(generation: 2, route: 1, nowUs: 1000)
    try require(q.pendingCount == 0 && q.failure == nil, "confirmed stop did not clear")
  }),
  ("zero_latency_is_unknown", {
    let q = AudioRetirementPrototype(generation: 1, route: 1)
    q.observe(evidence(100,0), nowUs: 100)
    try require(q.failure == .unknownLatency, "zero SDK latency treated as known")
  }),
  ("route_change_blocks_and_old_generation_is_ignored", {
    let q = AudioRetirementPrototype(generation: 1, route: 1)
    q.observe(evidence(100), nowUs: 100)
    var old = 0; var fresh = 0
    let ticket = AudioRetirementPrototype.Ticket(generation: 1) { old += 1 }
    _ = q.rendered(ticket, atUs: 100, nowUs: 100)
    q.observe(evidence(120,route: 2), nowUs: 120)
    drain(q, 200); try require(old == 0 && q.failure == .routeChanged, "route change admitted")
    q.resetAfterOutputStop(generation: 2, route: 2, nowUs: 200)
    q.observe(evidence(200,route: 2), nowUs: 200)
    try require(!q.rendered(ticket, atUs: 100, nowUs: 200), "stale ticket admitted")
    _ = q.rendered(.init(generation: 2) { fresh += 1 }, atUs: 200, nowUs: 200)
    drain(q, 270)
    try require(old == 0 && fresh == 1, "generation isolation failed")
  }),
  ("out_of_order_notifications_use_own_render_timestamp", {
    let q = AudioRetirementPrototype(generation: 1, route: 1)
    q.observe(evidence(100), nowUs: 100)
    var ids: [Int] = []
    _ = q.rendered(.init(generation: 1) { ids.append(2) }, atUs: 100, nowUs: 100)
    _ = q.rendered(.init(generation: 1) { ids.append(1) }, atUs: 90, nowUs: 100)
    drain(q, 160); try require(ids == [1], "wrong render timestamp")
    drain(q, 170); try require(ids == [1,2], "missing later delivery")
  }),
  ("capacity_failure_does_not_complete_or_grow_queue", {
    let q = AudioRetirementPrototype(generation: 1, route: 1, capacity: 2)
    q.observe(evidence(100), nowUs: 100)
    var count = 0
    for _ in 0..<3 { _ = q.rendered(.init(generation: 1) { count += 1 }, atUs: 100, nowUs: 100) }
    drain(q, 200)
    try require(q.pendingCount == 2 && q.peakPending == 2 && q.failure == .capacityExceeded && count == 0, "capacity bypass")
  }),
  ("clock_regression_blocks", {
    let q = AudioRetirementPrototype(generation: 1, route: 1)
    q.observe(evidence(100), nowUs: 100)
    drain(q, 99)
    try require(q.failure == .clockRegressed, "regressed clock admitted")
  }),
  ("stale_evidence_blocks", {
    let q = AudioRetirementPrototype(generation: 1, route: 1, maxEvidenceAgeUs: 20)
    q.observe(evidence(100), nowUs: 100)
    var count = 0
    _ = q.rendered(.init(generation: 1) { count += 1 }, atUs: 100, nowUs: 100)
    drain(q, 121)
    try require(q.failure == .staleEvidence && count == 0, "stale evidence admitted")
  }),
  ("deadline_overflow_blocks", {
    let q = AudioRetirementPrototype(generation: 1, route: 1)
    q.observe(evidence(UInt64.max-10), nowUs: UInt64.max-10)
    _ = q.rendered(.init(generation: 1) {}, atUs: UInt64.max-10, nowUs: UInt64.max-10)
    try require(q.failure == .overflow, "wrapped deadline admitted")
  }),
  ("increased_latency_revokes_ready_delivery", {
    let q = AudioRetirementPrototype(generation: 1, route: 1)
    q.observe(evidence(100), nowUs: 100)
    var count = 0
    _ = q.rendered(.init(generation: 1) { count += 1 }, atUs: 100, nowUs: 100)
    let ready = q.poll(nowUs: 170)
    q.observe(evidence(170,100), nowUs: 170)
    ready.forEach { $0() }
    try require(count == 0 && q.pendingCount == 1, "old ready delivery bypassed extension")
    drain(q, 220)
    try require(count == 1, "extended ready callback missing")
  }),
  ("failed_queue_retains_payload_until_confirmed_stop", {
    let q = AudioRetirementPrototype(generation: 1, route: 1)
    q.observe(evidence(100), nowUs: 100)
    var object: NSObject? = NSObject()
    weak var weakObject = object
    _ = q.rendered(.init(generation: 1) { [value = object!] in withExtendedLifetime(value) {} }, atUs: 100, nowUs: 100)
    object = nil
    q.observe(nil, nowUs: 110)
    drain(q, 200)
    try require(weakObject != nil, "payload released during unresolved output")
    q.resetAfterOutputStop(generation: 2, route: 1, nowUs: 200)
    try require(weakObject == nil, "stopped payload retained")
  }),
  ("ready_callbacks_respect_reentrant_generation_reset", {
    let q = AudioRetirementPrototype(generation: 1, route: 1)
    q.observe(evidence(100), nowUs: 100)
    var count = 0
    _ = q.rendered(.init(generation: 1) {
      count += 1
      q.resetAfterOutputStop(generation: 2, route: 1, nowUs: 170)
    }, atUs: 100, nowUs: 100)
    _ = q.rendered(.init(generation: 1) { count += 100 }, atUs: 100, nowUs: 100)
    drain(q, 170)
    try require(count == 1, "ready old-generation callback delivered")
  })
]

var results: [[String: Any]] = []
for (name, test) in tests {
  do { try test(); results.append(["name": name, "passed": true]) }
  catch { results.append(["name": name, "passed": false, "error": String(describing: error)]) }
}
let data = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
exit(results.allSatisfy { $0["passed"] as? Bool == true } ? 0 : 1)
