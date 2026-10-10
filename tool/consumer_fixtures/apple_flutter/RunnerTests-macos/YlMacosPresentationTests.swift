@testable import yl_player_apple
import AppKit
import AVFAudio
import Foundation
import VideoToolbox
import XCTest
import YlFFmpegBridge

final class YlMacosPresentationTests: XCTestCase {
  private final class RecordingTimedEndpoint: YlTimedVideoEndpoint {
    var pts: [Int64] = []
    var retirement: (() -> Void)?
    var beforeEnqueue: (() -> Void)?
    func update(_ snapshot: YlPresentationClockSnapshot, generation: UInt64) {}
    func enqueue(_ frame: YlFrameEnvelope) -> Bool {
      beforeEnqueue?(); pts.append(frame.ptsUs); return true
    }
    func retire(removingImage: Bool, completion: @escaping () -> Void) { retirement = completion }
  }
  private final class RecordingTimedOutput: YlTextureOutput, YlTimedVideoOutput {
    let textureId: Int64 = 91
    var endpoints: [RecordingTimedEndpoint] = []
    func makeTimedVideoEndpoint() -> (any YlTimedVideoEndpoint)? {
      let endpoint = RecordingTimedEndpoint(); endpoints.append(endpoint); return endpoint
    }
    func publish(_ pixelBuffer: CVPixelBuffer?) {}
    func resize(width: Int, height: Int) {}
    func clear() {}
    func dispose() {}
  }

  @MainActor
  func testTimedLeaseRejectsBeforeCommitAndAfterReplacement() async throws {
    let output = RecordingTimedOutput()
    // Use one real owner throughout the lifecycle; the output only records the system boundary.
    let actual = YlAppleTextureOwner(output: output, onFrame: { _ in })
    defer { actual.dispose() }
    let a = actual.makeLease(identity: .init(sessionId: "a", loadRequestId: "a"))
    XCTAssertNil(a.makeTimedVideoEndpoint())
    actual.commit(a)
    let endpoint = try XCTUnwrap(a.makeTimedVideoEndpoint())
    let raw = try XCTUnwrap(output.endpoints.last)
    let frame = YlFrameEnvelope(payload: NSObject(), ptsUs: 1, durationUs: 1, keyframe: true, generation: 1)
    XCTAssertTrue(endpoint.enqueue(frame))
    let b = actual.makeLease(identity: .init(sessionId: "b", loadRequestId: "b"))
    actual.commit(b)
    XCTAssertFalse(endpoint.enqueue(frame))
    XCTAssertEqual(raw.pts, [1])
    XCTAssertNil(b.makeTimedVideoEndpoint(), "New output must wait for the old native flush")
    try XCTUnwrap(raw.retirement)()
    await Task.yield()
    let replacement = try XCTUnwrap(b.makeTimedVideoEndpoint())
    XCTAssertTrue(replacement.enqueue(frame))
    actual.dispose(); actual.dispose()
    XCTAssertFalse(replacement.enqueue(frame))
    output.endpoints.last?.retirement?()
  }

  @MainActor
  func testLateTimedFlushCannotClearNewLease() async throws {
    let output = RecordingTimedOutput()
    let actual = YlAppleTextureOwner(output: output, onFrame: { _ in })
    defer { actual.dispose() }
    let a = actual.makeLease(identity: .init(sessionId: "a", loadRequestId: "a")); actual.commit(a)
    _ = try XCTUnwrap(a.makeTimedVideoEndpoint()); let first = try XCTUnwrap(output.endpoints.last)
    a.clear()
    let b = actual.makeLease(identity: .init(sessionId: "b", loadRequestId: "b")); actual.commit(b)
    let c = actual.makeLease(identity: .init(sessionId: "c", loadRequestId: "c")); actual.commit(c)
    XCTAssertNil(b.makeTimedVideoEndpoint()); XCTAssertNil(c.makeTimedVideoEndpoint())
    let oldFlush = try XCTUnwrap(first.retirement); oldFlush()
    await Task.yield()
    let latest = try XCTUnwrap(c.makeTimedVideoEndpoint())
    oldFlush() // A duplicate system completion must not reopen any old permission.
    XCTAssertNil(a.makeTimedVideoEndpoint()); XCTAssertNil(b.makeTimedVideoEndpoint())
    XCTAssertTrue(latest.enqueue(.init(payload: NSObject(), ptsUs: 2, durationUs: 1, keyframe: true, generation: 2)))
    actual.dispose(); output.endpoints.last?.retirement?()
  }

