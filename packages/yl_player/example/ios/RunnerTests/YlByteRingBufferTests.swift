@testable import yl_player_ios
import XCTest

final class YlByteRingBufferTests: XCTestCase {
  func testAppendNeverExceedsExactCapacity() throws {
    let buffer = YlByteRingBuffer(capacity: 4)

    XCTAssertEqual(try buffer.append(Data([1, 2, 3, 4]), at: 0), 4)
    XCTAssertEqual(buffer.bufferedBytes, 4)
    XCTAssertEqual(try buffer.append(Data([5]), at: 4), 0)
    XCTAssertEqual(buffer.bufferedBytes, 4)
  }

  func testPartialReadCanRewindInsideRetainedWindow() throws {
    let buffer = YlByteRingBuffer(capacity: 4)
    XCTAssertEqual(try buffer.append(Data([1, 2, 3, 4]), at: 0), 4)
    var first = [UInt8](repeating: 0, count: 2)
    XCTAssertEqual(
      try first.withUnsafeMutableBytes { try buffer.read(into: $0) },
      2
    )
    XCTAssertEqual(first, [1, 2])

    XCTAssertTrue(buffer.seekWithinBuffer(to: 1))
    var replay = [UInt8](repeating: 0, count: 3)
    XCTAssertEqual(
      try replay.withUnsafeMutableBytes { try buffer.read(into: $0) },
      3
    )
    XCTAssertEqual(replay, [2, 3, 4])
    XCTAssertEqual(buffer.currentOffset, 4)
  }

  func testAppendRejectsNoncontiguousOffset() throws {
    let buffer = YlByteRingBuffer(capacity: 4)
    XCTAssertEqual(try buffer.append(Data([1]), at: 10), 1)

    XCTAssertThrowsError(try buffer.append(Data([2]), at: 12)) { error in
      guard case let YlByteSourceError.invalidOffset(expected, actual) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(expected, 11)
      XCTAssertEqual(actual, 12)
    }
  }

  func testReadBlocksUntilProducerAppends() throws {
    let buffer = YlByteRingBuffer(capacity: 8)
    let started = expectation(description: "read started")
    let finished = expectation(description: "read wakes")
    DispatchQueue.global().async {
      started.fulfill()
      var bytes = [UInt8](repeating: 0, count: 3)
      do {
        let count = try bytes.withUnsafeMutableBytes { try buffer.read(into: $0) }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(bytes, [7, 8, 9])
      } catch {
        XCTFail("Unexpected read error: \(error)")
      }
      finished.fulfill()
    }
    wait(for: [started], timeout: 1)

    XCTAssertEqual(try buffer.append(Data([7, 8, 9]), at: 0), 3)

    wait(for: [finished], timeout: 1)
  }

  func testBlockingWriteAppliesBackpressureUntilConsumerReads() throws {
    let buffer = YlByteRingBuffer(capacity: 4)
    let writeFinished = expectation(description: "write finishes")
    DispatchQueue.global().async {
      do {
        try buffer.write(Data([0, 1, 2, 3, 4, 5, 6, 7]), at: 0)
      } catch {
        XCTFail("Unexpected write error: \(error)")
      }
      writeFinished.fulfill()
    }

    var output = [UInt8]()
    for _ in 0..<2 {
      var chunk = [UInt8](repeating: 0, count: 4)
      let count = try chunk.withUnsafeMutableBytes { try buffer.read(into: $0) }
      output.append(contentsOf: chunk.prefix(count))
    }

    wait(for: [writeFinished], timeout: 1)
    XCTAssertEqual(output, Array(0...7))
    XCTAssertLessThanOrEqual(buffer.bufferedBytes, buffer.capacity)
  }

  func testFinishReturnsZeroOnlyAfterBufferedBytesDrain() throws {
    let buffer = YlByteRingBuffer(capacity: 4)
    XCTAssertEqual(try buffer.append(Data([1, 2]), at: 0), 2)
    buffer.finish()
    var bytes = [UInt8](repeating: 0, count: 4)

    XCTAssertEqual(
      try bytes.withUnsafeMutableBytes { try buffer.read(into: $0) },
      2
    )
    XCTAssertEqual(
      try bytes.withUnsafeMutableBytes { try buffer.read(into: $0) },
      0
    )
  }

