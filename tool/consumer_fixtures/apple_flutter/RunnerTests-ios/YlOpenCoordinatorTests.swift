@testable import yl_player_apple
import XCTest

final class YlOpenCoordinatorTests: XCTestCase {
  private func candidate(_ id: Int) -> YlPreparedOpen {
    .avPlayer(source: YlAppleSourceDescriptor(uri: String(id), kind: .file))
  }

  private func candidateID(_ candidate: YlPreparedOpen) -> Int? {
    guard case let .avPlayer(source) = candidate else { return nil }
    return Int(source.uri)
  }

  func testPreparationRunsOffMainAndSuccessfulCommitRunsOnMain() {
    let coordinator = YlOpenCoordinator(label: "test.open.success")
    let completed = expectation(description: "completed")
    var preparedOnMain = true
    var committedOnMain = false

    _ = coordinator.begin(
      prepare: { token in
        try token.throwIfCancelled()
        preparedOnMain = Thread.isMainThread
        return self.candidate(1)
      },
      commit: { candidate in
        committedOnMain = Thread.isMainThread
        XCTAssertEqual(self.candidateID(candidate), 1)
      },
      completion: { result in
        if case let .failure(error) = result {
          XCTFail("Unexpected failure: \(error.code)")
        }
        completed.fulfill()
      }
    )

    wait(for: [completed], timeout: 2)
    XCTAssertFalse(preparedOnMain)
    XCTAssertTrue(committedOnMain)
  }

  func testSecondOpenCancelsFirstAndOnlyNewestCommits() {
    let coordinator = YlOpenCoordinator(label: "test.open.replace")
    let firstStarted = expectation(description: "first started")
    let firstCompleted = expectation(description: "first completed")
    let secondCompleted = expectation(description: "second completed")
    let cancellationLock = NSLock()
    var cancelCount = 0
    var firstCompletionCount = 0
    var secondCompletionCount = 0
    var committedIDs = [Int]()

    _ = coordinator.begin(
      prepare: { token in
        let released = DispatchSemaphore(value: 0)
        token.onCancel {
          cancellationLock.lock()
          cancelCount += 1
          cancellationLock.unlock()
          released.signal()
        }
        firstStarted.fulfill()
        released.wait()
        try token.throwIfCancelled()
        return self.candidate(1)
      },
      commit: { candidate in
        if let id = self.candidateID(candidate) { committedIDs.append(id) }
      },
      completion: { result in
        firstCompletionCount += 1
        if case let .failure(error) = result {
          XCTAssertEqual(error.code, "network.cancelled")
        }
        firstCompleted.fulfill()
      }
    )
    wait(for: [firstStarted], timeout: 1)

    _ = coordinator.begin(
      prepare: { _ in self.candidate(2) },
      commit: { candidate in
        if let id = self.candidateID(candidate) { committedIDs.append(id) }
      },
      completion: { result in
        secondCompletionCount += 1
        if case let .failure(error) = result {
          XCTFail("Unexpected failure: \(error.code)")
        }
        secondCompleted.fulfill()
      }
    )

    wait(for: [firstCompleted, secondCompleted], timeout: 2)
    XCTAssertEqual(committedIDs, [2])
    XCTAssertEqual(cancelCount, 1)
    XCTAssertEqual(firstCompletionCount, 1)
    XCTAssertEqual(secondCompletionCount, 1)
  }

  func testCancelCurrentCompletesPendingOpenExactlyOnce() {
    let coordinator = YlOpenCoordinator(label: "test.open.dispose")
    let started = expectation(description: "started")
    let completed = expectation(description: "completed")
    var completionCount = 0
    var commitCount = 0

    _ = coordinator.begin(
      prepare: { token in
        let released = DispatchSemaphore(value: 0)
        token.onCancel { released.signal() }
        started.fulfill()
        released.wait()
        try token.throwIfCancelled()
        return self.candidate(1)
      },
      commit: { _ in commitCount += 1 },
      completion: { result in
        completionCount += 1
        if case let .failure(error) = result {
          XCTAssertEqual(error.category, "cancelled")
          XCTAssertEqual(error.code, "network.cancelled")
        } else {
          XCTFail("Expected cancellation")
        }
        completed.fulfill()
      }
    )
    wait(for: [started], timeout: 1)

    coordinator.cancelCurrent()
    coordinator.cancelCurrent()

    wait(for: [completed], timeout: 2)
    XCTAssertEqual(completionCount, 1)
    XCTAssertEqual(commitCount, 0)
  }