  @MainActor
  func testTimedLeaseCloseDoesNotWaitUnderSessionLock() async throws {
    let output = RecordingTimedOutput()
    let owner = YlAppleTextureOwner(output: output, onFrame: { _ in })
    let a = owner.makeLease(identity: .init(sessionId: "a", loadRequestId: "a")); owner.commit(a)
    let endpoint = try XCTUnwrap(a.makeTimedVideoEndpoint()), raw = try XCTUnwrap(output.endpoints.last)
    let entered = expectation(description: "native enqueue entered")
    let ended = expectation(description: "in-flight enqueue finished")
    let release = DispatchSemaphore(value: 0)
    raw.beforeEnqueue = { entered.fulfill(); _ = release.wait(timeout: .now() + 2) }
    DispatchQueue.global().async {
      _ = endpoint.enqueue(.init(payload: NSObject(), ptsUs: 1, durationUs: 1, keyframe: true, generation: 1))
      ended.fulfill()
    }
    await fulfillment(of: [entered], timeout: 1)
    owner.dispose()
    XCTAssertNil(raw.retirement, "Retire cannot flush while an admitted system enqueue is in flight")
    release.signal()
    await fulfillment(of: [ended], timeout: 1)
    XCTAssertNotNil(raw.retirement)
    raw.beforeEnqueue = nil
    XCTAssertFalse(endpoint.enqueue(.init(payload: NSObject(), ptsUs: 2, durationUs: 1, keyframe: true, generation: 1)))
    raw.retirement?()
  }

  func testTimedWindowDoesNotExceedLeadOrCount() {
    let window = YlTimedVideoWindow()
    window.reset(generation: 1)
    let snapshot = YlPresentationClockSnapshot(positionUs: 1_000_000, hostTimeUs: 10_000_000, rate: 1, playing: true)
    XCTAssertTrue(window.canSubmit(ptsUs: 1_050_000, snapshot: snapshot))
    XCTAssertFalse(window.canSubmit(ptsUs: 1_050_001, snapshot: snapshot))
    for pts: Int64 in [1_010_000, 1_020_000, 1_030_000] {
      window.didSubmit(.init(payload: NSObject(), ptsUs: pts, durationUs: 10_000, keyframe: true, generation: 1))
    }
    XCTAssertFalse(window.canSubmit(ptsUs: 1_040_000, snapshot: snapshot))
    window.advance(to: 1_010_000)
    XCTAssertTrue(window.canSubmit(ptsUs: 1_040_000, snapshot: snapshot))
    XCTAssertFalse(window.canSubmit(ptsUs: 1_030_000, snapshot: snapshot), "Duplicate submitted PTS must remain rejected after capacity frees")
    window.advance(to: 0)
    XCTAssertEqual(window.pendingFrames.map(\.ptsUs), [1_020_000, 1_030_000])
    window.reset(generation: 2)
    XCTAssertTrue(window.pendingFrames.isEmpty)
    window.didSubmit(.init(payload: NSObject(), ptsUs: 1, durationUs: 0, keyframe: true, generation: 1))
    XCTAssertTrue(window.pendingFrames.isEmpty, "An old generation cannot refill the new window")
  }

  func testTimedWindowHandlesPauseRateAndOverflow() {
    let window = YlTimedVideoWindow(); window.reset(generation: 1)
    for (rate, last): (Double, Int64) in [(0.25, 1_012_500), (4, 1_200_000)] {
      let s = YlPresentationClockSnapshot(positionUs: 1_000_000, hostTimeUs: 0, rate: rate, playing: true)
      XCTAssertTrue(window.canSubmit(ptsUs: last, snapshot: s))
      XCTAssertFalse(window.canSubmit(ptsUs: last + 1, snapshot: s))
    }
    XCTAssertFalse(window.canSubmit(ptsUs: 0, snapshot: .init(positionUs: 0, hostTimeUs: 0, rate: 1, playing: false)))
    XCTAssertFalse(window.canSubmit(ptsUs: -1, snapshot: .init(positionUs: 0, hostTimeUs: 0, rate: 1, playing: true)))
    for rate in [Double.nan, .infinity, -1, 0] {
      XCTAssertFalse(window.canSubmit(ptsUs: 0, snapshot: .init(positionUs: 0, hostTimeUs: 0, rate: rate, playing: true)))
    }
    XCTAssertTrue(window.canSubmit(ptsUs: .max, snapshot: .init(positionUs: .max - 1, hostTimeUs: 0, rate: 4, playing: true)))
  }

