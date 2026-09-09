import XCTest
import YlFFmpegBridge
@testable import yl_player_apple

@MainActor
final class YlAppleReconciliationTests: XCTestCase {
  func testSamePreparedReaderReconcilesLatePositiveSeekBackToZeroBeforeCommit() async throws {
    let gate = AppleRequestGate()
    let server = try ReactivationMediaServer(data: AppleHostCharacterizations.fixtureMedia(), onRequest: gate.observe)
    defer { server.close() }
    let source: [String: Any?] = ["uri": server.url.absoluteString, "kind": "network", "formatHint": "matroska"]
    let coordinator = YlOpenCoordinator()
    let held = expectation(description: "same candidate's positive reconciliation seek finished, commit still withheld")
    let completed = expectation(description: "latest candidate committed")
    let release = DispatchSemaphore(value: 0); defer { release.signal() }
    var prepared: YlPreparedFallback?
    var originalToken: YlOpenCancellationToken?
    var preparations = 0, updates = 0, commits = 0
    var revision = 1, preparedRevision = 0
    var targetUs: Int64 = 3_000_000
    coordinator.begin(prepare: { token in
      preparations += 1; originalToken = token
      let value = try YlPreparedFallback(source: source, requireHardwareProbe: false,
        configuration: PlayerConfiguration(map: [:]), cancellationToken: token)
      prepared = value
      return .fallback(source: source, prepared: value)
    }, commit: { candidate in
      XCTAssertTrue(Thread.isMainThread)
      guard case .fallback(_, let value) = candidate else { return XCTFail("Wrong candidate") }
      XCTAssertTrue(value === prepared)
      XCTAssertEqual(preparedRevision, revision)
      XCTAssertEqual(value.resumeState?.positionUs, 0)
      let media = try value.takeMedia(); defer { media.close() }
      let context = try XCTUnwrap(media.context)
      var packet: YLFPacketRef?
      XCTAssertEqual(ylf_read_packet(context, &packet), 0)
      let actual = try XCTUnwrap(packet)
      defer { ylf_packet_release(&packet) }
      XCTAssertGreaterThan(ylf_packet_size(actual), 0)
      XCTAssertLessThan(ylf_packet_pts_us(actual), 100_000,
        "A zero resume-state label must correspond to real demux output rewound from the earlier positive seek")
      commits += 1
    }, reconcile: { candidate in
      XCTAssertTrue(Thread.isMainThread)
      guard preparedRevision != revision else { return nil }
      guard case .fallback(_, let value) = candidate else { return nil }
      let capturedRevision = revision, capturedTarget = targetUs
      return { token in
        XCTAssertFalse(Thread.isMainThread)
        XCTAssertTrue(token === originalToken)
        XCTAssertTrue(value === prepared)
        updates += 1
        try value.prepareForReactivation(.init(positionUs: capturedTarget,
          selectedAudioStreamIndex: nil, shouldPlay: false))
        if capturedRevision == 1 { held.fulfill(); _ = release.wait(timeout: .now() + 5) }
        preparedRevision = capturedRevision
      }
    }, completion: { result in
      if case let .failure(error) = result { XCTFail("Unexpected \(error.code)") }
      completed.fulfill()
    })
    await fulfillment(of: [held], timeout: 5)
    XCTAssertEqual(commits, 0)
    revision = 2; targetUs = 0
    release.signal()
    await fulfillment(of: [completed], timeout: 5)
    XCTAssertEqual(preparations, 1, "Reconciliation never creates a fresh reader")
    XCTAssertEqual(updates, 2)
    XCTAssertEqual(commits, 1)
    XCTAssertFalse(gate.observed.isEmpty, "Preparation exercised the actual network request path")
  }

  func testCancellationDuringSameCandidateReconciliationSettlesOnceAndDiscardsMedia() async throws {
    try await discardReconciliation(supersede: false)
  }

  func testSupersessionDuringReconciliationDiscardsOldMediaAndCommitsOnlyNewCandidate() async throws {
    try await discardReconciliation(supersede: true)
  }

  private func discardReconciliation(supersede: Bool) async throws {
    let server = try ReactivationMediaServer(data: AppleHostCharacterizations.fixtureMedia()); defer { server.close() }
    let source: [String: Any?] = ["uri": server.url.absoluteString, "kind": "network", "formatHint": "matroska"]
    let coordinator = YlOpenCoordinator()
    let held = expectation(description: "real candidate reconciliation held")
    let completed = expectation(description: "cancellation settles before worker release")
    let release = DispatchSemaphore(value: 0); defer { release.signal() }
    var prepared: YlPreparedFallback?
    var completions = 0, commits = 0, cancellations = 0
    coordinator.begin(prepare: { token in
      token.onCancel { cancellations += 1 }
      let value = try YlPreparedFallback(source: source, requireHardwareProbe: false,
        configuration: PlayerConfiguration(map: [:]), cancellationToken: token)
      prepared = value
      return .fallback(source: source, prepared: value)
    }, commit: { _ in commits += 1 }, reconcile: { candidate in
      guard case .fallback(_, let value) = candidate else { return nil }
      return { _ in
        try value.prepareForReactivation(.init(positionUs: 3_000_000, selectedAudioStreamIndex: nil, shouldPlay: false))
        held.fulfill(); _ = release.wait(timeout: .now() + 5)
      }
    }, completion: { result in
      completions += 1
      if case .success = result { XCTFail("Cancelled candidate committed") }
      completed.fulfill()
    })
    await fulfillment(of: [held], timeout: 5)
    let replacementCompleted = expectation(description: "replacement completion")
    var replacementCommits = 0
    if supersede {
      coordinator.begin(prepare: { _ in .avPlayer(source: [:]) }, commit: { _ in replacementCommits += 1 },
        completion: { result in
          if case .failure = result { XCTFail("Current replacement rejected by stale reconciliation") }
          replacementCompleted.fulfill()
        })
    } else {
      coordinator.cancelCurrent()
      replacementCompleted.fulfill()
    }
    await fulfillment(of: [completed], timeout: 1)
    XCTAssertEqual(commits, 0)
    release.signal()
    await fulfillment(of: [replacementCompleted], timeout: 5)
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(replacementCommits, supersede ? 1 : 0)
    XCTAssertEqual(completions, 1)
    XCTAssertEqual(cancellations, 1)
    XCTAssertEqual(commits, 0)
    XCTAssertThrowsError(try prepared?.takeMedia(), "Cancelled candidate relinquished the actual prepared media")
  }
}
