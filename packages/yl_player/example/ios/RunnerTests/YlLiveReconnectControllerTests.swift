@testable import yl_player_apple
import AVFoundation
import XCTest

final class YlLiveReconnectControllerTests: XCTestCase {
  @MainActor
  func testStableBufferingRespectsWaitPolicyAndPlaybackSpeed() throws {
    for goal in [YlBufferGoal.smoothPlayback, .lowLatency] {
      let player = StalledLivePlayer()
      let services = YlPlatformServices(platform: .ios, textureOutput: AppleTestTexture(),
        makeDisplayDriver: { _ in AppleTestDisplay() })
      let backend = YlAvPlayerBackend(playerId: 99, services: services,
        configuration: PlayerConfiguration(map: ["bufferMode": "lowLatency"]),
        player: player, emit: { _ in })
      defer { backend.dispose() }
      var live = source(uri: "https://example.test/live.m3u8", formatHint: .hls, isLive: true)
      live.loadOptions = YlAppleLoadOptions(bufferStrategy: goal)
      try backend.open(live)
      try backend.setPlaybackSpeed(1.25)
      try backend.play()
      let stable = goal == .smoothPlayback
      XCTAssertEqual(player.currentItem?.preferredForwardBufferDuration, stable ? 30 : 2)
      XCTAssertEqual(player.automaticallyWaitsToMinimizeStalling, stable)
      XCTAssertEqual(player.immediateRates, stable ? [] : [1.25])
      XCTAssertEqual(player.waitingRates, stable ? [1.25] : [])
    }
  }

  @MainActor
  func testLiveTimeoutReconnectsInternallyBeforeReportingFailure() async throws {
    let player = StalledLivePlayer()
    let output = AppleTestTexture()
    let services = YlPlatformServices(platform: .ios, textureOutput: output,
      makeDisplayDriver: { _ in AppleTestDisplay() })
    var failures = [NativePlayerError]()
    let failed = expectation(description: "Retry budget exhausted")
    let backend = YlAvPlayerBackend(playerId: 99, services: services,
      configuration: PlayerConfiguration(map: ["network": [
        "readTimeoutMs": 30, "maxRetries": 1, "baseRetryDelayMs": 0,
      ]]), player: player, emit: {
        if case .failure(let error) = $0.event {
          failures.append(error)
          failed.fulfill()
        }
      })
    defer { backend.dispose() }
    try backend.open(source(uri: "https://example.test/live.m3u8",
      formatHint: .hls, isLive: true))
    let clears = output.clears
    try backend.play()
    await fulfillment(of: [failed], timeout: 2)

    XCTAssertEqual(player.installedItems.count, 2,
      "The native backend must reopen the current source before reporting timeout")
    XCTAssertEqual(failures.count, 1)
    XCTAssertEqual(failures.first?.code, "avplayer.first_frame_timeout")
    XCTAssertEqual(output.clears, clears, "Internal recovery must retain the last picture")
    XCTAssertFalse(backend.playbackIntent, "Exhausted recovery must stop playback")
  }

  @MainActor
  func testStopCancelsPendingTimeoutReconnect() async throws {
    let player = StalledLivePlayer()
    let output = AppleTestTexture()
    let services = YlPlatformServices(platform: .ios, textureOutput: output,
      makeDisplayDriver: { _ in AppleTestDisplay() })
    let reconnecting = expectation(description: "Internal reconnection scheduled")
    var observedReconnect = false
    var failures = [NativePlayerError]()
    let backend = YlAvPlayerBackend(playerId: 99, services: services,
      configuration: PlayerConfiguration(map: ["network": [
        "readTimeoutMs": 20, "maxRetries": 1, "baseRetryDelayMs": 100,
      ]]), player: player, emit: {
        if case .failure(let error) = $0.event { failures.append(error) }
        if case .state = $0.event, player.currentItem == nil,
           player.installedItems.count == 1, !observedReconnect {
          observedReconnect = true
          reconnecting.fulfill()
        }
      })
    defer { backend.dispose() }
    try backend.open(source(uri: "https://example.test/live.m3u8",
      formatHint: .hls, isLive: true))
    let clears = output.clears
    try backend.play()
    await fulfillment(of: [reconnecting], timeout: 2)
    XCTAssertTrue(failures.isEmpty)
    XCTAssertEqual(output.clears, clears)
    backend.stop()
    let elapsed = expectation(description: "Reconnect delay elapsed")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { elapsed.fulfill() }
    await fulfillment(of: [elapsed], timeout: 2)
    XCTAssertEqual(player.installedItems.count, 1)
    XCTAssertNil(player.currentItem)
    XCTAssertGreaterThan(output.clears, clears)
    XCTAssertTrue(failures.isEmpty)
  }