  func testTimedSchedulerDoesNotCatchUpFutureFrames() {
    let scheduler = YlFrameScheduler(collectDropDiagnostics: true)
    scheduler.flush(generation: 1)
    for pts: Int64 in [30_000, 10_000, 20_000] {
      XCTAssertTrue(scheduler.enqueue(.init(payload: NSObject(), ptsUs: pts, durationUs: 10_000, keyframe: true, generation: 1)))
    }
    XCTAssertNil(scheduler.nextFrame(upTo: 50_000, generation: 2))
    XCTAssertEqual(scheduler.nextFrame(upTo: 50_000, generation: 1)?.ptsUs, 10_000)
    XCTAssertEqual(scheduler.nextFrame(upTo: 50_000, generation: 1)?.ptsUs, 20_000)
    XCTAssertEqual(scheduler.nextFrame(upTo: 50_000, generation: 1)?.ptsUs, 30_000)
    XCTAssertEqual(scheduler.lateFrameDropCount, 0)
    XCTAssertFalse(scheduler.enqueue(.init(payload: NSObject(), ptsUs: 20_000, durationUs: 0, keyframe: true, generation: 1)))
    scheduler.flush(generation: 2)
    XCTAssertTrue(scheduler.enqueue(.init(payload: NSObject(), ptsUs: 1, durationUs: 0, keyframe: true, generation: 2)))
    XCTAssertNil(scheduler.nextFrame(upTo: 0, generation: 2))
    XCTAssertEqual(scheduler.nextFrame(upTo: 1, generation: 2)?.ptsUs, 1)
    scheduler.dispose()
    XCTAssertNil(scheduler.nextFrame(upTo: .max, generation: 2))
  }

  func testTimedClockSnapshotPreservesPauseAndRate() {
    var audio: YlRenderedAudioTime? = .init(sampleTime: 0, sampleRate: 48_000)
    let clock = YlMediaClock(audioTime: { audio })
    clock.play(atHostTimeUs: 1_000_000)
    audio = .init(sampleTime: 24_000, sampleRate: 48_000)
    let playing = clock.presentationSnapshot(atHostTimeUs: 1_500_000)
    XCTAssertEqual(playing.positionUs, 500_000)
    XCTAssertEqual(playing.hostTimeUs, 1_500_000)
    XCTAssertTrue(playing.playing)
    clock.pause(atHostTimeUs: 1_500_000)
    audio = .init(sampleTime: 48_000, sampleRate: 48_000)
    let paused = clock.presentationSnapshot(atHostTimeUs: 2_000_000)
    XCTAssertEqual(paused.positionUs, 500_000); XCTAssertFalse(paused.playing)
    clock.setRate(2, atHostTimeUs: 2_000_000)
    XCTAssertEqual(clock.presentationSnapshot(atHostTimeUs: 2_000_000).rate, 2)
    audio = nil
    clock.play(atHostTimeUs: 2_000_000)
    XCTAssertEqual(clock.presentationSnapshot(atHostTimeUs: 2_250_000).positionUs, 1_000_000)
  }

  private final class DisplayTestWindow: NSWindow {
    var selectedScreen: NSScreen?
    override var screen: NSScreen? { selectedScreen }
  }


  private final class DisplayTestCadence: YlDisplayCadence {
    var isPaused = false
    var invalidated = false
    func invalidate() { invalidated = true }
  }


  func testDisplayTimerFollowsItsOwningWindowAndPreservesPauseWhenScreenChanges() throws {
    let availableScreen = try XCTUnwrap(NSScreen.screens.first)
    let window = DisplayTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: .borderless, backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    window.contentView = view
    var requestedScreens: [NSScreen?] = []
    var cadences: [DisplayTestCadence] = []
    let timer = YlDisplayTimer(view: view, cadenceFactory: { screen, _, _ in
      requestedScreens.append(screen)
      let cadence = DisplayTestCadence()
      cadences.append(cadence)
      return cadence
    }) {}
    defer { timer.invalidate() }
    XCTAssertEqual(requestedScreens.count, 1)
    XCTAssertNil(requestedScreens.first!, "An offscreen owning window must not bind another window's display.")
    timer.isPaused = true

    window.selectedScreen = availableScreen
    NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)

