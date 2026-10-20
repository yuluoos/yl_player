@testable import yl_player_media_core
@testable import yl_player_apple
import Foundation
import XCTest

final class YlRtmpRecoveryTests: XCTestCase {
  func testPausePlayBetweenAdmissionChecksCannotLoseReservedAttempt() {
    let budget=YlRtmpRecoveryBudget(),scheduler=RtmpRecoveryScheduler(),session=RtmpRecoverySession()
    let recovery=YlRecoveryCoordinator(configuration:.init(map:[:]),scheduler:scheduler,rtmpBudget:budget)
    recovery.session=session
    recovery.scheduleLiveReconnect(after:session.transient,generation:1)
    session.pausePlayAtNextAdmission=true
    session.completeOpenPermanently=true
    scheduler.runNext()
    session.runReadyContinuations()
    XCTAssertEqual(session.opens,1,"play must observe the saved attempt or admission must succeed")
    XCTAssertEqual(budget.attempts,1,"the same reserved attempt must resume without another debit")
    XCTAssertEqual(scheduler.delays,[500])
    XCTAssertFalse(session.reconfiguring,"eventual open/terminal completion cannot leave recovery stuck")
    XCTAssertEqual(session.terminal?.code,"container.rtmp_track_layout_changed")
  }
  func testDeferredAdmissionRejectsStaleGenerationAndDisposedSession() {
    for disposed in [false,true] {
      let budget=YlRtmpRecoveryBudget(),scheduler=RtmpRecoveryScheduler(),session=RtmpRecoverySession()
      let recovery=YlRecoveryCoordinator(configuration:.init(map:[:]),scheduler:scheduler,rtmpBudget:budget)
      recovery.session=session
      recovery.scheduleLiveReconnect(after:session.transient,generation:1)
      session.paused=true;scheduler.runNext()
      if disposed {session.disposed=true} else {session.currentGeneration=2}
      session.paused=false;session.resumeDeferred()
      XCTAssertEqual(session.opens,0);XCTAssertEqual(budget.attempts,1)
      XCTAssertNil(session.deferred)
    }
  }
  func testPauseDefersReservedAttemptWithoutChargingAgainAndCancellationFencesResume() {
    let budget=YlRtmpRecoveryBudget(), scheduler=RtmpRecoveryScheduler(), session=RtmpRecoverySession()
    let recovery=YlRecoveryCoordinator(configuration:.init(map:[:]),scheduler:scheduler,rtmpBudget:budget)
    recovery.session=session
    recovery.scheduleLiveReconnect(after:session.transient,generation:1)
    session.paused=true;scheduler.runNext()
    XCTAssertEqual(session.opens,0);XCTAssertEqual(budget.attempts,1)
    session.paused=false;session.resumeDeferred()
    XCTAssertEqual(session.opens,1);XCTAssertEqual(budget.attempts,2)
    session.paused=true;scheduler.runNext()
    XCTAssertEqual(session.opens,1);XCTAssertEqual(budget.attempts,2)
    recovery.cancelBudget();session.paused=false;session.resumeDeferred()
    XCTAssertEqual(session.opens,1);XCTAssertEqual(budget.attempts,2)
  }
  func testTransientWhilePausedDefersReservationButPermanentFailureStaysTyped() {
    let budget=YlRtmpRecoveryBudget(), scheduler=RtmpRecoveryScheduler(), session=RtmpRecoverySession()
    let recovery=YlRecoveryCoordinator(configuration:.init(map:[:]),scheduler:scheduler,rtmpBudget:budget)
    recovery.session=session;session.paused=true
    recovery.scheduleLiveReconnect(after:session.transient,generation:1)
    XCTAssertEqual(budget.attempts,0);XCTAssertTrue(scheduler.delays.isEmpty)
    recovery.scheduleLiveReconnect(after:ylRtmpError("container.rtmp_track_layout_changed"),generation:1)
    XCTAssertEqual(session.terminal?.code,"container.rtmp_track_layout_changed")
    session.paused=false;session.resumeDeferred()
    XCTAssertEqual(budget.attempts,1);XCTAssertEqual(scheduler.delays,[500])
  }
  func testOneLifetimeBudgetSurvivesFirstFramesAndCoordinatorReconstruction() {
    let budget = YlRtmpRecoveryBudget(), scheduler = RtmpRecoveryScheduler(), session = RtmpRecoverySession()
    let recovery = YlRecoveryCoordinator(configuration:.init(map:[:]),scheduler:scheduler,rtmpBudget:budget)
    recovery.session = session
    recovery.scheduleLiveReconnect(after:session.transient,generation:1)
    XCTAssertEqual(scheduler.delays,[500])
    recovery.markFirstFrame(); scheduler.runNext()
    XCTAssertEqual(scheduler.delays,[500,1000])
    recovery.markFirstFrame(); scheduler.runNext()
    XCTAssertEqual(scheduler.delays,[500,1000,2000])
    recovery.markFirstFrame(); scheduler.runNext()
    let next = YlRecoveryCoordinator(configuration:.init(map:[:]),scheduler:scheduler,rtmpBudget:budget)
    next.session = session; next.scheduleLiveReconnect(after:session.transient,generation:1)
    XCTAssertEqual(scheduler.delays,[500,1000,2000])
    XCTAssertEqual(session.opens,3)
    session.reconfiguring=true // The public live-edge transition starts a fresh explicit operation.
    next.scheduleLiveReconnect(after:session.transient,generation:1,explicitLiveAttempt:true)
    XCTAssertEqual(scheduler.delays,[500,1000,2000,0]); scheduler.runNext()
    XCTAssertEqual(session.opens,4); XCTAssertEqual(budget.attempts,3)
  }
  func testPermanentFailuresAndCancelledGenerationNeverOpen() {
    let scheduler = RtmpRecoveryScheduler(), session = RtmpRecoverySession()
    let recovery = YlRecoveryCoordinator(configuration:.init(map:[:]),scheduler:scheduler,rtmpBudget:.init())
    recovery.session = session
    recovery.scheduleLiveReconnect(after:ylRtmpError("container.rtmp_track_layout_changed"),generation:1)
    XCTAssertTrue(scheduler.delays.isEmpty)
    XCTAssertEqual(session.terminal?.code,"container.rtmp_track_layout_changed")
    recovery.scheduleLiveReconnect(after:session.transient,generation:1)
    recovery.cancelBudget(); scheduler.runNext()
    XCTAssertEqual(session.opens,0)
  }
  func testRestorationBackoffCancellationKeepsOriginalWaiterAndDoesNotOpenAgain() {
    let token = YlOpenCancellationToken(), budget = YlRtmpRecoveryBudget()
    let entered = expectation(description:"first restoration attempt")
    let finished = expectation(description:"original waiter cancelled")
    DispatchQueue.global().async {
      var attempts = 0
      do {
        let _: Int = try budget.prepareRestoration(token:token) {
          attempts += 1; entered.fulfill(); throw ylRtmpError("network.rtmp_handshake_failed")
        }
        XCTFail("Cancelled restoration succeeded")
      } catch { XCTAssertEqual((error as? NativePlayerError)?.code,"network.cancelled") }
      XCTAssertEqual(attempts,1); finished.fulfill()
    }
    wait(for:[entered],timeout:1); token.cancel(); wait(for:[finished],timeout:0.5)
  }
  func testPermanentRestorationFailureNeverConsumesRecoveryBudget() {
    let budget = YlRtmpRecoveryBudget(); var attempts = 0
    XCTAssertThrowsError(try budget.prepareRestoration(token:.init()) { () -> Int in
      attempts += 1; throw ylRtmpError("container.rtmp_track_layout_changed")
    }) { XCTAssertEqual(($0 as? NativePlayerError)?.code,"container.rtmp_track_layout_changed") }
    XCTAssertEqual(attempts,1); XCTAssertEqual(budget.attempts,0)
  }

}
private final class RtmpRecoveryScheduler: YlRecoveryScheduling {
  var delays: [Int64] = [], items: [DispatchWorkItem] = []
  func schedule(_ item: DispatchWorkItem,afterMilliseconds delayMs: Int64) { delays.append(delayMs); items.append(item) }
  func runNext() { guard !items.isEmpty else { return XCTFail("No recovery work") }; items.removeFirst().perform() }
}
private final class RtmpRecoverySession: YlRecoverySession {
  let transient = ylRtmpError("network.rtmp_disconnected")
  var paused=false, deferred:(()->Void)?
  var pausePlayAtNextAdmission=false, completeOpenPermanently=false
  var reconfiguring=true, disposed=false, currentGeneration:UInt64=1
  private var readyContinuations:[()->Void]=[]
  func runReadyContinuations(){let work=readyContinuations;readyContinuations=[];work.forEach {$0()}}
  func deferRecoveryIfPaused(generation:UInt64,operation:@escaping()->Void)->Bool {
    guard paused else {return false};deferred=operation;return true
  }
  func resumeDeferred(){let work=deferred;deferred=nil;work?()}
  var opens = 0, terminal: NativePlayerError?
  var recoveryGeneration: UInt64 { currentGeneration }
  var managedRequestFailure: NativePlayerError? { nil }
  func mayScheduleRecovery(generation:UInt64)->Bool { generation == 1 }
  func emitRecoveryRetry(attempt:Int,delayMs:Int64,error:NativePlayerError,generation:UInt64) {}
  func installRecoveryWorkItem(_ workItem:DispatchWorkItem,generation:UInt64)->Bool { generation == 1 }
  func beginRecoveryOpen(_ token:YlOpenCancellationToken,generation:UInt64,whenPaused:@escaping()->Void)->Bool {
    guard !disposed,reconfiguring,generation==currentGeneration else {return false}
    if pausePlayAtNextAdmission {
      pausePlayAtNextAdmission=false
      // Pause wins admission; atomic storage precedes Play taking the continuation.
      paused=true
      deferred=whenPaused
      paused=false
      if let work=deferred {deferred=nil;readyContinuations.append(work)}
      return false
    }
    if paused {deferred=whenPaused;return false}
    return true
  }
  func makeLiveReconnectPipeline(generation:UInt64,cancellationToken:YlOpenCancellationToken)throws->YlFallbackReconnectPipeline { opens += 1; throw completeOpenPermanently ? ylRtmpError("container.rtmp_track_layout_changed") : transient }
  func installRecoveryCandidate(_ candidate:YlFallbackReconnectPipeline,token:YlOpenCancellationToken,generation:UInt64)->Bool { false }
  func resumeRecovery(generation:UInt64) {}
  func shouldRetryRecovery(token:YlOpenCancellationToken,generation:UInt64)->Bool { !token.isCancelled && generation == 1 }
  func reportRecoveryExhaustion(_ error:NativePlayerError,generation:UInt64) { terminal = error; reconfiguring=false }
}