  @MainActor
  func testVodAndDisabledRetryTimeoutsRemainTerminal() async throws {
    for (isLive, retries) in [(false, 1), (true, 0)] {
      let player = StalledLivePlayer()
      let services = YlPlatformServices(platform: .ios, textureOutput: AppleTestTexture(),
        makeDisplayDriver: { _ in AppleTestDisplay() })
      let failed = expectation(description: "Terminal timeout")
      let backend = YlAvPlayerBackend(playerId: 99, services: services,
        configuration: PlayerConfiguration(map: ["network": [
          "readTimeoutMs": 20, "maxRetries": retries,
        ]]), player: player, emit: {
          if case .failure = $0.event { failed.fulfill() }
        })
      defer { backend.dispose() }
      try backend.open(source(uri: "https://example.test/stream.m3u8",
        formatHint: .hls, isLive: isLive))
      try backend.play()
      await fulfillment(of: [failed], timeout: 2)
      XCTAssertEqual(player.installedItems.count, 1)
      XCTAssertFalse(backend.playbackIntent)
    }
  }

  @MainActor
  func testPausedLivePlaybackDoesNotReconnectAfterReadTimeout() async throws {
    let player = StalledLivePlayer()
    let services = YlPlatformServices(platform: .ios, textureOutput: AppleTestTexture(),
      makeDisplayDriver: { _ in AppleTestDisplay() })
    var failures = [NativePlayerError]()
    let backend = YlAvPlayerBackend(playerId: 99, services: services,
      configuration: PlayerConfiguration(map: ["network": ["readTimeoutMs": 20]]),
      player: player, emit: {
        if case .failure(let error) = $0.event { failures.append(error) }
      })
    defer { backend.dispose() }
    try backend.open(source(uri: "https://example.test/live.m3u8",
      formatHint: .hls, isLive: true))
    try backend.play()
    try backend.pause()
    let elapsed = expectation(description: "Read timeout elapsed")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { elapsed.fulfill() }
    await fulfillment(of: [elapsed], timeout: 2)
    XCTAssertEqual(player.installedItems.count, 1)
    XCTAssertTrue(failures.isEmpty)
  }

