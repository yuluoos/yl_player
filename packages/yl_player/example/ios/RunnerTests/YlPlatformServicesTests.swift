@testable import yl_player_apple
import CoreVideo
import CoreMedia
import AVFoundation
import XCTest
#if os(iOS)
import Flutter
import UIKit
#else
import FlutterMacOS
import AppKit
#endif

final class YlPlatformServicesTests: XCTestCase {
  private final class Registry: NSObject, FlutterTextureRegistry {
    var texture: FlutterTexture?
    var published: [Int64] = []
    var removed: [Int64] = []
    func register(_ texture: FlutterTexture) -> Int64 { self.texture = texture; return 81 }
    func textureFrameAvailable(_ textureId: Int64) { published.append(textureId) }
    func unregisterTexture(_ textureId: Int64) { removed.append(textureId); texture = nil }
  }

  func testTexturePublicationClearAndDisposalRetainOneIdentity() throws {
    let registry = Registry()
    #if os(iOS)
    let output = YlIosTextureOutput(textures: registry)
    #else
    let output = YlMacosTextureOutput(textures: registry)
    #endif
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
    output.publish(try XCTUnwrap(buffer))
    XCTAssertEqual(registry.published, [81])
    XCTAssertNotNil(registry.texture?.copyPixelBuffer()?.takeRetainedValue())
    output.clear()
    XCTAssertNil(registry.texture?.copyPixelBuffer())
    XCTAssertEqual(output.textureId, 81)
    output.dispose()
    output.dispose()
    output.publish(buffer)
    XCTAssertEqual(registry.removed, [81])
    XCTAssertEqual(registry.published, [81])
  }

  func testStopClearsPixelBufferInPlatformOutput() throws {
    let registry = Registry()
    #if os(iOS)
    let services = YlIosPlatformAdapter.makeServices(textures: registry)
    #else
    let services = YlMacosPlatformAdapter.makeServices(textures: registry)
    #endif
    let backend = YlAvPlayerBackend(playerId: 90, services: services,
      configuration: .init(map: ["audioPolicy": "appManaged"]), emit: { _ in })
    defer { backend.dispose(); services.textureOutput.dispose() }
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
    services.textureOutput.publish(try XCTUnwrap(buffer))
    XCTAssertNotNil(registry.texture?.copyPixelBuffer()?.takeRetainedValue())
    backend.stop()
    XCTAssertNil(registry.texture?.copyPixelBuffer()?.takeRetainedValue())
    XCTAssertEqual(services.textureOutput.textureId, 81)
    XCTAssertTrue(registry.removed.isEmpty)
  }

