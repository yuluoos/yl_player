@testable import yl_player_apple
import XCTest
import Flutter
import UIKit
import AVFoundation

final class YlIosChannelTests: XCTestCase {
  private final class NativeRegistry: NSObject, FlutterTextureRegistry {
    var texture: FlutterTexture?
    var removed: [Int64] = []
    var textureFrames = 0
    func register(_ texture: FlutterTexture) -> Int64 { self.texture = texture; return 71 }
    func textureFrameAvailable(_ textureId: Int64) { textureFrames += 1 }
    func unregisterTexture(_ textureId: Int64) { texture = nil; removed.append(textureId) }
  }

  @MainActor
  func testDisplayDriverKeepsUpWithSixtyFpsVideo() async throws {
    let registry = NativeRegistry()
    let services = YlIosPlatformAdapter.makeServices(textures: registry)
    defer { services.textureOutput.dispose() }
    let ticks = expectation(description: "Display callbacks for 60 fps video")
    ticks.expectedFulfillmentCount = 46
    var times: [CFTimeInterval] = []
    let driver = services.makeDisplayDriver {
      guard times.count < 46 else { return }
      times.append(CACurrentMediaTime())
      ticks.fulfill()
    }
    defer { driver.invalidate() }
    await fulfillment(of: [ticks], timeout: 4)
    let intervals = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
    guard !intervals.isEmpty else { return XCTFail("No display callbacks") }
    // Ignore occasional host scheduling delays, but reject a persistent 30 Hz
    // presentation cadence that discards due frames from 50/60 fps media.
    XCTAssertLessThan(intervals[intervals.count / 2], 1.0 / 45.0,
      "The iOS video output must not systematically sample 60 fps media at 30 Hz")
  }

  @MainActor
  func testNativeVideoViewClearResizeReattachAndDispose() async throws {
    let registry = NativeRegistry()
    let factory = YlIosVideoViewFactory()
    let output = YlIosTextureOutput(textures: registry, nativeViews: factory)
    var old: FlutterPlatformView? = factory.create(withFrame: CGRect(x: 0, y: 0, width: 200, height: 100),
      viewIdentifier: 1, arguments: ["textureId": Int64(71)])
    let oldContainer = try XCTUnwrap(old?.view().layer)
    let firstLayer = try XCTUnwrap(oldContainer.sublayers?.first as? AVSampleBufferDisplayLayer)
    var pixel: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
    output.publish(try XCTUnwrap(pixel))
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    XCTAssertEqual(registry.textureFrames, 0, "Native frames must bypass Flutter's 8-bit texture pipeline")
    output.clear()
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    XCTAssertNil(firstLayer.superlayer)
    XCTAssertFalse(oldContainer.sublayers?.first === firstLayer)
    let current = factory.create(withFrame: CGRect(x: 0, y: 0, width: 300, height: 160),
      viewIdentifier: 2, arguments: ["textureId": Int64(71)])
    old = nil
    XCTAssertEqual(current.view().layer.sublayers?.count, 1, "Retired view disposal cannot detach current surface")
    current.view().bounds.size = CGSize(width: 400, height: 240)
    current.view().setNeedsLayout()
    current.view().layoutIfNeeded()
    XCTAssertEqual(current.view().layer.sublayers?.first?.frame.size, CGSize(width: 400, height: 240))
    output.dispose()
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    XCTAssertTrue(current.view().layer.sublayers?.isEmpty ?? true)
    XCTAssertEqual(registry.removed, [71])
    let stale = factory.create(withFrame: .zero, viewIdentifier: 3, arguments: ["textureId": Int64(71)])
    XCTAssertTrue(stale.view().layer.sublayers?.isEmpty ?? true)
  }

  func testVideoOutputGapIsVisibleWhileThePlaybackTimelineAdvances() throws {
    let probe = YlAvPlayerVideoProgressProbe()
    XCTAssertNil(probe.observe(enabled: true, framePublished: true,
      positionMs: 1_000, nowMs: 0, timeoutMs: 5_000))
    XCTAssertNil(probe.observe(enabled: true, framePublished: false,
      positionMs: 5_000, nowMs: 4_000, timeoutMs: 5_000))
    let gap = try XCTUnwrap(probe.observe(enabled: true, framePublished: false,
      positionMs: 6_000, nowMs: 5_000, timeoutMs: 5_000))
    XCTAssertEqual(gap.kind, .videoOutputGap)
    XCTAssertEqual(gap.frameGapMs, 5_000)
    XCTAssertEqual(gap.timelineGapMs, 0)
    XCTAssertEqual(gap.positionMs, 6_000)
  }

