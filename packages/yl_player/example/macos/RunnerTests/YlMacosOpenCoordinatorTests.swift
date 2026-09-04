@testable import yl_player_macos
import XCTest

final class YlMacosOpenCoordinatorTests: XCTestCase {
  private final class BackendSpy: YlPlaybackBackend {
    var isActive: Bool
    var requiresExternalRollbackActivation = false
    var activationError: NativePlayerError?
    private(set) var disposed = false
    private(set) var activationCount = 0

    init(active: Bool, activationError: NativePlayerError? = nil) {
      isActive = active
      self.activationError = activationError
    }

    func activate() throws {
      activationCount += 1
      if let activationError { throw activationError }
      isActive = true
    }

    func quiesceForReplacement() { isActive = false }
    func deactivate() { isActive = false }
    func command(name: String, arguments: [String: Any?]) throws {}
    func emitState() {}
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? { nil }
    func dispose() { disposed = true; isActive = false }
  }

  func testBackendSlotQuiescesBeforePreparingAndRollsBackOnFailure() {
    let previous = BackendSpy(active: true)
    let slot = YlBackendSlot(initial: previous)
    let expected = NativePlayerError(
      category: "resource",
      code: "resource.video_decoder_limit",
      message: "decoder busy"
    )

    XCTAssertThrowsError(try slot.replace {
      XCTAssertFalse(previous.isActive)
      throw expected
    })
    XCTAssertTrue(previous.isActive)
    XCTAssertTrue(slot.current === previous)
  }

  func testBackendSlotDisposesCandidateWhenActivationFails() {
    let previous = BackendSpy(active: true)
    let candidate = BackendSpy(
      active: false,
      activationError: NativePlayerError(
        category: "decoderUnsupported",
        code: "decoder.video_hardware_unavailable",
        message: "unavailable"
      )
    )
    let slot = YlBackendSlot(initial: previous)

    XCTAssertThrowsError(try slot.replace { candidate })
    XCTAssertTrue(candidate.disposed)
    XCTAssertTrue(previous.isActive)
    XCTAssertTrue(slot.current === previous)
  }

  func testBackendSlotDoesNotActivateInactivePreviousOnPrepareFailure() {
    let previous = BackendSpy(active: false)
    let slot = YlBackendSlot(initial: previous)

    XCTAssertThrowsError(try slot.replace {
      throw NativePlayerError(
        category: "resource",
        code: "resource.video_decoder_limit",
        message: "decoder busy"
      )
    })
    XCTAssertFalse(previous.isActive)
    XCTAssertTrue(slot.current === previous)
  }

  func testBackendSlotExposesActiveRollbackThatNeedsAsyncRecovery() {
    let previous = BackendSpy(
      active: true,
      activationError: NativePlayerError(
        category: "internal",
        code: "macos.async_activation_required",
        message: "async recovery required"
      )
    )
    let slot = YlBackendSlot(initial: previous)

    XCTAssertThrowsError(try slot.replace {
      throw NativePlayerError(
        category: "source",
        code: "source.open_failed",
        message: "candidate failed"
      )
    })
    XCTAssertFalse(previous.isActive)
    XCTAssertTrue(slot.takeRollbackRequiresExternalActivation())
    XCTAssertFalse(slot.takeRollbackRequiresExternalActivation())
  }

  func testBackendSlotDoesNotSynchronouslyReactivateExternalOnlyBackend() {
    let previous = BackendSpy(active: true)
    previous.requiresExternalRollbackActivation = true
    let slot = YlBackendSlot(initial: previous)

    XCTAssertThrowsError(try slot.replace {
      throw NativePlayerError(
        category: "source",
        code: "source.open_failed",
        message: "candidate failed"
      )
    })
    XCTAssertEqual(previous.activationCount, 0)
    XCTAssertTrue(slot.takeRollbackRequiresExternalActivation())
  }

  private func candidate(_ id: Int) -> YlPreparedOpen {
    .avPlayer(source: ["id": id])
  }

  private func candidateID(_ candidate: YlPreparedOpen) -> Int? {
    guard case let .avPlayer(source) = candidate else { return nil }
    return source["id"] as? Int
  }

  func testSecondOpenCancelsFirstCompletionAndOnlyNewestCommits() {
    let coordinator = YlOpenCoordinator(label: "test.macos.open.replace")
    let firstStarted = expectation(description: "first started")
    let firstCompleted = expectation(description: "first completed")
    let secondCompleted = expectation(description: "second completed")
    var committedIDs = [Int]()

    _ = coordinator.begin(
      prepare: { token in
        let released = DispatchSemaphore(value: 0)
        token.onCancel { released.signal() }
        firstStarted.fulfill()
        released.wait()
        try token.throwIfCancelled()
        return self.candidate(1)
      },
      commit: { candidate in
        if let id = self.candidateID(candidate) { committedIDs.append(id) }
      },
      completion: { result in
        guard case let .failure(error) = result else {
          XCTFail("Expected the superseded open to be cancelled")
          firstCompleted.fulfill()
          return
        }
        XCTAssertEqual(error.category, "cancelled")
        XCTAssertEqual(error.code, "network.cancelled")
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
        if case let .failure(error) = result {
          XCTFail("Unexpected failure: \(error.code)")
        }
        secondCompleted.fulfill()
      }
    )

    wait(for: [firstCompleted, secondCompleted], timeout: 2)
    XCTAssertEqual(committedIDs, [2])
  }

  func testRecoveryOnlyStartsAfterLatestOperationHasFinished() {
    let coordinator = YlOpenCoordinator(label: "test.macos.open.recovery")
    let started = expectation(description: "started")
    let cancelled = expectation(description: "cancelled")
    let generation = coordinator.begin(
      prepare: { token in
        started.fulfill()
        while !token.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
        throw YlOpenCancellationToken.cancellationError()
      },
      commit: { _ in },
      completion: { _ in cancelled.fulfill() }
    )
    wait(for: [started], timeout: 1)
    XCTAssertFalse(coordinator.canBeginRecovery(after: generation))
    coordinator.cancelCurrent()
    wait(for: [cancelled], timeout: 1)
    XCTAssertTrue(coordinator.canBeginRecovery(after: generation))

    let newer = coordinator.begin(
      prepare: { _ in self.candidate(2) },
      commit: { _ in },
      completion: { _ in }
    )
    XCTAssertGreaterThan(newer, generation)
    XCTAssertFalse(coordinator.canBeginRecovery(after: generation))
    coordinator.cancelCurrent()
  }
}
