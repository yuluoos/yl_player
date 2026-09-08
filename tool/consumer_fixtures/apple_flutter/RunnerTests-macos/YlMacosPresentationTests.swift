@testable import yl_player_apple
import AppKit
import AVFAudio
import Foundation
import VideoToolbox
import XCTest
import YlFFmpegBridge

final class YlMacosPresentationTests: XCTestCase {
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