  func testCancelWinsWhileFailedPreparationCompletionIsQueuedForMain() {
    let coordinator = YlOpenCoordinator(label: "test.open.cancel-before-callback")
    let preparationFailed = DispatchSemaphore(value: 0)
    let completed = expectation(description: "completed")
    var completionCode: String?

    _ = coordinator.begin(
      prepare: { _ in
        defer { preparationFailed.signal() }
        throw NativePlayerError(
          category: "network",
          code: "network.http_status",
          message: "Rejected"
        )
      },
      commit: { _ in XCTFail("Failed preparation must not commit") },
      completion: { result in
        if case let .failure(error) = result { completionCode = error.code }
        completed.fulfill()
      }
    )

    XCTAssertEqual(preparationFailed.wait(timeout: .now() + 1), .success)
    coordinator.cancelCurrent()

    wait(for: [completed], timeout: 2)
    XCTAssertEqual(completionCode, "network.cancelled")
  }

  func testCandidateThatFinishesAfterNewGenerationCannotCommit() {
    let coordinator = YlOpenCoordinator(label: "test.open.stale-candidate")
    let prepared = DispatchSemaphore(value: 0)
    let secondCompleted = expectation(description: "second completed")
    var committedIDs = [Int]()

    let firstGeneration = coordinator.begin(
      prepare: { _ in
        prepared.signal()
        return self.candidate(1)
      },
      commit: { candidate in
        if let id = self.candidateID(candidate) { committedIDs.append(id) }
      },
      completion: { _ in }
    )

    XCTAssertEqual(prepared.wait(timeout: .now() + 1), .success)
    let secondGeneration = coordinator.begin(
      prepare: { _ in self.candidate(2) },
      commit: { candidate in
        if let id = self.candidateID(candidate) { committedIDs.append(id) }
      },
      completion: { result in
        if case let .failure(error) = result {
          XCTFail("Unexpected failure: \(error.code)")
        }
        secondCompleted.fulfill()
      }
    )

    wait(for: [secondCompleted], timeout: 2)
    XCTAssertGreaterThan(secondGeneration, firstGeneration)
    XCTAssertEqual(committedIDs, [2])
  }

  func testPreparationFailureDoesNotCommitCandidate() {
    let coordinator = YlOpenCoordinator(label: "test.open.failure")
    let completed = expectation(description: "completed")
    var activeID = 7
    var completionCount = 0

    _ = coordinator.begin(
      prepare: { _ in
        throw NativePlayerError(
          category: "network",
          code: "network.http_status",
          message: "Rejected"
        )
      },
      commit: { candidate in activeID = self.candidateID(candidate) ?? -1 },
      completion: { result in
        completionCount += 1
        if case let .failure(error) = result {
          XCTAssertEqual(error.code, "network.http_status")
        } else {
          XCTFail("Expected failure")
        }
        completed.fulfill()
      }
    )

    wait(for: [completed], timeout: 2)
    XCTAssertEqual(activeID, 7)
    XCTAssertEqual(completionCount, 1)
  }

  func testHeaderedHlsPreflightFailureDoesNotReplaceActiveCandidate() {
    let coordinator = YlOpenCoordinator(label: "test.open.hls-preflight")
    let completed = expectation(description: "completed")
    let session = HlsLoaderURLProtocol.configuration { _, source in
      source.respond(status: 401, data: Data())
    }
    var activeID = 7

    _ = coordinator.begin(
      prepare: { token in
        let prepared = try YlPreparedHlsAsset(
          originURL: URL(string: "https://media.test/master.m3u8")!,
          headers: ["Authorization": "Bearer expired"],
          configuration: .init(map: [:]),
          cancellationToken: token,
          sessionConfiguration: session
        )
        return .headeredHls(source: YlAppleSourceDescriptor(uri: String(8), kind: .file), prepared: prepared)
      },
      commit: { candidate in activeID = self.candidateID(candidate) ?? 8 },
      completion: { result in
        guard case let .failure(error) = result else {
          XCTFail("Expected HLS preflight failure")
          completed.fulfill()
          return
        }
        XCTAssertEqual(error.code, "network.http_status")
        completed.fulfill()
      }
    )

    wait(for: [completed], timeout: 2)
    XCTAssertEqual(activeID, 7)
  }

  func testPreparationFailureCancelsLifetimeTokenBeforeCompletion() {
    let coordinator = YlOpenCoordinator(label: "test.open.failure-token")
    let completed = expectation(description: "completed")
    var cancelCount = 0

    _ = coordinator.begin(
      prepare: { token in
        token.onCancel { cancelCount += 1 }
        throw NativePlayerError(
          category: "network",
          code: "network.http_status",
          message: "Rejected"
        )
      },
      commit: { _ in XCTFail("Failed preparation must not commit") },
      completion: { _ in
        XCTAssertEqual(cancelCount, 1)
        completed.fulfill()
      }
    )

    wait(for: [completed], timeout: 2)
  }