  func testVideoGapDiagnosticsAreRateLimitedAndShowTimelineStoppingAndRecovery() throws {
    let probe = YlAvPlayerVideoProgressProbe()
    _ = probe.observe(enabled: true, framePublished: true,
      positionMs: 0, nowMs: 0, timeoutMs: 5_000)
    _ = probe.observe(enabled: true, framePublished: false,
      positionMs: 5_000, nowMs: 5_000, timeoutMs: 5_000)
    for now in 5_001..<10_000 {
      XCTAssertNil(probe.observe(enabled: true, framePublished: false,
        positionMs: 5_000, nowMs: Int64(now), timeoutMs: 5_000))
    }
    let stopped = try XCTUnwrap(probe.observe(enabled: true, framePublished: false,
      positionMs: 5_000, nowMs: 10_000, timeoutMs: 5_000))
    XCTAssertEqual(stopped.frameGapMs, 10_000)
    XCTAssertEqual(stopped.timelineGapMs, 5_000)
    let resumed = try XCTUnwrap(probe.observe(enabled: true, framePublished: true,
      positionMs: 6_000, nowMs: 11_000, timeoutMs: 5_000))
    XCTAssertEqual(resumed.kind, .videoOutputResumed)
    XCTAssertEqual(resumed.frameGapMs, 11_000)
    XCTAssertNil(probe.observe(enabled: true, framePublished: true,
      positionMs: 7_000, nowMs: 12_000, timeoutMs: 5_000))
  }

  func testVideoProbeDoesNotCarryPausedSeekOrReplacementTimeIntoTheNextInterval() {
    let probe = YlAvPlayerVideoProgressProbe()
    _ = probe.observe(enabled: true, framePublished: true,
      positionMs: 1_000, nowMs: 0, timeoutMs: 5_000)
    XCTAssertNil(probe.observe(enabled: false, framePublished: false,
      positionMs: 1_000, nowMs: 60_000, timeoutMs: 5_000))
    XCTAssertNil(probe.observe(enabled: true, framePublished: false,
      positionMs: 1_000, nowMs: 61_000, timeoutMs: 5_000))
    probe.reset() // seek, item removal and callback rebinding use this boundary.
    XCTAssertNil(probe.observe(enabled: true, framePublished: false,
      positionMs: 30_000, nowMs: 120_000, timeoutMs: 5_000))
    XCTAssertNil(probe.observe(enabled: true, framePublished: false,
      positionMs: 0, nowMs: 130_000, timeoutMs: 5_000), "Backward timeline starts a new observation")
  }

  func testVideoProbeIgnoresUnknownPositionAndHasAMinimumLoggingInterval() throws {
    let probe = YlAvPlayerVideoProgressProbe()
    XCTAssertNil(probe.observe(enabled: true, framePublished: false,
      positionMs: nil, nowMs: 0, timeoutMs: 0))
    XCTAssertNil(probe.observe(enabled: true, framePublished: false,
      positionMs: 0, nowMs: 60_000, timeoutMs: 0))
    XCTAssertNil(probe.observe(enabled: true, framePublished: false,
      positionMs: 0, nowMs: 64_999, timeoutMs: 0))
    let gap = try XCTUnwrap(probe.observe(enabled: true, framePublished: false,
      positionMs: 0, nowMs: 65_000, timeoutMs: 0))
    XCTAssertEqual(gap.timelineGapMs, 5_000)
  }






  func testDecoderPolicyDefaultsToHardwareOnlyAndAcceptsLegacyInput() {
    XCTAssertEqual(PlayerConfiguration(map: [:]).decoderPolicy, "hardwareOnly")
    XCTAssertEqual(
      PlayerConfiguration(map: ["decoderPolicy": "preferHardware"]).decoderPolicy,
      "preferHardware"
    )
  }






}
