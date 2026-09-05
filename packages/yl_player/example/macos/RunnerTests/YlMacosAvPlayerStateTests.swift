@testable import yl_player_macos
import XCTest

final class YlMacosAvPlayerStateTests: XCTestCase {
  func testFailureGateCoalescesCallbacksForOneItem() {
    let gate = YlAvPlayerFailureGate()

    XCTAssertTrue(gate.begin(generation: 4))
    XCTAssertFalse(gate.begin(generation: 4))
    XCTAssertTrue(gate.finish(generation: 4, currentGeneration: 4))
    gate.markTerminal(generation: 4)
    XCTAssertFalse(gate.begin(generation: 4))
    gate.reset()
    XCTAssertTrue(gate.begin(generation: 4))
  }

  func testFailureDiagnosticDoesNotExposeNSErrorUserInfo() {
    let error = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorTimedOut,
      userInfo: [
        NSLocalizedDescriptionKey: "secret token https://u:p@test/x?key=secret",
      ]
    )

    let diagnostic = YlAvPlayerFailurePolicy.diagnostic(error)

    XCTAssertEqual(
      diagnostic,
      "NSError(domain=NSURLErrorDomain, code=\(NSURLErrorTimedOut))"
    )
    XCTAssertFalse(diagnostic.contains("secret"))
  }

  func testPlayIntentReportsBufferingUntilRateStarts() {
    XCTAssertEqual(
      YlAvPlayerStatePolicy.status(
        wantsToPlay: true,
        itemReady: true,
        rate: 0,
        waiting: true
      ),
      "buffering"
    )
  }

  func testStartedRateReportsPlaying() {
    XCTAssertEqual(
      YlAvPlayerStatePolicy.status(
        wantsToPlay: true,
        itemReady: true,
        rate: 1,
        waiting: false
      ),
      "playing"
    )
  }

  func testReadyWithoutPlayIntentReportsPaused() {
    XCTAssertEqual(
      YlAvPlayerStatePolicy.status(
        wantsToPlay: false,
        itemReady: true,
        rate: 0,
        waiting: false
      ),
      "paused"
    )
  }

  func testStallWatchdogReportsFirstFrameTimeoutBeforeAnyFrameRenders() {
    var scheduledDelay: TimeInterval?
    var scheduledAction: (() -> Void)?
    let watchdog = YlAvPlayerStallWatchdog { delay, action in
      scheduledDelay = delay
      scheduledAction = action
    }
    var failure: NativePlayerError?

    watchdog.update(
      active: true,
      wantsToPlay: true,
      hasCurrentItem: true,
      isWaiting: false,
      firstFrameSent: false,
      timeoutMs: 12_000,
      waitingReason: nil
    ) { failure = $0 }

    XCTAssertEqual(scheduledDelay, 12)
    scheduledAction?()
    XCTAssertEqual(failure?.category, "network")
    XCTAssertEqual(failure?.code, "avplayer.first_frame_timeout")
    XCTAssertEqual(
      failure?.diagnostic,
      "AVPlayer(phase=firstFrame, timeoutMs=12000, waitingReason=none)"
    )
  }

  func testStallWatchdogReportsRebufferTimeoutAfterFirstFrame() {
    var scheduledAction: (() -> Void)?
    let watchdog = YlAvPlayerStallWatchdog { _, action in
      scheduledAction = action
    }
    var failure: NativePlayerError?

    watchdog.update(
      active: true,
      wantsToPlay: true,
      hasCurrentItem: true,
      isWaiting: true,
      firstFrameSent: true,
      timeoutMs: 15_000,
      waitingReason: "AVPlayerWaitingToMinimizeStallsReason"
    ) { failure = $0 }

    scheduledAction?()
    XCTAssertEqual(failure?.category, "network")
    XCTAssertEqual(failure?.code, "avplayer.stall_timeout")
    XCTAssertEqual(
      failure?.diagnostic,
      "AVPlayer(phase=rebuffer, timeoutMs=15000, "
        + "waitingReason=AVPlayerWaitingToMinimizeStallsReason)"
    )
  }

  func testStallWatchdogCancelsPendingFailureWhenPlaybackRecovers() {
    var scheduledAction: (() -> Void)?
    let watchdog = YlAvPlayerStallWatchdog { _, action in
      scheduledAction = action
    }
    var failures = [NativePlayerError]()

    watchdog.update(
      active: true,
      wantsToPlay: true,
      hasCurrentItem: true,
      isWaiting: true,
      firstFrameSent: true,
      timeoutMs: 15_000,
      waitingReason: nil
    ) { failures.append($0) }
    watchdog.update(
      active: true,
      wantsToPlay: true,
      hasCurrentItem: true,
      isWaiting: false,
      firstFrameSent: true,
      timeoutMs: 15_000,
      waitingReason: nil
    ) { failures.append($0) }

    scheduledAction?()
    XCTAssertTrue(failures.isEmpty)
  }

  func testStallWatchdogKeepsOriginalFirstFrameDeadlineAcrossRefreshes() {
    var scheduledActions = [() -> Void]()
    let watchdog = YlAvPlayerStallWatchdog { _, action in
      scheduledActions.append(action)
    }
    var failures = [NativePlayerError]()

    for _ in 0..<2 {
      watchdog.update(
        active: true,
        wantsToPlay: true,
        hasCurrentItem: true,
        isWaiting: false,
        firstFrameSent: false,
        timeoutMs: 15_000,
        waitingReason: nil
      ) { failures.append($0) }
    }

    XCTAssertEqual(scheduledActions.count, 1)
    scheduledActions.first?()
    XCTAssertEqual(failures.map(\.code), ["avplayer.first_frame_timeout"])
  }
}
