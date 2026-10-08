import Foundation

struct Failure: Error { let message: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw Failure(message: message) }
}
typealias Model = AudioBoundaryPrototype<Int>
func model(group: Int = 4, count: Int = 8, bytes: Int = 80, duration: Int64 = 80) -> Model {
  Model(groupSize: group, maxCount: count, maxBytes: bytes, maxDurationUs: duration)
}
func add(_ q: Model, _ value: Int) -> Model.Admission {
  q.enqueue(value, bytes: 10, durationUs: 10)
}
func notify(_ q: Model, _ actions: [Model.Submission]) {
  for a in actions {
    if a.isBoundary { q.playedBack(a.ticket) } else { q.resourcesReleased(a.ticket) }
  }
}
let tests: [(String, () throws -> Void)] = [
  ("empty_and_single_real_tail", {
    let empty = model(); empty.finishInput(); empty.finishInput()
    try require(empty.drained && empty.takeSubmissions().isEmpty, "empty inserted a sentinel")
    let q = model(); try require(add(q, 7) == .accepted, "single admission")
    try require(q.takeSubmissions().isEmpty && q.pendingCount == 1, "lookahead not owned")
    q.finishInput(); let a = q.takeSubmissions()
    try require(a.count == 1 && a[0].payload == 7 && a[0].isBoundary && !q.drained, "tail missing")
    try require(add(q, 8) == .finished, "accepted after EOF")
    q.playedBack(a[0].ticket); try require(q.drained, "short stream not drained")
  }),
  ("rendered_does_not_retire_conservative_budget", {
    let q = model(); for i in 0..<4 { _ = add(q, i) }
    let a = q.takeSubmissions()
    try require(a.map(\.payload) == [0,1,2,3] && a.filter(\.isBoundary).count == 1, "wrong scheduling order")
    for item in a { q.resourcesReleased(item.ticket) }
    try require(q.pendingCount == 4 && q.pendingBytes == 40 && q.pendingDurationUs == 40, "early budget retirement")
    q.playedBack(a[0].ticket)
    try require(q.pendingCount == 4, "ordinary callback forged boundary")
    q.playedBack(a.last!.ticket); try require(q.pendingCount == 0, "group budget not released")
  }),
  ("capacity_seals_tail_before_refusing_next", {
    let q = model(group: 99, count: 3)
    for i in 0..<3 { _ = add(q, i) }
    try require(add(q, 3) == .backpressure, "capacity exceeded")
    let a = q.takeSubmissions()
    try require(a.count == 3 && a.last!.isBoundary && q.pendingCount == 3, "tail stranded at backpressure")
    notify(q, a); try require(add(q, 3) == .accepted, "never resumed after boundary")
  }),
  ("long_live_input_remains_bounded_without_EOF", {
    let q = model(); var pending: [Model.Submission] = []
    for i in 0..<10000 {
      if add(q, i) == .backpressure {
        pending += q.takeSubmissions(); notify(q, pending); pending.removeAll()
        try require(add(q, i) == .accepted, "live producer deadlocked")
      }
      pending += q.takeSubmissions()
      try require(q.pendingCount <= 8 && q.pendingBytes <= 80 && q.pendingDurationUs <= 80, "unbounded admission")
    }
    q.sealBoundary(); pending += q.takeSubmissions(); notify(q, pending)
    try require(q.pendingCount == 0 && !q.drained, "live input falsely ended")
    q.finishInput(); try require(q.drained, "EOF after all fences should drain")
  }),
  ("byte_duration_and_invalid_single_item_limits", {
    let bytes = model(group: 99, bytes: 15); _ = add(bytes, 1)
    try require(add(bytes, 2) == .backpressure && bytes.takeSubmissions().last!.isBoundary, "byte limit")
    let duration = model(group: 99, duration: 15); _ = add(duration, 1)
    try require(add(duration, 2) == .backpressure && duration.takeSubmissions().last!.isBoundary, "duration limit")
    let q = model()
    for pair: (Int, Int64) in [(-1,1),(0,1),(1,-1),(81,1),(1,81)] {
      try require(q.enqueue(0, bytes: pair.0, durationUs: pair.1) == .invalid, "invalid item admitted")
    }
    try require(q.pendingCount == 0, "invalid item reserved memory")
  }),
  ("overflow_and_zero_duration_are_count_bounded", {
    let q = model(group: 99, count: 2, bytes: Int.max, duration: Int64.max)
    _ = q.enqueue(1, bytes: Int.max, durationUs: Int64.max)
    try require(q.enqueue(2, bytes: 1, durationUs: 1) == .backpressure, "overflow bypassed limit")
    let zero = model(group: 99, count: 2)
    for i in 0..<2 { _ = zero.enqueue(i, bytes: 1, durationUs: 0) }
    try require(zero.enqueue(2, bytes: 1, durationUs: 0) == .backpressure, "zero duration unbounded")
    zero.finishInput(); try require(!zero.drained, "zero duration falsely drained")
    notify(zero, zero.takeSubmissions()); try require(zero.drained, "zero duration fence lost")
  }),
  ("paused_EOF_requires_real_completion", {
    let q = model(); _ = add(q, 1); _ = add(q, 2)
    q.finishInput(); let a = q.takeSubmissions()
    // No synthetic pause/time event can produce a playback notification.
    for item in a { q.resourcesReleased(item.ticket) }
    try require(!q.drained && q.pendingCount == 2, "paused EOF drained from render events")
    q.playedBack(a.last!.ticket); try require(q.drained, "in-flight paused completion blocked")
  }),
  ("out_of_order_duplicate_and_missing_fences", {
    let q = model(group: 2); for i in 0..<4 { _ = add(q, i) }; q.finishInput()
    let a = q.takeSubmissions(); q.playedBack(a[3].ticket); q.playedBack(a[3].ticket)
    try require(q.pendingCount == 2 && !q.drained, "later fence completed earlier group")
    q.resourcesReleased(a[1].ticket); try require(!q.drained, "missing fence fabricated")
    q.playedBack(a[1].ticket); try require(q.drained, "remaining fence not retired")
  }),
  ("reset_after_stop_ignores_old_generation", {
    let q = model(); _ = add(q, 1); q.finishInput(); let old = q.takeSubmissions()[0]
    q.resetAfterOutputStop(); _ = add(q, 2); q.finishInput(); let fresh = q.takeSubmissions()[0]
    q.playedBack(old.ticket); q.resourcesReleased(old.ticket)
    try require(q.pendingCount == 1 && !q.drained, "stale generation retired fresh input")
    q.playedBack(fresh.ticket); try require(q.drained, "fresh generation stalled")
  }),
  ("starved_producer_can_seal_without_EOF", {
    let q = model(); _ = add(q, 1); q.sealBoundary(); q.sealBoundary()
    let a = q.takeSubmissions(); try require(a.count == 1 && a[0].isBoundary, "starved tail stranded/duplicated")
    notify(q, a); _ = add(q, 2); q.finishInput(); let b = q.takeSubmissions()
    try require(b.count == 1 && b[0].payload == 2, "producer could not resume")
    notify(q,b); try require(q.drained, "final tail not drained")
  }),
  ("EOF_enqueue_race_is_serialized_without_lost_tail", {
    let serial = DispatchQueue(label: "boundary-test")
    let q = model(group: 99, count: 100, bytes: 1000, duration: 1000)
    let group = DispatchGroup(); var accepted = 0
    for i in 0..<100 {
      group.enter(); DispatchQueue.global().async {
        serial.sync {
          if i == 50 { q.finishInput() }
          else if add(q, i) == .accepted { accepted += 1 }
        }; group.leave()
      }
    }
    group.wait()
    try serial.sync {
      q.finishInput(); let a = q.takeSubmissions()
      try require(a.count == accepted && a.filter(\.isBoundary).count <= 1, "race lost/duplicated submissions")
      notify(q,a); try require(q.drained, "race lost final completion")
    }
  }),
  ("payload_owned_only_until_submission_or_stopped_reset", {
    final class Payload {}
    let q = AudioBoundaryPrototype<Payload>(groupSize: 4, maxCount: 8, maxBytes: 80, maxDurationUs: 80)
    weak var weakPayload: Payload?
    do { let p = Payload(); weakPayload = p; _ = q.enqueue(p, bytes: 10, durationUs: 10) }
    try require(weakPayload != nil, "unscheduled tail lost payload")
    q.resetAfterOutputStop(); try require(weakPayload == nil, "reset retained tail")
    do { let p = Payload(); weakPayload = p; _ = q.enqueue(p, bytes: 10, durationUs: 10) }
    q.finishInput()
    do { let a = q.takeSubmissions(); try require(weakPayload === a[0].payload, "wrong submitted payload") }
    try require(weakPayload == nil && q.pendingCount == 1, "metadata retained PCM or retired early")
  }),
]
var results: [[String: Any]] = []
for (name, body) in tests {
  do { try body(); results.append(["name":name,"passed":true]) }
  catch { results.append(["name":name,"passed":false,"error":String(describing:error)]) }
}
print(String(decoding: try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]), as: UTF8.self))
if results.contains(where: { $0["passed"] as? Bool == false }) { exit(1) }
