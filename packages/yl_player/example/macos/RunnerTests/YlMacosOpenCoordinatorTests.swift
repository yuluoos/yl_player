@testable import yl_player_macos
import XCTest

final class YlMacosOpenCoordinatorTests: XCTestCase {
  private final class BackendSpy: YlPlaybackBackend {
    var isActive: Bool
    var activationError: NativePlayerError?
    private(set) var disposed = false

    init(active: Bool, activationError: NativePlayerError? = nil) {
      isActive = active
      self.activationError = activationError
    }

    func activate() throws {
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
}