  func testFailureWakesBlockedReader() {
    let buffer = YlByteRingBuffer(capacity: 8)
    let finished = expectation(description: "failure wakes")
    DispatchQueue.global().async {
      var bytes = [UInt8](repeating: 0, count: 1)
      do {
        _ = try bytes.withUnsafeMutableBytes { try buffer.read(into: $0) }
        XCTFail("Expected read failure")
      } catch {
        guard case let YlByteSourceError.failed(nativeError) = error else {
          return XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(nativeError.code, "network.read_timeout")
      }
      finished.fulfill()
    }

    buffer.fail(NativePlayerError(
      category: "network",
      code: "network.read_timeout",
      message: "Timed out."
    ))

    wait(for: [finished], timeout: 1)
  }

  func testCancelWakesBlockedReader() {
    let buffer = YlByteRingBuffer(capacity: 8)
    let finished = expectation(description: "cancel wakes")
    DispatchQueue.global().async {
      var bytes = [UInt8](repeating: 0, count: 1)
      do {
        _ = try bytes.withUnsafeMutableBytes { try buffer.read(into: $0) }
        XCTFail("Expected cancellation")
      } catch {
        guard case YlByteSourceError.cancelled = error else {
          return XCTFail("Unexpected error: \(error)")
        }
      }
      finished.fulfill()
    }

    buffer.cancel()

    wait(for: [finished], timeout: 1)
  }

  func testResetDropsBytesAndChangesAbsoluteOffset() throws {
    let buffer = YlByteRingBuffer(capacity: 8)
    XCTAssertEqual(try buffer.append(Data([1, 2, 3]), at: 0), 3)

    buffer.reset(at: 100)

    XCTAssertEqual(buffer.bufferedBytes, 0)
    XCTAssertEqual(buffer.currentOffset, 100)
    XCTAssertEqual(try buffer.append(Data([9]), at: 100), 1)
  }

  func testShrinkEvictsConsumedBytesAndPausesUntilUnreadBytesDrain() throws {
    let buffer = YlByteRingBuffer(capacity: 8)
    XCTAssertEqual(try buffer.append(Data(Array(0...7)), at: 0), 8)
    var consumed = [UInt8](repeating: 0, count: 4)
    XCTAssertEqual(
      try consumed.withUnsafeMutableBytes { try buffer.read(into: $0) },
      4
    )

    buffer.shrink(to: 2)

    XCTAssertEqual(buffer.capacity, 2)
    XCTAssertEqual(buffer.bufferedBytes, 4)
    XCTAssertEqual(try buffer.append(Data([8]), at: 8), 0)
    var remainder = [UInt8](repeating: 0, count: 4)
    XCTAssertEqual(
      try remainder.withUnsafeMutableBytes { try buffer.read(into: $0) },
      4
    )
    XCTAssertEqual(remainder, [4, 5, 6, 7])
    XCTAssertEqual(buffer.bufferedBytes, 0)
  }

  func testConcurrentThousandChunkTransferPreservesBytesAndLimit() throws {
    let buffer = YlByteRingBuffer(capacity: 64)
    let expected = (0..<1000).map { UInt8($0 % 251) }
    let writeFinished = expectation(description: "producer finishes")
    DispatchQueue.global().async {
      do {
        for (offset, byte) in expected.enumerated() {
          try buffer.write(Data([byte]), at: Int64(offset))
          XCTAssertLessThanOrEqual(buffer.bufferedBytes, buffer.capacity)
        }
        buffer.finish()
      } catch {
        XCTFail("Unexpected producer error: \(error)")
      }
      writeFinished.fulfill()
    }

    var actual = [UInt8]()
    var scratch = [UInt8](repeating: 0, count: 17)
    while true {
      let count = try scratch.withUnsafeMutableBytes { try buffer.read(into: $0) }
      if count == 0 { break }
      actual.append(contentsOf: scratch.prefix(count))
      XCTAssertLessThanOrEqual(buffer.bufferedBytes, buffer.capacity)
    }

    wait(for: [writeFinished], timeout: 5)
    XCTAssertEqual(actual, expected)
  }
}
