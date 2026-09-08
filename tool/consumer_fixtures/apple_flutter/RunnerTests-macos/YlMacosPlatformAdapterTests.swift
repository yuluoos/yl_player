@testable import yl_player_apple
import AppKit
import FlutterMacOS
import XCTest

final class YlMacosPlatformAdapterTests: XCTestCase {
  private final class Registry: NSObject, FlutterTextureRegistry {
    func register(_ texture: FlutterTexture) -> Int64 { 93 }
    func textureFrameAvailable(_ textureId: Int64) {}
    func unregisterTexture(_ textureId: Int64) {}
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
