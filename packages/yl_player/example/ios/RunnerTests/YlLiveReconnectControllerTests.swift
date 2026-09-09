@testable import yl_player_apple
import AVFoundation
import XCTest

final class YlLiveReconnectControllerTests: XCTestCase {
  func testRetriesAreBoundedAndExponentiallyCapped() {
    let controller = YlLiveReconnectController(configuration: .init(map: [
      "maxRetries": 2,
      "baseRetryDelayMs": 10,
      "maxRetryDelayMs": 15,
    ]))

    XCTAssertTrue(controller.canRetry)
    XCTAssertEqual(controller.nextDelayMs(), 10)
    XCTAssertTrue(controller.canRetry)
    XCTAssertEqual(controller.nextDelayMs(), 15)
    XCTAssertFalse(controller.canRetry)
    XCTAssertNil(controller.nextDelayMs())
    XCTAssertEqual(controller.attempt, 2)
  }

  func testFirstFrameResetsRetryBudget() {
    let controller = YlLiveReconnectController(configuration: .init(map: [
      "maxRetries": 1,
      "baseRetryDelayMs": 7,
    ]))

    XCTAssertEqual(controller.nextDelayMs(), 7)
    controller.markFirstFrame()

    XCTAssertEqual(controller.attempt, 0)
    XCTAssertEqual(controller.nextDelayMs(), 7)
  }

  func testCancellationPreventsFutureRetriesAndInstallation() {
    let controller = YlLiveReconnectController(configuration: .init(map: [
      "maxRetries": 3,
    ]))

    controller.cancel()

    XCTAssertNil(controller.nextDelayMs())
    XCTAssertFalse(controller.shouldInstall(
      reconnectGeneration: 4,
      currentGeneration: 4
    ))
  }

  func testStaleGenerationCannotInstallReconnectedPipeline() {
    let controller = YlLiveReconnectController(configuration: .init(map: [:]))

    XCTAssertFalse(controller.shouldInstall(
      reconnectGeneration: 4,
      currentGeneration: 5
    ))
    XCTAssertTrue(controller.shouldInstall(
      reconnectGeneration: 5,
      currentGeneration: 5
    ))
  }

