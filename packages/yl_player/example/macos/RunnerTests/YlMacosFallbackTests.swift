@testable import yl_player_media_core
@testable import yl_player_apple
import AppKit
import AVFAudio
import CryptoKit
import Foundation
import VideoToolbox
import XCTest
import YlFFmpegBridge

final class YlMacosFallbackTests: XCTestCase {
  func testPackagedAV1ProfileOnlyMatchesItsQualifiedImage() throws {
    let key = YlSoftwareDecodeKey(model: "M1-test", osBuild: "build", decoderBuild: "swift:bridge",
      codec: Int32(YLFCodecAV1), profile: 0, bitDepth: 8, chroma: 420, width: 320, height: 180,
      fpsNumerator: 24, fpsDenominator: 1, threads: 2, outputPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let limits = YlSoftwareDecodeLimits(maxOwnedBytes: 1024, maxFrames: 4, maxPacketBytes: 128,
      windowNs: 1000, maxCpuNs: 500, maxDecodeWallNs: 200)
    let encoder = JSONEncoder()
    var record: [String: Any] = ["schemaVersion": 1, "baselineSHA256": String(repeating: "a", count: 64),
      "verificationSHA256": String(repeating: "b", count: 64),
      "key": try JSONSerialization.jsonObject(with: encoder.encode(key)),
      "limits": try JSONSerialization.jsonObject(with: encoder.encode(limits))]
    func read() throws -> YlSoftwareDecodeAdmission {
      .init(qualifiedProfile: try JSONSerialization.data(withJSONObject: record))
    }
    XCTAssertEqual(try read().limits(for: key), limits)
    var different = try XCTUnwrap(record["key"] as? [String: Any])
    different["decoderBuild"] = "other:bridge"
    record["key"] = different
    XCTAssertNil(try read().limits(for: key))
    record["verificationSHA256"] = record["baselineSHA256"]
    XCTAssertTrue(try read().entries.isEmpty)
  }

  func testSoftwareDecodeIdentityIncludesImageContainingDecoder() throws {
    let address = unsafeBitCast(YlSoftwareVideoDecoder.self, to: UnsafeRawPointer.self)
    var image = Dl_info()
    XCTAssertNotEqual(dladdr(address, &image), 0)
    let path = String(cString: try XCTUnwrap(image.dli_fname))
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let identity = try XCTUnwrap(YlSoftwareDecodeIdentity.current)
    XCTAssertEqual(identity.decoderBuild.components(separatedBy: ":").first, expected)
  }

  func testMp4OpenFailurePreservesPublicContainerCode() {
    XCTAssertThrowsError(try YlOpenedMedia(
      recipe: .local(path: "/dev/null", container: .mp4)
    )) { error in
      let failure = YlAppleSafeDiagnostics.failure(error, scope: .command)
      XCTAssertEqual(failure.code, "container.mp4_open_failed")
      XCTAssertTrue(failure.message.contains("complete MP4 file"))
    }
  }

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
