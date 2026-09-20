@testable import yl_player_apple
import AppKit
import FlutterMacOS
import XCTest
import AVFoundation

final class YlMacosPlatformAdapterTests: XCTestCase {
  private final class Registry: NSObject, FlutterTextureRegistry {
    var removed: [Int64] = []
    var textureFrames = 0
    func register(_ texture: FlutterTexture) -> Int64 { 93 }
    func textureFrameAvailable(_ textureId: Int64) { textureFrames += 1 }
    func unregisterTexture(_ textureId: Int64) { removed.append(textureId) }
  }

  @MainActor
  func testNativeHDRSurfaceRegistrationLayoutClearAndRetirement() async throws {
    let registry = Registry()
    let factory = YlMacosVideoViewFactory()
    let services = YlMacosPlatformAdapter.makeServices(textures: registry, nativeViews: factory)
    XCTAssertEqual(services.nativeViewType, "yl_player_apple/video")
    let output = try XCTUnwrap(services.textureOutput as? YlMacosTextureOutput)
    var old: NSView? = factory.create(withViewIdentifier: 1, arguments: ["textureId": Int64(93)])
    let oldContainer = try XCTUnwrap(old?.layer)
    let oldLayer = try XCTUnwrap(oldContainer.sublayers?.first)
    var pixel: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
      kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
    output.publish(try XCTUnwrap(pixel))
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    XCTAssertEqual(registry.textureFrames, 0)
    output.clear()
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    XCTAssertNil(oldLayer.superlayer)
    let current = factory.create(withViewIdentifier: 2, arguments: ["textureId": Int64(93)])
    old = nil
    current.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
    current.needsLayout = true
    current.layoutSubtreeIfNeeded()
    XCTAssertEqual(current.layer?.sublayers?.count, 1)
    XCTAssertEqual(current.layer?.sublayers?.first?.frame.size, CGSize(width: 320, height: 180))
    output.dispose()
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    XCTAssertTrue(current.layer?.sublayers?.isEmpty ?? true)
    XCTAssertEqual(registry.removed, [93])
    let stale = factory.create(withViewIdentifier: 3, arguments: ["textureId": Int64(93)])
    XCTAssertTrue(stale.layer?.sublayers?.isEmpty ?? true)
  }

  func testDisplayFactoryDoesNotRetainTheFlutterView() {
    var view: NSView? = NSView()
    weak var observed = view
    let services = YlMacosPlatformAdapter.makeServices(textures: Registry(), displayView: view)
    defer { services.textureOutput.dispose() }
    view = nil
    XCTAssertNil(observed)
    withExtendedLifetime(services) {}
  }
}
