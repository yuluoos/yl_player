@testable import yl_player_ios
import CoreVideo
import XCTest
import YlFFmpegBridge

final class YlFallbackBackendTests: XCTestCase {
  private final class FakeBackend: YlPlaybackBackend {
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    private(set) var disposeCount = 0
    var activationError: Error?
    var isActive: Bool { activateCount > deactivateCount }

    func activate() throws {
      activateCount += 1
      if let activationError { throw activationError }
    }
    func deactivate() { deactivateCount += 1 }
    func command(name: String, arguments: [String: Any?]) throws {}
    func emitState() {}
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? { nil }
    func dispose() { disposeCount += 1 }
  }

  private struct ExpectedFailure: Error {}

  private final class IrreversibleBackend: YlPlaybackBackend {
    private(set) var active = true
    private(set) var permanentlyClosed = false
    private(set) var quiesceCount = 0
    var isActive: Bool { active }

    func activate() throws {
      if permanentlyClosed { throw ExpectedFailure() }
      active = true
    }
    func deactivate() {
      active = false
      permanentlyClosed = true
    }
    func quiesceForReplacement() {
      active = false
      quiesceCount += 1
    }
    func command(name: String, arguments: [String: Any?]) throws {}
    func emitState() {}
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? { nil }
    func dispose() { permanentlyClosed = true }
  }

  func testPreparationFailurePreservesCurrentBackend() throws {
    let original = FakeBackend()
    let slot = YlBackendSlot(initial: original)
    try original.activate()

    XCTAssertThrowsError(try slot.replace { throw ExpectedFailure() })
    XCTAssertTrue(slot.current === original)
    XCTAssertEqual(original.deactivateCount, 0)
  }

  func testReplacementKeepsOnlyOneBackendActive() throws {
    let original = FakeBackend()
    let replacement = FakeBackend()
    let slot = YlBackendSlot(initial: original)
    try original.activate()

    try slot.replace { replacement }
    XCTAssertEqual(original.deactivateCount, 1)
    XCTAssertEqual(replacement.activateCount, 1)
    XCTAssertTrue(slot.current === replacement)
  }

  func testActivationFailureRestoresPreviousBackendAndDisposesCandidate() throws {
    let original = FakeBackend()
    let candidate = FakeBackend()
    candidate.activationError = ExpectedFailure()
    let slot = YlBackendSlot(initial: original)
    try original.activate()

    XCTAssertThrowsError(try slot.replace { candidate })
    XCTAssertTrue(slot.current === original)
    XCTAssertTrue(original.isActive)
    XCTAssertEqual(original.deactivateCount, 1)
    XCTAssertEqual(original.activateCount, 2)
    XCTAssertEqual(candidate.activateCount, 1)
    XCTAssertEqual(candidate.disposeCount, 1)
  }

  func testActivationFailureRestoresBackendWithoutPermanentTeardown() {
    let original = IrreversibleBackend()
    let candidate = FakeBackend()
    candidate.activationError = ExpectedFailure()
    let slot = YlBackendSlot(initial: original)

    XCTAssertThrowsError(try slot.replace { candidate })

    XCTAssertTrue(slot.current === original)
    XCTAssertTrue(original.isActive)
    XCTAssertFalse(original.permanentlyClosed)
    XCTAssertEqual(original.quiesceCount, 1)
  }

  func testGenerationRejectsCallbacksFromReplacedBackend() throws {
    let slot = YlBackendSlot(initial: FakeBackend())
    let oldGeneration = slot.generation
    try slot.replace { FakeBackend() }
    XCTAssertFalse(slot.accepts(generation: oldGeneration))
    XCTAssertTrue(slot.accepts(generation: slot.generation))
  }

  func testDisposeIsIdempotentFromPartialState() {
    let backend = FakeBackend()
    let slot = YlBackendSlot(initial: backend)
    slot.dispose()
    slot.dispose()
    XCTAssertEqual(backend.disposeCount, 1)
  }

  func testRealMkvPreflightEitherPreparesOrReturnsStableHardwareError() throws {
    let fixture = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mkv")
    )
    var prepared: YlPreparedFallback?
    do {
      prepared = try YlPreparedFallback(source: [
        "uri": fixture.absoluteString,
        "kind": "file",
        "formatHint": "matroska",
        "isLive": false,
      ])
    } catch {
      XCTAssertEqual(
        (error as? NativePlayerError)?.code,
        "decoder.video_hardware_unavailable"
      )
    }
    if let prepared {
      XCTAssertGreaterThan(prepared.videoStream.width, 0)
      guard case let .local(path, container) = prepared.sourceRecipe else {
        return XCTFail("Expected local source recipe")
      }
      XCTAssertEqual(path, fixture.path)
      XCTAssertEqual(container, .matroska)
    }
    prepared = nil
    XCTAssertEqual(ylf_debug_outstanding_packet_count(), 0)
  }

  func testDiscardedPreparedFallbackCannotTransferItsMedia() throws {
    let fixture = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mkv")
    )
    let prepared = try YlPreparedFallback(
      source: [
        "uri": fixture.absoluteString,
        "kind": "file",
        "formatHint": "matroska",
        "isLive": false,
      ],
      requireHardwareProbe: false
    )

    prepared.discard()
    prepared.discard()

    XCTAssertThrowsError(try prepared.takeMedia()) { error in
      XCTAssertEqual(
        (error as? NativePlayerError)?.code,
        "internal.fallback_invariant"
      )
    }
  }

  func testInFlightPacketBudgetRejectsOversizedCompressedPacket() throws {
    let budget = try YlFallbackBufferBudget.make(configuration: PlayerConfiguration(map: [
      "bufferMode": "lowLatency",
    ]))

    XCTAssertNoThrow(try budget.validateInFlightPacket(size: budget.inFlightPacketBytes))
    XCTAssertThrowsError(
      try budget.validateInFlightPacket(size: budget.inFlightPacketBytes + 1)
    ) { error in
      XCTAssertEqual((error as? NativePlayerError)?.category, "resource")
      XCTAssertEqual((error as? NativePlayerError)?.code, "resource.network_buffer_limit")
    }
  }
}
