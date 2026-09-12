@testable import yl_player_apple
import XCTest

final class YlFrameSchedulerTests: XCTestCase {
  private final class LifetimeCounter {
    private let lock = NSLock()
    private(set) var released = 0

    func increment() {
      lock.lock()
      released += 1
      lock.unlock()
    }
  }

  private final class Token {
    let counter: LifetimeCounter

    init(counter: LifetimeCounter) {
      self.counter = counter
    }

    deinit {
      counter.increment()
    }
  }

  private func frame(
    _ ptsUs: Int64,
    generation: UInt64 = 1,
    counter: LifetimeCounter = LifetimeCounter()
  ) -> YlFrameEnvelope {
    YlFrameEnvelope(
      payload: Token(counter: counter),
      ptsUs: ptsUs,
      durationUs: 40_000,
      keyframe: false,
      generation: generation
    )
  }

  func testOrdersFramesAndSelectsNewestDueFrame() {
    let scheduler = YlFrameScheduler()
    scheduler.enqueue(frame(30_000))
    scheduler.enqueue(frame(10_000))
    scheduler.enqueue(frame(20_000))

    XCTAssertEqual(scheduler.pendingPTS, [10_000, 20_000, 30_000])
    XCTAssertEqual(scheduler.frame(at: 25_000, generation: 1)?.ptsUs, 20_000)
    XCTAssertEqual(scheduler.pendingPTS, [30_000])
    XCTAssertEqual(scheduler.lateFrameDropCount, 1)
  }

  func testBackpressuresUntilPresentationFreesCapacity() {
    let counter = LifetimeCounter()
    let scheduler = YlFrameScheduler(
      compatibility: .init(platform: .ios), enqueueWaitTimeout: 1
    )
    defer { scheduler.dispose() }
    scheduler.enqueue(frame(10_000, counter: counter))
    scheduler.enqueue(frame(20_000, counter: counter))
    scheduler.enqueue(frame(30_000, counter: counter))
    let started = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      started.signal()
      XCTAssertTrue(scheduler.enqueue(self.frame(40_000, counter: counter)))
      completed.signal()
    }

    XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(completed.wait(timeout: .now() + 0.05), .timedOut)
    XCTAssertEqual(scheduler.pendingPTS, [10_000, 20_000, 30_000])
    XCTAssertEqual(counter.released, 0)
    XCTAssertEqual(scheduler.frame(at: 10_000, generation: 1)?.ptsUs, 10_000)
    XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(scheduler.pendingPTS, [20_000, 30_000, 40_000])
    XCTAssertEqual(scheduler.lateFrameDropCount, 0)
    XCTAssertEqual(counter.released, 1)
    scheduler.dispose()
    XCTAssertEqual(counter.released, 4)
  }

  func testIncreasingRateWakesProducerAndAllowsNineQueuedFrames() {
    let scheduler = YlFrameScheduler(
      compatibility: .init(platform: .ios), enqueueWaitTimeout: 2
    )
    defer { scheduler.dispose() }
    for pts in [10_000, 20_000, 30_000] {
      XCTAssertTrue(scheduler.enqueue(frame(Int64(pts))))
    }
    let started = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      started.signal()
      XCTAssertTrue(scheduler.enqueue(self.frame(40_000)))
      completed.signal()
    }
    XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(completed.wait(timeout: .now() + 0.05), .timedOut)

    scheduler.setRate(3)
    XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
    for pts in [50_000, 60_000, 70_000, 80_000, 90_000] {
      XCTAssertTrue(scheduler.enqueue(frame(Int64(pts))))
    }
    XCTAssertEqual(scheduler.pendingPTS, [10_000, 20_000, 30_000, 40_000, 50_000, 60_000, 70_000, 80_000, 90_000])
    XCTAssertEqual(scheduler.lateFrameDropCount, 0)

    DispatchQueue.global().async {
      started.signal()
      XCTAssertFalse(scheduler.enqueue(self.frame(100_000)))
      completed.signal()
    }
    XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(completed.wait(timeout: .now() + 0.05), .timedOut)
    scheduler.dispose()
    XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
  }

  func testReturningToNormalRatePreservesQueuedFramesUntilCapacityDrains() {
    let counter = LifetimeCounter()
    let scheduler = YlFrameScheduler(
      compatibility: .init(platform: .ios), enqueueWaitTimeout: 2
    )
    defer { scheduler.dispose() }
    scheduler.setRate(3)
    for pts in [10_000, 20_000, 30_000, 40_000, 50_000, 60_000, 70_000, 80_000, 90_000] {
      XCTAssertTrue(scheduler.enqueue(frame(Int64(pts), counter: counter)))
    }
    scheduler.setRate(1)
    XCTAssertEqual(scheduler.pendingPTS, [10_000, 20_000, 30_000, 40_000, 50_000, 60_000, 70_000, 80_000, 90_000])
    XCTAssertEqual(counter.released, 0)

    let started = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      started.signal()
      XCTAssertTrue(scheduler.enqueue(self.frame(100_000, counter: counter)))
      completed.signal()
    }
    XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(completed.wait(timeout: .now() + 0.05), .timedOut)
    for pts in [10_000, 20_000, 30_000, 40_000, 50_000, 60_000] {
      XCTAssertEqual(scheduler.frame(at: Int64(pts), generation: 1)?.ptsUs, Int64(pts))
    }
    XCTAssertEqual(scheduler.pendingPTS, [70_000, 80_000, 90_000])
    XCTAssertEqual(completed.wait(timeout: .now() + 0.05), .timedOut)
    XCTAssertEqual(scheduler.frame(at: 70_000, generation: 1)?.ptsUs, 70_000)
    XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(scheduler.pendingPTS, [80_000, 90_000, 100_000])
    XCTAssertEqual(scheduler.lateFrameDropCount, 0)
    XCTAssertEqual(counter.released, 7)
    scheduler.dispose()
    XCTAssertEqual(counter.released, 10)
  }

  func testRejectsWaitingFrameThatBecomesLateBeforeCapacityIsAvailable() {
    let counter = LifetimeCounter()
    let scheduler = YlFrameScheduler(
      compatibility: .init(platform: .ios), enqueueWaitTimeout: 2
    )
    defer { scheduler.dispose() }
    for pts in [10_000, 30_000, 40_000] {
      XCTAssertTrue(scheduler.enqueue(frame(Int64(pts), counter: counter)))
    }
    let started = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      started.signal()
      XCTAssertFalse(scheduler.enqueue(self.frame(20_000, counter: counter)))
      completed.signal()
    }

    XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(completed.wait(timeout: .now() + 0.05), .timedOut)
    XCTAssertEqual(scheduler.pendingPTS, [10_000, 30_000, 40_000])
    XCTAssertEqual(scheduler.frame(at: 40_000, generation: 1)?.ptsUs, 40_000)
    XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(scheduler.pendingPTS, [])
    XCTAssertNil(scheduler.frame(at: 50_000, generation: 1))
    XCTAssertEqual(scheduler.lateFrameDropCount, 3)
    XCTAssertEqual(counter.released, 4)
  }

  func testRejectsLateAndDuplicateFramesAfterPresentation() {
    let counter = LifetimeCounter()
    let scheduler = YlFrameScheduler(compatibility: .init(platform: .ios))
    XCTAssertTrue(scheduler.enqueue(frame(30_000, counter: counter)))
    XCTAssertEqual(scheduler.frame(at: 30_000, generation: 1)?.ptsUs, 30_000)

    XCTAssertFalse(scheduler.enqueue(frame(20_000, counter: counter)))
    XCTAssertFalse(scheduler.enqueue(frame(30_000, counter: counter)))
    XCTAssertNil(scheduler.frame(at: 40_000, generation: 1))
    XCTAssertEqual(scheduler.lateFrameDropCount, 2)
    XCTAssertEqual(counter.released, 3)
  }

  func testGenerationFlushCancelsWaitingEnqueueAndReleasesFrames() {
    assertWaitingEnqueueIsCancelled { $0.flush(generation: 2) }
  }

  func testDisposeCancelsWaitingEnqueueAndReleasesFrames() {
    assertWaitingEnqueueIsCancelled { $0.dispose() }
  }

  private func assertWaitingEnqueueIsCancelled(
    _ cancel: (YlFrameScheduler) -> Void
  ) {
    let counter = LifetimeCounter()
    let scheduler = YlFrameScheduler(
      compatibility: .init(platform: .ios), maxFrames: 1, enqueueWaitTimeout: 2
    )
    defer { scheduler.dispose() }
    XCTAssertTrue(scheduler.enqueue(frame(10_000, counter: counter)))
    let started = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      started.signal()
      XCTAssertFalse(scheduler.enqueue(self.frame(20_000, counter: counter)))
      completed.signal()
    }

    XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(completed.wait(timeout: .now() + 0.05), .timedOut)
    XCTAssertEqual(scheduler.pendingPTS, [10_000])
    cancel(scheduler)
    XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(scheduler.pendingPTS, [])
    XCTAssertEqual(counter.released, 2)
  }

  func testGenerationFlushAndDisposeReleaseAllFrames() {
    let counter = LifetimeCounter()
    let scheduler = YlFrameScheduler()
    scheduler.enqueue(frame(10_000, generation: 1, counter: counter))
    scheduler.enqueue(frame(20_000, generation: 2, counter: counter))

    scheduler.flush(generation: 3)
    XCTAssertEqual(scheduler.pendingPTS, [])
    XCTAssertEqual(counter.released, 2)
    XCTAssertNil(scheduler.frame(at: 30_000, generation: 2))

    scheduler.enqueue(frame(30_000, generation: 3, counter: counter))
    scheduler.dispose()
    scheduler.dispose()
    XCTAssertEqual(counter.released, 3)
  }
}
