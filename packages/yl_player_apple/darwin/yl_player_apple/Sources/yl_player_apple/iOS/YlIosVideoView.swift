#if os(iOS)
import AVFoundation
import Flutter
import UIKit

/// Registry lifetime follows the plugin; output lifetime follows the player host.
final class YlIosVideoViewFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "yl_player_apple/video"
  private let outputs = NSMapTable<NSNumber, YlIosTextureOutput>(keyOptions: .strongMemory,
    valueOptions: .weakMemory)

  func register(_ output: YlIosTextureOutput) {
    outputs.setObject(output, forKey: NSNumber(value: output.textureId))
  }
  func unregister(_ identity: Int64) { outputs.removeObject(forKey: NSNumber(value: identity)) }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64,
    arguments args: Any?) -> FlutterPlatformView {
    let identity = (args as? [String: Any])?["textureId"] as? NSNumber
    let output = identity.flatMap { outputs.object(forKey: $0) }
    return YlIosVideoPlatformView(frame: frame, output: output)
  }
}

private final class YlIosVideoUIView: UIView {
  var onLayout: (() -> Void)?
  override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
}

private final class YlIosVideoPlatformView: NSObject, FlutterPlatformView {
  private let content: YlIosVideoUIView
  private weak var output: YlIosTextureOutput?
  init(frame: CGRect, output: YlIosTextureOutput?) {
    content = YlIosVideoUIView(frame: frame)
    self.output = output
    super.init()
    content.isUserInteractionEnabled = false
    content.backgroundColor = .black
    content.onLayout = { [weak output] in output?.layoutVideoSurface() }
    output?.attach(content.layer)
  }
  func view() -> UIView { content }
  deinit { output?.detach(content.layer) }
}
#endif