  func testRetiredBackendCannotDisposeOrClearCandidateTexture() throws {
    let registry = Registry()
    #if os(iOS)
    let services = YlIosPlatformAdapter.makeServices(textures: registry)
    #else
    let services = YlMacosPlatformAdapter.makeServices(textures: registry)
    #endif
    defer { services.textureOutput.dispose() }
    let old = YlAvPlayerBackend(playerId: 91, services: services,
      configuration: .init(map: ["audioPolicy": "appManaged"]), emit: { _ in })
    try old.activate()
    old.quiesceForReplacement()
    var candidateFrame: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &candidateFrame), kCVReturnSuccess)
    services.textureOutput.publish(try XCTUnwrap(candidateFrame))
    old.dispose()
    XCTAssertTrue(registry.removed.isEmpty)
    XCTAssertNotNil(registry.texture?.copyPixelBuffer()?.takeRetainedValue())
    XCTAssertEqual(services.textureOutput.textureId, 81)
  }

  private final class NativeSurface: YlTextureOutput, YlNativeVideoSurfaceOutput {
    let textureId: Int64 = 91
    let nativeViewType: String? = "yl_player_apple/video"
    var onRenderFailure: ((NativePlayerError) -> Void)?
    var clears = 0
    func publish(_ pixelBuffer: CVPixelBuffer?) {}
    func resize(width: Int, height: Int) {}
    func clear() { clears += 1 }
    func dispose() {}
  }

  func testNativeSurfaceCapabilityAndErrorAuthoritySurviveLeasing() {
    let output = NativeSurface()
    var failures: [YlAppleSessionIdentity] = []
    let owner = YlAppleTextureOwner(output: output,
      onFailure: { identity, _ in failures.append(identity) }, onFrame: { _ in })
    let a = YlAppleSessionIdentity(sessionId: "a", loadRequestId: "a")
    let b = YlAppleSessionIdentity(sessionId: "b", loadRequestId: "b")
    let old = owner.makeLease(identity: a)
    let next = owner.makeLease(identity: b)
    owner.commit(old)
    owner.commit(next)
    XCTAssertEqual(output.clears, 1, "A native layer must remove the previous session's image")
    old.clear()
    XCTAssertEqual(output.clears, 1)
    let error = NativePlayerError(category: "render", code: "render.video_surface_failed", message: "Test")
    output.onRenderFailure?(error)
    XCTAssertEqual(failures, [b])
    let services = YlPlatformServices(platform: .ios, textureOutput: output,
      makeDisplayDriver: { _ in fatalError("This test does not create a display driver") })
    XCTAssertEqual(services.borrowing(next).nativeViewType, output.nativeViewType)
    owner.stop()
    output.onRenderFailure?(error)
    owner.dispose()
    output.onRenderFailure?(error)
    XCTAssertEqual(failures, [b])
  }

  func testNativeSampleKeepsHDRPrecisionAndDolbyAttachments() throws {
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
      kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let frame = try XCTUnwrap(buffer)
    let rpu = Data([1, 2, 3, 4])
    CVBufferSetAttachment(frame, "DolbyVisionRPUData" as CFString, rpu as CFData, .shouldPropagate)
    CVBufferSetAttachment(frame, kCVImageBufferTransferFunctionKey,
      kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
    let sample = try YlSampleBufferVideoRenderer.makeSample(frame)
    XCTAssertTrue(CMSampleBufferGetImageBuffer(sample) === frame)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))),
      kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
    XCTAssertEqual(CVBufferCopyAttachment(frame, "DolbyVisionRPUData" as CFString, nil) as? Data, rpu)
    let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
    XCTAssertTrue(YlHDRVideoPolicy.isHDR(format))
    let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)) as NSArray
    XCTAssertEqual((attachments[0] as! NSDictionary)[kCMSampleAttachmentKey_DisplayImmediately] as? Bool, true)
  }

  #if os(macOS) && DEBUG && YL_BOUND_AV
  @MainActor
  func testPausedReadbackFreezesActualRendererAndRestoresOriginalClock() async throws {
    guard #available(macOS 14.4, *) else { throw XCTSkip("Native readback requires macOS 14.4") }
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)); view.wantsLayer = true
    let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
    defer { window.close() }
    let renderer = YlSampleBufferVideoRenderer()
    renderer.attach(try XCTUnwrap(view.layer))
    defer { renderer.dispose() }
    let emptyLayer = try XCTUnwrap(view.layer?.sublayers?.first as? AVSampleBufferDisplayLayer)
    XCTAssertThrowsError(try YlBoundDisplayReadback(layer: emptyLayer),
      "Freezing before the first displayed frame can prevent readback after seek")
    XCTAssertNil(emptyLayer.controlTimebase)
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let pixel = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(pixel, []); memset(CVPixelBufferGetBaseAddress(pixel), 120, CVPixelBufferGetDataSize(pixel)); CVPixelBufferUnlockBaseAddress(pixel, [])
    renderer.publish(pixel)
    try await Task.sleep(nanoseconds: 100_000_000)
    let layer = try XCTUnwrap(view.layer?.sublayers?.first as? AVSampleBufferDisplayLayer)
    XCTAssertNil(layer.controlTimebase)
    XCTAssertEqual(CMTimebaseGetEffectiveRate(layer.sampleBufferRenderer.timebase), 1)
    let readback = try YlBoundDisplayReadback(layer: layer)
    defer { readback.restore() }
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(CMTimebaseGetEffectiveRate(layer.sampleBufferRenderer.timebase), 0,
      "A paused player alone does not freeze an immediate display renderer")
    let displayed = try XCTUnwrap(layer.sampleBufferRenderer.displayedPixelBuffer())
    CVPixelBufferLockBaseAddress(displayed, .readOnly)
    XCTAssertEqual(CVPixelBufferGetBaseAddress(displayed)?.assumingMemoryBound(to: UInt8.self)[1], 120)
    CVPixelBufferUnlockBaseAddress(displayed, .readOnly)
    XCTAssertTrue(readback.restore())
    XCTAssertNotNil(layer.controlTimebase, "Keep an explicit host clock: clearing to nil leaves this SDK stopped")
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(CMTimebaseGetEffectiveRate(layer.sampleBufferRenderer.timebase), 1)
    try readback.freeze()
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(CMTimebaseGetEffectiveRate(layer.sampleBufferRenderer.timebase), 0)
    XCTAssertTrue(readback.restore())
    // A pre-existing stopped timebase must survive the same lease by identity.
    var existing: CMTimebase?
    XCTAssertEqual(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(), timebaseOut: &existing), noErr)
    layer.controlTimebase = try XCTUnwrap(existing)
    let second = try YlBoundDisplayReadback(layer: layer)
    XCTAssertTrue(second.restore())
    XCTAssertTrue(layer.controlTimebase === existing)
    XCTAssertEqual(CMTimebaseSetRate(try XCTUnwrap(existing), rate: 1), noErr)
    XCTAssertThrowsError(try second.freeze())
    XCTAssertTrue(layer.controlTimebase === existing)
    XCTAssertEqual(CMTimebaseSetRate(try XCTUnwrap(existing), rate: 0), noErr)
    try second.freeze()
    layer.controlTimebase = nil // Simulate an independent owner replacing the clock.
    XCTAssertFalse(second.restore())
    XCTAssertNil(layer.controlTimebase)
  }

  @MainActor
  func testMissingReadbackLetsPendingPresentationRecoverWithoutAnotherFrame() async throws {
    guard #available(macOS 14.4, *) else { throw XCTSkip("Native readback requires macOS 14.4") }
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)); view.wantsLayer = true
    let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
    defer { window.close() }
    let renderer = YlSampleBufferVideoRenderer(); renderer.attach(try XCTUnwrap(view.layer))
    defer { renderer.dispose() }
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let frame = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(frame, []); memset(CVPixelBufferGetBaseAddress(frame), 83, CVPixelBufferGetDataSize(frame)); CVPixelBufferUnlockBaseAddress(frame, [])
    let layer = try XCTUnwrap(view.layer?.sublayers?.first as? AVSampleBufferDisplayLayer)
    renderer.publish(frame)
    // Capture at the readiness transition, with no fixed pre-freeze settle delay.
    let readyDeadline = Date().addingTimeInterval(2)
    while !layer.isReadyForDisplay && Date() < readyDeadline { try await Task.sleep(nanoseconds: 1_000_000) }
    let readback = try YlBoundDisplayReadback(layer: layer)
    defer { readback.restore() }
    // A flushed/pending presentation deterministically supplies a missing read.
    layer.flushAndRemoveImage()
    XCTAssertNil(try readback.pixelBuffer())
    try await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertEqual(CMTimebaseGetEffectiveRate(layer.sampleBufferRenderer.timebase), 1,
      "An empty snapshot must let pending presentation advance without resuming audio")
    renderer.publish(frame) // One real queued frame; retries must not replace it.
    var displayed: CVPixelBuffer?
    let deadline = Date().addingTimeInterval(2)
    repeat {
      try await Task.sleep(nanoseconds: 20_000_000)
      displayed = try readback.pixelBuffer()
    } while displayed == nil && Date() < deadline
    let actual = try XCTUnwrap(displayed)
    XCTAssertEqual(CMTimebaseGetEffectiveRate(layer.sampleBufferRenderer.timebase), 0)
    CVPixelBufferLockBaseAddress(actual, .readOnly)
    XCTAssertEqual(CVPixelBufferGetBaseAddress(actual)?.assumingMemoryBound(to: UInt8.self)[1], 83)
    CVPixelBufferUnlockBaseAddress(actual, .readOnly)
    XCTAssertTrue(readback.restore())
  }

  @MainActor
  func testAcceptanceWindowRemainsVisibleAcrossSpacesAndRestoresOnlyItsOwner() {
    let window = NSWindow(contentRect: NSRect(x: 80, y: 90, width: 720, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let other = NSWindow(contentRect: NSRect(x: 10, y: 20, width: 100, height: 80),
      styleMask: [.titled], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    defer { window.close(); other.close() }
    let frame = window.frame, behavior = window.collectionBehavior, level = window.level
    let minimum = window.minSize, otherFrame = other.frame
    let lease = YlBoundWindowVisibility(window: window)
    XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
    XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
    XCTAssertEqual(window.level, .floating)
    XCTAssertTrue(window.isVisible)
    XCTAssertEqual(window.contentView?.bounds.size, NSSize(width: 400, height: 260))
    XCTAssertEqual(other.frame, otherFrame)
    XCTAssertEqual(other.level, .normal)
    XCTAssertFalse(other.isVisible)
    lease.restore()
    XCTAssertEqual(window.frame, frame)
    XCTAssertEqual(window.collectionBehavior, behavior)
    XCTAssertEqual(window.level, level)
    XCTAssertEqual(window.minSize, minimum)
    XCTAssertFalse(window.isVisible)
  }
  #endif

  private final class PassiveSession: YlVTSession {
    // This lifetime-only double must satisfy the explicit decoder admission
    // contract. It does not establish hardware support or produce video evidence.
    var hardwareEvidence: YlHardwareDecoderEvidence { .init(mode: .hardware) }
    var usesHardwareDecoder: Bool { true }
    func decode(_ sample: CMSampleBuffer, generation: UInt64,
                reservation: YlVideoDecodeReservation?) -> OSStatus {
      reservation?.release()
      return noErr
    }
    func flush() {}
    func invalidate() {}
  }
  private final class PassiveFactory: YlVTSessionFactory {
    func makeSession(formatDescription: CMVideoFormatDescription,
                     output: @escaping (YlVTDecodedImage) -> Void) throws -> YlVTSession {
      PassiveSession()
    }
  }

  func testRetiredFallbackCannotClearCandidateTexture() throws {
    let registry = Registry()
    #if os(iOS)
    let services = YlIosPlatformAdapter.makeServices(textures: registry)
    #else
    let services = YlMacosPlatformAdapter.makeServices(textures: registry)
    #endif
    defer { services.textureOutput.dispose() }
    let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mkv"))
    let prepared = try YlPreparedFallback(source: YlAppleSourceDescriptor(uri: fixture.absoluteString, kind: .file, formatHint: .matroska), requireHardwareProbe: false)
    let old: YlFallbackBackend
    do {
      old = try YlFallbackBackend(playerId: 92, services: services,
        configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: prepared,
        generation: 1, videoSessionFactory: PassiveFactory(), emit: { _ in })
    } catch let error as NativePlayerError {
      XCTFail("Retirement fixture setup: \(error.category)/\(error.code): \(error.message)")
      throw error
    }
    defer { old.dispose() }
    try old.activate()
    old.quiesceForReplacement()
    var candidateFrame: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &candidateFrame), kCVReturnSuccess)
    services.textureOutput.publish(try XCTUnwrap(candidateFrame))
    old.deactivate()
    old.dispose()
    XCTAssertTrue(registry.removed.isEmpty)
    XCTAssertNotNil(registry.texture?.copyPixelBuffer()?.takeRetainedValue())
    XCTAssertEqual(services.textureOutput.textureId, 81)
  }

  func testLifecycleStartIsIdempotentAndStopRemovesObservers() {
    let center = NotificationCenter()
    #if os(iOS)
    let driver = YlIosLifecycle(center: center)
    let suspend = UIApplication.didEnterBackgroundNotification
    let resume = UIApplication.willEnterForegroundNotification
    #else
    let driver = YlMacosLifecycle(center: center)
    let suspend = NSApplication.didResignActiveNotification
    let resume = NSApplication.didBecomeActiveNotification
    #endif
    var calls: [String] = []
    driver.onSuspend = { calls.append("suspend") }
    driver.onResume = { calls.append("resume") }
    driver.start()
    driver.start()
    center.post(name: suspend, object: nil)
    center.post(name: resume, object: nil)
    XCTAssertEqual(calls, ["suspend", "resume"])
    driver.stop()
    center.post(name: suspend, object: nil)
    XCTAssertEqual(calls, ["suspend", "resume"])
  }
}
