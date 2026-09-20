#if os(macOS)
import AppKit
import AVFoundation
import FlutterMacOS

final class YlMacosVideoViewFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "yl_player_apple/video"
  private let outputs = NSMapTable<NSNumber, YlMacosTextureOutput>(keyOptions: .strongMemory,
    valueOptions: .weakMemory)
  func register(_ output: YlMacosTextureOutput) {
    outputs.setObject(output, forKey: NSNumber(value: output.textureId))
  }
  func unregister(_ identity: Int64) { outputs.removeObject(forKey: NSNumber(value: identity)) }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    let identity = (args as? [String: Any])?["textureId"] as? NSNumber
    let output = identity.flatMap { outputs.object(forKey: $0) }
    return YlMacosVideoView(output: output)
  }
}

private final class YlMacosVideoView: NSView {
  private weak var output: YlMacosTextureOutput?
  override var isFlipped: Bool { true }
  init(output: YlMacosTextureOutput?) {
    self.output = output
    super.init(frame: .zero)
    wantsLayer = true
    layer = CALayer()
    layer?.backgroundColor = NSColor.black.cgColor
    if let layer { output?.attach(layer) }
  }
  required init?(coder: NSCoder) { nil }
  override func layout() { super.layout(); output?.layoutVideoSurface() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  deinit { if let layer { output?.detach(layer) } }
}
#endif
