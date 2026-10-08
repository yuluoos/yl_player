import Foundation
struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw Failure(message: message) }
}
final class Payload { let id: Int; init(_ id: Int) { self.id = id } }
typealias Model = AudioTerminalBudgetPrototype<Payload>
func make(_ count: Int = 4, bytes: Int = 40, duration: Int64 = 40) throws -> (Model,YlManagedBufferScope) {
  let ledger = YlManagedBufferLedger(maxBytes: bytes)
  let scope = try ledger.makeScope(maxBytes: bytes)
  scope.configureTimeline(try YlBoundedBufferPlan(minDurationMs: 0, maxDurationMs: 1, maxBytes: 4*1024*1024))
  return (Model(scope: scope, maxCount: count, maxBytes: bytes, maxDurationUs: duration),scope)
}
func add(_ q: Model,_ id: Int) -> Model.Admission {
  q.enqueue(ptsUs: Int64(id*10), durationUs: 10, bytes: 10) { Payload(id) }
}
func release(_ q: Model,_ actions: [Model.Submission]) {
  for a in actions { if a.isTerminal { q.playedBack(a.ticket) } else { q.rendered(a.ticket) } }
}
let tests: [(String, () throws -> Void)] = [
  ("resource_retires_real_bytes_and_timing_but_not_output", {
    let (q,scope)=try make(); _=add(q,0);_=add(q,1)
    let a=q.takeSubmissions(); weak var pcm=a[0].payload
    try check(pcm != nil && scope.ledger.snapshot.currentBytes == 20, "PCM not charged")
    q.rendered(a[0].ticket)
    try check(pcm == nil && a[0].payload == nil, "resource still owns PCM")
    try check(scope.ledger.snapshot.currentBytes == 10 && scope.bufferedDurationUs == 10, "real ledger not retired")
    try check(!q.drained && q.pendingCount == 1, "rendered falsely drained")
    q.finishInput(); let tail=q.takeSubmissions()[0]
    q.rendered(tail.ticket); try check(!q.drained && scope.ledger.snapshot.currentBytes == 10, "rendered forged final playback")
    q.playedBack(tail.ticket); try check(q.drained && scope.ledger.snapshot.currentBytes == 0, "tail failed drain")
  }),
  ("single_and_empty_input_use_no_sentinel", {
    let (empty,_)=try make();empty.finishInput();try check(empty.drained && empty.takeSubmissions().isEmpty,"empty sentinel")
    let (q,_)=try make();_=add(q,1);q.finishInput();q.finishInput();let a=q.takeSubmissions()
    try check(a.count == 1 && a[0].isTerminal && a[0].payload?.id == 1 && !q.drained,"wrong real tail")
    try check(add(q,2) == .finished,"admitted after EOF");q.playedBack(a[0].ticket);try check(q.drained,"single tail pending")
  }),
  ("long_input_uses_only_one_terminal_fence_and_bounded_metadata", {
    let (q,scope)=try make(); var terminal=0
    for i in 0..<10000 {
      try check(add(q,i) == .accepted,"producer cannot progress before EOF")
      let a=q.takeSubmissions();terminal += a.filter(\.isTerminal).count; release(q,a)
      try check(q.pendingCount == 1 && scope.ledger.snapshot.currentBytes == 10,"metadata/byte history grew")
    }
    try check(terminal == 0 && !q.drained,"intermediate final callback")
    q.finishInput();let a=q.takeSubmissions();terminal += a.filter(\.isTerminal).count;release(q,a)
    try check(terminal == 1 && q.drained && scope.ledger.snapshot.currentBytes == 0,"missing final fence")
  }),
  ("starvation_holds_charged_tail_then_resumes", {
    let (q,scope)=try make();_=add(q,0);_=add(q,1);release(q,q.takeSubmissions())
    for _ in 0..<100 { try check(q.takeSubmissions().isEmpty && !q.drained,"starvation fabricated submission/completion") }
    try check(scope.ledger.snapshot.currentBytes == 10 && scope.bufferedDurationUs == 10,"held tail uncharged")
    _=add(q,2);let a=q.takeSubmissions();try check(a.count == 1 && a[0].payload?.id == 1 && !a[0].isTerminal,"resume lost tail")
    release(q,a);q.finishInput();release(q,q.takeSubmissions());try check(q.drained,"resume not drained")
  }),
  ("backpressure_and_insufficient_lookahead_are_distinct", {
    let (q,_)=try make(2);_=add(q,0);_=add(q,1)
    try check(add(q,2) == .backpressure,"in-flight bound bypassed");release(q,q.takeSubmissions())
    try check(add(q,2) == .accepted,"rendered did not resume admission")
    let (tiny,_)=try make(1);_=add(tiny,0)
    try check(add(tiny,1) == .insufficientLookahead,"permanent deadlock hidden as retry")
    let (bytes,_)=try make(4,bytes:15);_=add(bytes,0)
    try check(add(bytes,1) == .insufficientLookahead,"byte lookahead deadlock")
    let (duration,_)=try make(4,duration:15);_=add(duration,0)
    try check(add(duration,1) == .insufficientLookahead,"duration lookahead deadlock")
  }),
  ("missing_and_reordered_notifications_cannot_fake_drain", {
    let (q,scope)=try make();for i in 0..<3 { _=add(q,i) };q.finishInput();let a=q.takeSubmissions()
    q.playedBack(a[0].ticket);try check(q.pendingCount == 3,"ordinary ticket accepted as terminal")
    q.playedBack(a[2].ticket);q.playedBack(a[2].ticket)
    try check(!q.drained && scope.ledger.snapshot.currentBytes == 20,"final swept missing resources")
    q.rendered(a[1].ticket);q.rendered(a[1].ticket);try check(q.pendingCount == 1,"duplicate retired another item")
    q.rendered(a[0].ticket);try check(q.drained,"delayed resource did not drain")
  }),
  ("reset_after_stop_releases_payload_and_ignores_old_tickets", {
    let (q,scope)=try make();_=add(q,0);q.finishInput();let old=q.takeSubmissions()[0];weak var pcm=old.payload
    q.resetAfterOutputStop();try check(pcm == nil && old.payload == nil && scope.ledger.snapshot.currentBytes == 0,"reset ownership leak")
    _=add(q,1);q.finishInput();let fresh=q.takeSubmissions()[0]
    q.playedBack(old.ticket);q.rendered(old.ticket);try check(q.pendingCount == 1 && !q.drained,"stale completion touched new generation")
    q.playedBack(fresh.ticket);try check(q.drained,"fresh tail stalled")
  }),
  ("allocation_is_deferred_until_actual_ledger_admission", {
    let (q,scope)=try make();var allocations=0
    let external=scope.reserve(category:.scheduledAudio,bytes:40)!
    let denied=q.enqueue(ptsUs:0,durationUs:10,bytes:10) { allocations += 1;return Payload(0) }
    try check(denied == .ledgerLimited && allocations == 0 && q.pendingCount == 0,"allocation before reserve")
    external.release()
    try check(add(q,0) == .accepted,"ledger release could not resume")
    try check(q.enqueue(ptsUs:Int64.max,durationUs:10,bytes:10) { allocations += 1;return Payload(1) } == .invalid,"PTS overflow admitted")
    try check(allocations == 0,"invalid item allocated")
  }),
  ("real_timeline_span_can_refuse_large_PTS_gap", {
    let (q,scope)=try make();_=add(q,0)
    try check(q.enqueue(ptsUs:2000,durationUs:10,bytes:10) { Payload(1) } == .timelineLimited,"timeline bypassed")
    try check(scope.ledger.snapshot.currentBytes == 10 && q.pendingCount == 1,"failed timing admission leaked bytes")
  }),
  ("EOF_enqueue_and_callback_delivery_share_serial_executor", {
    let serial=DispatchQueue(label:"terminal-budget-test");let (q,scope)=try make(200,bytes:2000,duration:2000)
    let group=DispatchGroup();var accepted=0
    for i in 0..<60 {
      group.enter();DispatchQueue.global().async {
        serial.sync {
          if i == 30 { q.finishInput() }
          else if q.enqueue(ptsUs:0,durationUs:10,bytes:10,makePayload:{ Payload(i) }) == .accepted { accepted += 1 }
          release(q,q.takeSubmissions())
        };group.leave()
      }
    }
    group.wait();try serial.sync {
      q.finishInput();release(q,q.takeSubmissions())
      try check(q.drained && scope.ledger.snapshot.currentBytes == 0 && accepted <= 59,"serialized EOF race lost resource")
    }
  }),
]
var result:[[String:Any]]=[]
for (name,test) in tests {
  do { try test();result.append(["name":name,"passed":true]) }
  catch { result.append(["name":name,"passed":false,"error":String(describing:error)]) }
}
print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
if result.contains(where:{$0["passed"] as? Bool == false}) { exit(1) }
