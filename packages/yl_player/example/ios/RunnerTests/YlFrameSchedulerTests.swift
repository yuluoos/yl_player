@testable import yl_player_ios
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

  func testOwnsAtMostThreeFramesAndDropsOldest() {
    let counter = LifetimeCounter()
    let scheduler = YlFrameScheduler()
    scheduler.enqueue(frame(10_000, counter: counter))
    scheduler.enqueue(frame(20_000, counter: counter))
    scheduler.enqueue(frame(30_000, counter: counter))
    scheduler.enqueue(frame(40_000, counter: counter))

    XCTAssertEqual(scheduler.pendingPTS, [20_000, 30_000, 40_000])
    XCTAssertEqual(scheduler.lateFrameDropCount, 1)
    XCTAssertEqual(counter.released, 1)
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
