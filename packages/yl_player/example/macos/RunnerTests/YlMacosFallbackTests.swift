@testable import yl_player_apple
import AppKit
import AVFAudio
import Foundation
import VideoToolbox
import XCTest
import YlFFmpegBridge

final class YlMacosFallbackTests: XCTestCase {
  func testResetRejectsPendingReservationsFromTheOldDecoderGeneration() throws {
    let budget = YlVideoDecodeBudget(maxBytes: 12, maxFrames: 1)
    let old = try XCTUnwrap(budget.reservePending(byteCount: 12, timeout: 0))
    budget.reset()
    let current = try XCTUnwrap(budget.reservePending(byteCount: 8, timeout: 0))
    XCTAssertFalse(try old.beginDecoding(shouldCancel: { false }))
    old.release()
    XCTAssertEqual(budget.inFlightBytes, 8)
    current.release()
    XCTAssertEqual(budget.inFlightBytes, 0)
  }


  func testTerminalFailureTransitionIsOneShotAndInvalidatesWork() {
    let first = YlFallbackTerminalFailurePolicy.begin(
      disposed: false,
      active: true,
      hasError: false,
      videoGeneration: 7,
      audioGeneration: 11
    )

    XCTAssertEqual(first?.videoGeneration, 8)
    XCTAssertEqual(first?.audioGeneration, 12)
    XCTAssertNil(YlFallbackTerminalFailurePolicy.begin(
      disposed: false,
      active: false,
      hasError: true,
      videoGeneration: 8,
      audioGeneration: 12
    ))
  }


  func testActivationPolicyRejectsTerminalAndDisposedBackends() throws {
    XCTAssertFalse(try YlFallbackActivationPolicy.shouldActivate(
      disposed: false,
      active: true,
      hasTerminalError: false
    ))
    XCTAssertThrowsError(try YlFallbackActivationPolicy.shouldActivate(
      disposed: false,
      active: false,
      hasTerminalError: true
    )) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "resource.player_failed")
    }
    XCTAssertThrowsError(try YlFallbackActivationPolicy.shouldActivate(
      disposed: true,
      active: false,
      hasTerminalError: false
    )) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "macos.player_disposed")
    }
  }


  func testLiveReactivationPreservesPlaybackIntentAndResetsPosition() {
    XCTAssertEqual(
      YlFallbackReactivationPolicy.resolve(
        isSeekable: false,
        savedPositionUs: 8_000_000,
        selectedAudioStreamIndex: 3,
        shouldPlay: true
      ),
      YlFallbackResumeState(
        positionUs: 0,
        selectedAudioStreamIndex: 3,
        shouldPlay: true
      )
    )
  }


  func testRestorationCancellationIsNotReportedAsTerminalFailure() {
    let cancelled = YlOpenCancellationToken.cancellationError()
    XCTAssertFalse(YlFallbackRestorationPolicy.shouldReport(
      error: cancelled,
      isCurrentBackend: true
    ))
    XCTAssertFalse(YlFallbackRestorationPolicy.shouldReport(
      error: NativePlayerError(
        category: "network",
        code: "network.http_status",
        message: "failed"
      ),
      isCurrentBackend: false
    ))
    XCTAssertTrue(YlFallbackRestorationPolicy.shouldReport(
      error: NativePlayerError(
        category: "network",
        code: "network.http_status",
        message: "failed"
      ),
      isCurrentBackend: true
    ))
  }


  func testOnlyStateReplacingCommandsCancelRestoration() {
    for name: YlApplePlaybackCommand in [.play, .pause] {
      XCTAssertTrue(YlRestorationCommandPolicy.supersedesRestoration(name))
    }
    for name: YlApplePlaybackCommand in [
      .seek(0), .liveEdge, .track("audio"), .volume(1), .speed(1), .constraints(.unconstrained),
    ] {
      XCTAssertFalse(YlRestorationCommandPolicy.supersedesRestoration(name))
    }
    for name: YlApplePlaybackCommand in [.seek(0), .liveEdge, .track("audio")] {
      XCTAssertTrue(YlRestorationCommandPolicy.defersUntilRestored(name))
    }
  }


  func testBufferBudgetsStayWithinDocumentedCeilings() throws {
    let lowLatency = try YlFallbackBufferBudget.make(
      configuration: PlayerConfiguration(map: ["bufferMode": "lowLatency"])
    )
    XCTAssertEqual(lowLatency.networkBytes, 4 * 1024 * 1024)
    XCTAssertEqual(lowLatency.scheduledAudioBytes, 1 * 1024 * 1024)
    XCTAssertEqual(lowLatency.inFlightPacketBytes, 2 * 1024 * 1024)
  }


  func testPacketCallbackFailurePreservesTheNetworkCause() {
    let networkError = NativePlayerError(
      category: "network",
      code: "network.retry_exhausted",
      message: "Network media retries were exhausted.",
      diagnostic: "networkConnectionLost"
    )

    let error = ylFallbackPacketReadError(
      result: Int32(YLFResultCallbackFailed),
      inputError: networkError,
      container: .matroska
    )

    XCTAssertEqual(error.category, "network")
    XCTAssertEqual(error.code, "network.retry_exhausted")
    XCTAssertEqual(error.diagnostic, "networkConnectionLost")
  }




}
