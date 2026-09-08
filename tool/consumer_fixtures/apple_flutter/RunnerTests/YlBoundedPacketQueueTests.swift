@testable import yl_player_apple
import XCTest

final class YlBoundedPacketQueueTests: XCTestCase {
  private final class Token {}

  private func packet(
    bytes: Int = 10,
    durationUs: Int64 = 1_000,
    generation: UInt64 = 1
  ) -> YlPacketEnvelope {
    YlPacketEnvelope(
      packet: Token(),
      kind: .video,
      ptsUs: 0,
      dtsUs: 0,
      durationUs: durationUs,
      byteCount: bytes,
      keyframe: true,
      generation: generation
    )
  }

  func testAcceptsExactDurationAndByteBoundary() {
    let queue = YlBoundedPacketQueue(maxDurationUs: 1_000, maxBytes: 10)
    XCTAssertEqual(queue.push(packet()), .accepted)
    XCTAssertEqual(queue.count, 1)
    XCTAssertEqual(queue.bufferedDurationUs, 1_000)
    XCTAssertEqual(queue.bufferedBytes, 10)
  }

  func testRejectsOneByteAndOneMicrosecondOverLimit() {
    let bytesQueue = YlBoundedPacketQueue(maxDurationUs: 10_000, maxBytes: 10)
    XCTAssertEqual(bytesQueue.push(packet(bytes: 11)), .wouldExceedBytes)
    XCTAssertEqual(bytesQueue.count, 0)

    let durationQueue = YlBoundedPacketQueue(maxDurationUs: 1_000, maxBytes: 100)
    XCTAssertEqual(
      durationQueue.push(packet(durationUs: 1_001)),
      .wouldExceedDuration
    )
    XCTAssertEqual(durationQueue.count, 0)
  }

  func testBlockedProducerWakesAfterPop() {
    let queue = YlBoundedPacketQueue(maxDurationUs: 1_000, maxBytes: 10)
    XCTAssertEqual(queue.push(packet()), .accepted)
    let started = expectation(description: "producer started")
    let completed = expectation(description: "producer completed")

    DispatchQueue.global().async {
      started.fulfill()
      XCTAssertEqual(queue.waitAndPush(self.packet()), .accepted)
      completed.fulfill()
    }

    wait(for: [started], timeout: 1)
    XCTAssertNotNil(queue.pop())
    wait(for: [completed], timeout: 1)
    XCTAssertEqual(queue.count, 1)
  }

  func testCancellationWakesBlockedProducerAndReleasesQueuedPackets() {
    let queue = YlBoundedPacketQueue(maxDurationUs: 1_000, maxBytes: 10)
    XCTAssertEqual(queue.push(packet()), .accepted)
    let started = expectation(description: "producer started")
    let completed = expectation(description: "producer cancelled")

    DispatchQueue.global().async {
      started.fulfill()
      XCTAssertEqual(queue.waitAndPush(self.packet()), .cancelled)
      completed.fulfill()
    }

    wait(for: [started], timeout: 1)
    queue.cancel()
    wait(for: [completed], timeout: 1)
    XCTAssertTrue(queue.isCancelled)
    XCTAssertEqual(queue.count, 0)
  }
}
