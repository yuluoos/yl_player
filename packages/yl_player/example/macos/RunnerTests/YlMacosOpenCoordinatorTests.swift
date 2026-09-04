@testable import yl_player_macos
import XCTest

final class YlMacosOpenCoordinatorTests: XCTestCase {
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