  @MainActor
  func testAutomaticLiveReconnectPreservesFrameUntilReplacementButStopClears() throws {
    let output = AppleTestTexture()
    let player = AVPlayer()
    let services = YlPlatformServices(platform: .ios, textureOutput: output,
      makeDisplayDriver: { _ in AppleTestDisplay() })
    let backend = YlAvPlayerBackend(playerId: 98, services: services,
      configuration: PlayerConfiguration(map: [:]), player: player, emit: { _ in })
    defer { backend.dispose() }
    try backend.open(YlAppleSourceDescriptor(
      uri: "https://example.test/live.m3u8", kind: .network,
      formatHint: .hls, intent: .live))
    let item = try XCTUnwrap(player.currentItem)
    let clearsBeforeReconnect = output.clears

    NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime,
      object: item, userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey:
        NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)])

    XCTAssertNil(player.currentItem, "A transient live error must schedule item replacement")
    XCTAssertEqual(output.clears, clearsBeforeReconnect,
      "Retain the last published frame while the same live source reconnects")
    backend.stop()
    XCTAssertGreaterThan(output.clears, clearsBeforeReconnect,
      "Explicit stop must still clear the retained picture")
  }

  func testInternalPauseWithPlaybackIntentStillTimesOutAfterFirstFrame() {
    var scheduledAction: (() -> Void)?
    let watchdog = YlAvPlayerStallWatchdog { _, action in scheduledAction = action }
    var failure: NativePlayerError?
    watchdog.update(active: true, wantsToPlay: true, hasCurrentItem: true,
      timeControlStatus: .paused, playbackStatus: "buffering", firstFrameSent: true, timeoutMs: 15_000,
      waitingReason: nil) { failure = $0 }
    scheduledAction?()
    XCTAssertEqual(failure?.code, "avplayer.stall_timeout")
  }

  func testTerminalPlaybackCannotRearmStallTimeoutOnDelayedPause() {
    for terminalStatus in ["completed", "error"] {
      var scheduledActions = [() -> Void]()
      let watchdog = YlAvPlayerStallWatchdog { _, action in scheduledActions.append(action) }
      var failures = [NativePlayerError]()
      watchdog.update(active: true, wantsToPlay: true, hasCurrentItem: true,
        timeControlStatus: .waitingToPlayAtSpecifiedRate, playbackStatus: "buffering",
        firstFrameSent: true, timeoutMs: 15_000, waitingReason: nil) { failures.append($0) }
      watchdog.update(active: true, wantsToPlay: true, hasCurrentItem: true,
        timeControlStatus: .paused, playbackStatus: terminalStatus,
        firstFrameSent: true, timeoutMs: 15_000, waitingReason: nil) { failures.append($0) }
      scheduledActions.forEach { $0() }
      XCTAssertEqual(scheduledActions.count, 1)
      XCTAssertTrue(failures.isEmpty, terminalStatus)
    }
  }

  func testUserPauseCancelsInternalPauseTimeout() {
    var scheduledAction: (() -> Void)?
    let watchdog = YlAvPlayerStallWatchdog { _, action in scheduledAction = action }
    var failures = [NativePlayerError]()
    watchdog.update(active: true, wantsToPlay: true, hasCurrentItem: true,
      timeControlStatus: .waitingToPlayAtSpecifiedRate, playbackStatus: "buffering", firstFrameSent: true,
      timeoutMs: 15_000, waitingReason: nil) { failures.append($0) }
    watchdog.update(active: true, wantsToPlay: false, hasCurrentItem: true,
      timeControlStatus: .paused, playbackStatus: "buffering", firstFrameSent: true, timeoutMs: 15_000,
      waitingReason: nil) { failures.append($0) }
    scheduledAction?()
    XCTAssertTrue(failures.isEmpty)
  }

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
      timeControlStatus: .playing, playbackStatus: "buffering",
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
      timeControlStatus: .waitingToPlayAtSpecifiedRate, playbackStatus: "buffering",
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
      timeControlStatus: .waitingToPlayAtSpecifiedRate, playbackStatus: "buffering",
      firstFrameSent: true,
      timeoutMs: 15_000,
      waitingReason: nil
    ) { failures.append($0) }
    watchdog.update(
      active: true,
      wantsToPlay: true,
      hasCurrentItem: true,
      timeControlStatus: .playing, playbackStatus: "buffering",
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
        timeControlStatus: .playing, playbackStatus: "buffering",
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

    XCTAssertEqual(diagnostic, "Playback operation failed.")
    XCTAssertFalse(diagnostic.contains("media.test"))
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

/// Keep AVFoundation network callbacks out of the timeout regression: items never
/// become ready and only the backend's real watchdog drives recovery.
private final class StalledLivePlayer: AVPlayer {
  private var item: AVPlayerItem?
  private(set) var installedItems = [AVPlayerItem]()
  override var currentItem: AVPlayerItem? { item }
  override func replaceCurrentItem(with newItem: AVPlayerItem?) {
    item = newItem
    if let newItem { installedItems.append(newItem) }
  }
  private(set) var immediateRates = [Float]()
  private(set) var waitingRates = [Float]()
  override var rate: Float {
    get { 0 }
    set { waitingRates.append(newValue) }
  }
  override func playImmediately(atRate rate: Float) { immediateRates.append(rate) }
  override func pause() {}
}