  func testAvPlayerRecoveryRetriesObservedTransientLiveHlsFailure() {
    XCTAssertTrue(YlAvPlayerRecoveryPolicy.shouldReconnect(
      source: source(
        uri: "http://127.0.0.1:8080/m3u8?url=live",
        formatHint: .hls,
        isLive: true
      ),
      usesResourceLoader: false,
      hasBeenReady: true,
      playRequested: true,
      error: NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue),
      errorLogDomain: "CoreMediaErrorDomain",
      errorLogStatusCode: -12312
    ))
    XCTAssertTrue(YlAvPlayerRecoveryPolicy.shouldReconnect(
      source: source(
        uri: "https://media.test/live.m3u8",
        formatHint: .automatic,
        isLive: true
      ),
      usesResourceLoader: false,
      hasBeenReady: true,
      playRequested: true,
      error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost),
      errorLogDomain: nil,
      errorLogStatusCode: nil
    ))
    XCTAssertTrue(YlAvPlayerRecoveryPolicy.shouldReconnect(
      source: source(
        uri: "https://media.test/live.m3u8",
        formatHint: .hls,
        isLive: true
      ),
      usesResourceLoader: false,
      hasBeenReady: true,
      playRequested: true,
      error: NSError(domain: "CoreMediaErrorDomain", code: -12312),
      errorLogDomain: nil,
      errorLogStatusCode: nil
    ))
  }

  func testAvPlayerRecoveryRejectsPermanentAndUnsupportedFailures() {
    XCTAssertFalse(YlAvPlayerRecoveryPolicy.shouldReconnect(
      source: source(
        uri: "https://media.test/live.m3u8",
        formatHint: .hls,
        isLive: true
      ),
      usesResourceLoader: false,
      hasBeenReady: true,
      playRequested: true,
      error: NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue),
      errorLogDomain: "CoreMediaErrorDomain",
      errorLogStatusCode: 403
    ))
    XCTAssertFalse(YlAvPlayerRecoveryPolicy.shouldReconnect(
      source: source(
        uri: "https://media.test/live.m3u8",
        formatHint: .hls,
        isLive: true
      ),
      usesResourceLoader: false,
      hasBeenReady: true,
      playRequested: true,
      error: NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue),
      errorLogDomain: "UnknownDomain",
      errorLogStatusCode: 503
    ))
    XCTAssertFalse(YlAvPlayerRecoveryPolicy.shouldReconnect(
      source: source(
        uri: "https://media.test/vod.m3u8",
        formatHint: .hls,
        isLive: false
      ),
      usesResourceLoader: false,
      hasBeenReady: true,
      playRequested: true,
      error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
      errorLogDomain: nil,
      errorLogStatusCode: nil
    ))
    XCTAssertFalse(YlAvPlayerRecoveryPolicy.shouldReconnect(
      source: source(
        uri: "https://media.test/live.flv",
        formatHint: .flv,
        isLive: true
      ),
      usesResourceLoader: false,
      hasBeenReady: true,
      playRequested: true,
      error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
      errorLogDomain: nil,
      errorLogStatusCode: nil
    ))
    XCTAssertFalse(YlAvPlayerRecoveryPolicy.shouldReconnect(
      source: source(
        uri: "https://media.test/live.m3u8",
        formatHint: .hls,
        isLive: true
      ),
      usesResourceLoader: true,
      hasBeenReady: true,
      playRequested: true,
      error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
      errorLogDomain: nil,
      errorLogStatusCode: nil
    ))
  }

  func testAvPlayerRecoveryCoversPreplayFailureButNotPausedPlayback() {
    let transient = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
    let liveHls = source(
      uri: "https://media.test/live.m3u8",
      formatHint: .hls,
      isLive: true
    )

    XCTAssertTrue(YlAvPlayerRecoveryPolicy.shouldReconnect(
      source: liveHls,
      usesResourceLoader: false,
      hasBeenReady: false,
      playRequested: false,
      error: transient,
      errorLogDomain: nil,
      errorLogStatusCode: nil
    ))
    XCTAssertFalse(YlAvPlayerRecoveryPolicy.shouldReconnect(
      source: liveHls,
      usesResourceLoader: false,
      hasBeenReady: true,
      playRequested: false,
      error: transient,
      errorLogDomain: nil,
      errorLogStatusCode: nil
    ))
  }

  func testAvPlayerFailureGateCoalescesDuplicateAndStaleCallbacks() {
    let gate = YlAvPlayerFailureGate()

    XCTAssertTrue(gate.begin(generation: 4))
    XCTAssertFalse(gate.begin(generation: 4))
    XCTAssertFalse(gate.finish(generation: 4, currentGeneration: 5))
    XCTAssertTrue(gate.begin(generation: 5))
    XCTAssertTrue(gate.finish(generation: 5, currentGeneration: 5))
    gate.markTerminal(generation: 5)
    XCTAssertFalse(gate.begin(generation: 5))

    gate.reset()
    XCTAssertTrue(gate.begin(generation: 5))
  }

  func testAvPlayerStallWatchdogReportsFirstFrameTimeoutBeforeAnyFrameRenders() {
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

  func testAvPlayerStallWatchdogReportsRebufferTimeoutAfterFirstFrame() {
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

  func testAvPlayerStallWatchdogCancelsPendingFailureWhenPlaybackRecovers() {
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

  func testAvPlayerStallWatchdogKeepsOriginalFirstFrameDeadlineAcrossRefreshes() {
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

  func testAvPlayerErrorLogCollectorDoesNotHeadOfLineBlockNewFailures() {
    let collector = YlAvPlayerErrorLogCollector()
    let firstStarted = expectation(description: "first read started")
    let secondCompleted = expectation(description: "second read completed")
    let releaseFirst = DispatchSemaphore(value: 0)

    collector.collect(timeoutMs: 5_000, read: {
      firstStarted.fulfill()
      releaseFirst.wait()
      return YlAvPlayerErrorLogSnapshot(domain: "CoreMediaErrorDomain", statusCode: 500, uri: nil)
    }) { _ in }
    wait(for: [firstStarted], timeout: 1)

    collector.collect(timeoutMs: 5_000, read: {
      YlAvPlayerErrorLogSnapshot(domain: "CoreMediaErrorDomain", statusCode: 503, uri: nil)
    }) { snapshot in
      XCTAssertEqual(snapshot?.statusCode, 503)
      secondCompleted.fulfill()
    }
    wait(for: [secondCompleted], timeout: 1)
    releaseFirst.signal()
  }

  func testAvPlayerErrorLogCollectorBoundsBlockedLogReads() {
    let collector = YlAvPlayerErrorLogCollector()
    let completed = expectation(description: "bounded completion")
    let releaseRead = DispatchSemaphore(value: 0)

    collector.collect(timeoutMs: 25, read: {
      releaseRead.wait()
      return YlAvPlayerErrorLogSnapshot(domain: "CoreMediaErrorDomain", statusCode: 500, uri: nil)
    }) { snapshot in
      XCTAssertNil(snapshot)
      completed.fulfill()
    }

    wait(for: [completed], timeout: 1)
    releaseRead.signal()
  }

  func testAvPlayerDiagnosticExcludesUntrustedDescriptionsCommentsAndCredentials() {
    let diagnostic = YlAvPlayerRecoveryPolicy.diagnostic(
      error: NSError(
        domain: "https://attacker.test/error?token=outer-secret",
        code: -11800,
        userInfo: [NSLocalizedDescriptionKey: "Cookie: inner-secret"]
      ),
      errorDomain: "CoreMediaErrorDomain",
      statusCode: -12312,
      uri: "https://user:pass@media.test/live.m3u8?token=secret#part"
    )

    XCTAssertEqual(
      diagnostic,
      "NSError(domain=other, code=-11800); "
        + "HLS(domain=CoreMediaErrorDomain, status=-12312, "
        + "uri=https://media.test/live.m3u8)"
    )
    XCTAssertFalse(diagnostic.contains("secret"))
    XCTAssertFalse(diagnostic.contains("user"))
    XCTAssertFalse(diagnostic.contains("pass"))
    XCTAssertFalse(diagnostic.contains("Cookie"))
  }

  private func source(uri: String, formatHint: YlSourceFormat, isLive: Bool) -> YlAppleSourceDescriptor {
    YlAppleSourceDescriptor(uri: uri, kind: .network, formatHint: formatHint,
      intent: isLive ? .live : .automatic)
  }
}