  func testCancellationTokenInvokesLateAndEarlyHandlersOnce() {
    let token = YlOpenCancellationToken()
    var early = 0
    var late = 0
    token.onCancel { early += 1 }
    token.cancel()
    token.cancel()
    token.onCancel { late += 1 }

    XCTAssertTrue(token.isCancelled)
    XCTAssertEqual(early, 1)
    XCTAssertEqual(late, 1)
    XCTAssertThrowsError(try token.throwIfCancelled()) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "network.cancelled")
    }
  }
}

final class YlAsyncCommandCoordinatorTests: XCTestCase {
  func testCommandsRunInSubmissionOrderWithoutSupersedingEachOther() {
    let coordinator = YlAsyncCommandCoordinator(label: "test.command.fifo")
    let firstStarted = expectation(description: "first started")
    let bothCompleted = expectation(description: "both completed")
    bothCompleted.expectedFulfillmentCount = 2
    let releaseFirst = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var events = [Int]()

    coordinator.begin(
      operation: { token in
        firstStarted.fulfill()
        releaseFirst.wait()
        try token.throwIfCancelled()
        lock.lock()
        events.append(1)
        lock.unlock()
      },
      completion: { _ in bothCompleted.fulfill() }
    )
    wait(for: [firstStarted], timeout: 1)
    coordinator.begin(
      operation: { token in
        try token.throwIfCancelled()
        lock.lock()
        events.append(2)
        lock.unlock()
      },
      completion: { _ in bothCompleted.fulfill() }
    )

    releaseFirst.signal()
    wait(for: [bothCompleted], timeout: 2)
    XCTAssertEqual(events, [1, 2])
  }

  func testCommandRunsOffMainAndCompletesOnMain() {
    let coordinator = YlAsyncCommandCoordinator(label: "test.command.queue")
    let completed = expectation(description: "completed")

    coordinator.begin(
      operation: { token in
        XCTAssertFalse(Thread.isMainThread)
        try token.throwIfCancelled()
      },
      completion: { result in
        XCTAssertTrue(Thread.isMainThread)
        if case let .failure(error) = result {
          XCTFail("Unexpected failure: \(error.code)")
        }
        completed.fulfill()
      }
    )

    wait(for: [completed], timeout: 2)
  }

  func testCancelledCommandCompletesExactlyOnce() {
    let coordinator = YlAsyncCommandCoordinator(label: "test.command.cancel")
    let started = expectation(description: "started")
    let completed = expectation(description: "completed")
    var completionCount = 0

    coordinator.begin(
      operation: { token in
        started.fulfill()
        while !token.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
        try token.throwIfCancelled()
      },
      completion: { result in
        completionCount += 1
        guard case let .failure(error) = result else {
          XCTFail("Expected cancellation")
          completed.fulfill()
          return
        }
        XCTAssertEqual(error.code, "network.cancelled")
        completed.fulfill()
      }
    )
    wait(for: [started], timeout: 1)

    coordinator.cancelCurrent()

    wait(for: [completed], timeout: 2)
    XCTAssertEqual(completionCount, 1)
  }

  func testCancellationWinsWhileSuccessCompletionIsQueuedForMain() {
    let coordinator = YlAsyncCommandCoordinator(label: "test.command.queued")
    let bodyFinished = DispatchSemaphore(value: 0)
    let completed = expectation(description: "completed")

    coordinator.begin(
      operation: { _ in bodyFinished.signal() },
      completion: { result in
        guard case let .failure(error) = result else {
          XCTFail("A cancelled command must not report stale success")
          completed.fulfill()
          return
        }
        XCTAssertEqual(error.code, "network.cancelled")
        completed.fulfill()
      }
    )
    XCTAssertEqual(bodyFinished.wait(timeout: .now() + 1), .success)

    coordinator.cancelCurrent()

    wait(for: [completed], timeout: 2)
  }

  func testCancelledCoordinatorStaysAliveUntilCompletionIsDelivered() {
    var coordinator: YlAsyncCommandCoordinator? = YlAsyncCommandCoordinator(
      label: "test.command.lifetime"
    )
    weak var weakCoordinator = coordinator
    let started = expectation(description: "started")
    let completed = expectation(description: "completed")

    coordinator?.begin(
      operation: { token in
        started.fulfill()
        while !token.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
        try token.throwIfCancelled()
      },
      completion: { result in
        if case let .failure(error) = result {
          XCTAssertEqual(error.code, "network.cancelled")
        } else {
          XCTFail("Expected cancellation")
        }
        completed.fulfill()
      }
    )
    wait(for: [started], timeout: 1)
    coordinator?.cancelCurrent()
    coordinator = nil

    XCTAssertNotNil(weakCoordinator)
    wait(for: [completed], timeout: 2)
  }
}