    XCTAssertEqual(requestedScreens.count, 2)
    XCTAssertTrue(requestedScreens.last! === availableScreen)
    XCTAssertTrue(cadences.first!.invalidated)
    XCTAssertTrue(cadences.last!.isPaused)
    timer.invalidate()
    NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
    XCTAssertEqual(requestedScreens.count, 2, "An invalidated timer must not recreate its cadence.")
  }


  func testDisplayTimerFollowsTheActiveScreenRefreshRate() throws {
    guard let screen = NSScreen.main, screen.maximumFramesPerSecond > 30 else {
      throw XCTSkip("An active display faster than 30 Hz is required.")
    }
    let probe = YlDisplayTickProbe()
    let timer = YlDisplayTimer { probe.tick() }
    defer { timer.invalidate() }

    timer.isPaused = false
    let sampleDuration = 0.5
    RunLoop.main.run(until: Date(timeIntervalSinceNow: sampleDuration))

    let minimumTicks = Int(
      Double(screen.maximumFramesPerSecond) * sampleDuration * 0.75
    )
    XCTAssertGreaterThanOrEqual(probe.tickCount, minimumTicks)
  }


  func testMediaClockQueriesExternalAudioTimeWithoutHoldingItsLock() {
    let completed = expectation(description: "media clock play completed")
    var clock: YlMediaClock!
    clock = YlMediaClock(audioTime: {
      clock.anchorAudio(ptsUs: 0, sampleTime: 0)
      return YlRenderedAudioTime(sampleTime: 0, sampleRate: 48_000)
    })

    DispatchQueue.global().async {
      clock.play(atHostTimeUs: 0)
      completed.fulfill()
    }

    wait(for: [completed], timeout: 1)
  }


  func testMediaClockDoesNotReuseStaleAudioAnchorAcrossRateChanges() {
    var rendered: YlRenderedAudioTime? = YlRenderedAudioTime(
      sampleTime: 48_000,
      sampleRate: 48_000
    )
    let clock = YlMediaClock(audioTime: { rendered })
    clock.anchorAudio(ptsUs: 5_000_000, sampleTime: 48_000)
    clock.play(atHostTimeUs: 0)

    rendered = YlRenderedAudioTime(sampleTime: 96_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 1_000_000), 6_000_000)

    rendered = nil
    clock.setRate(2, atHostTimeUs: 1_000_000)
    rendered = YlRenderedAudioTime(sampleTime: 144_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 1_500_000), 7_000_000)

    rendered = YlRenderedAudioTime(sampleTime: 192_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 2_000_000), 8_000_000)

    rendered = nil
    clock.setRate(1, atHostTimeUs: 2_000_000)
    rendered = YlRenderedAudioTime(sampleTime: 216_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 2_500_000), 8_500_000)
  }


  func testMediaClockDoesNotScaleTheTimePitchPlayerTimelineTwice() {
    var rendered = YlRenderedAudioTime(sampleTime: 0, sampleRate: 48_000)
    let clock = YlMediaClock(audioTime: { rendered })
    clock.anchorAudio(ptsUs: 0, sampleTime: 0)
    clock.play(atHostTimeUs: 0)

    clock.setRate(3, atHostTimeUs: 0)
    rendered = YlRenderedAudioTime(sampleTime: 144_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 1_000_000), 3_000_000)

    clock.setRate(1, atHostTimeUs: 1_000_000)
    rendered = YlRenderedAudioTime(sampleTime: 192_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 2_000_000), 4_000_000)
  }


  func testMediaClockDoesNotReuseStaleAudioAnchorAcrossPauseAndResume() {
    var rendered: YlRenderedAudioTime? = YlRenderedAudioTime(
      sampleTime: 48_000,
      sampleRate: 48_000
    )
    let clock = YlMediaClock(audioTime: { rendered })
    clock.anchorAudio(ptsUs: 5_000_000, sampleTime: 48_000)
    clock.play(atHostTimeUs: 0)

    rendered = YlRenderedAudioTime(sampleTime: 96_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 1_000_000), 6_000_000)

    rendered = nil
    clock.pause(atHostTimeUs: 1_000_000)
    clock.play(atHostTimeUs: 2_000_000)
    rendered = YlRenderedAudioTime(sampleTime: 120_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 2_500_000), 6_500_000)
  }


  func testFrameSchedulerPresentsOverdueFramesInOrderAndRejectsOldGeneration() {
    let scheduler = YlFrameScheduler()
    scheduler.enqueue(YlFrameEnvelope(
      payload: NSObject(),
      ptsUs: 10_000,
      durationUs: 40_000,
      keyframe: false,
      generation: 1
    ))
    scheduler.enqueue(YlFrameEnvelope(
      payload: NSObject(),
      ptsUs: 20_000,
      durationUs: 40_000,
      keyframe: false,
      generation: 1
    ))

    XCTAssertEqual(scheduler.frame(at: 15_000, generation: 1)?.ptsUs, 10_000)
    XCTAssertEqual(scheduler.frame(at: 25_000, generation: 1)?.ptsUs, 20_000)
    XCTAssertEqual(scheduler.lateFrameDropCount, 0)
    scheduler.flush(generation: 2)
    XCTAssertNil(scheduler.frame(at: 30_000, generation: 1))
  }


  func testFrameSchedulerPresentsTheNewestFrameDueOnEachDisplayTick() {
    let scheduler = YlFrameScheduler()
    for ptsUs in [10_000, 20_000, 30_000] {
      XCTAssertTrue(scheduler.enqueue(YlFrameEnvelope(
        payload: NSObject(),
        ptsUs: Int64(ptsUs),
        durationUs: 10_000,
        keyframe: false,
        generation: 1
      )))
    }

    XCTAssertEqual(scheduler.frame(at: 35_000, generation: 1)?.ptsUs, 30_000)
    XCTAssertEqual(scheduler.pendingPTS, [])
    XCTAssertEqual(scheduler.lateFrameDropCount, 2)
  }


  func testFrameSchedulerRejectsAFrameOlderThanTheLastPresentedPTS() {
    let scheduler = YlFrameScheduler()
    XCTAssertTrue(scheduler.enqueue(YlFrameEnvelope(
      payload: NSObject(),
      ptsUs: 20_000,
      durationUs: 10_000,
      keyframe: false,
      generation: 1
    )))
    XCTAssertEqual(scheduler.frame(at: 20_000, generation: 1)?.ptsUs, 20_000)

    XCTAssertFalse(scheduler.enqueue(YlFrameEnvelope(
      payload: NSObject(),
      ptsUs: 10_000,
      durationUs: 10_000,
      keyframe: false,
      generation: 1
    )))
    XCTAssertNil(scheduler.frame(at: 30_000, generation: 1))
    XCTAssertEqual(scheduler.lateFrameDropCount, 1)
  }


  func testFrameSchedulerBackpressuresUntilPresentationFreesCapacity() {
    let scheduler = YlFrameScheduler()
    for ptsUs in [10_000, 20_000, 30_000] {
      XCTAssertTrue(scheduler.enqueue(YlFrameEnvelope(
        payload: NSObject(),
        ptsUs: Int64(ptsUs),
        durationUs: 10_000,
        keyframe: false,
        generation: 1
      )))
    }
    let started = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      started.signal()
      _ = scheduler.enqueue(YlFrameEnvelope(
        payload: NSObject(),
        ptsUs: 40_000,
        durationUs: 10_000,
        keyframe: false,
        generation: 1
      ))
      completed.signal()
    }

    XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(completed.wait(timeout: .now() + 0.05), .timedOut)
    XCTAssertEqual(scheduler.pendingPTS, [10_000, 20_000, 30_000])
    XCTAssertEqual(scheduler.frame(at: 10_000, generation: 1)?.ptsUs, 10_000)
    XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(scheduler.pendingPTS, [20_000, 30_000, 40_000])
  }

}

private final class YlDisplayTickProbe {
  private let lock = NSLock()
  private var count = 0

  var tickCount: Int {
    lock.withLock { count }
  }

  func tick() {
    lock.withLock { count += 1 }
  }
}
