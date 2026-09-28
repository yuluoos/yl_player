import AVFoundation
#if os(iOS)
import Flutter
import UIKit
#else
import FlutterMacOS
import AppKit
#endif

final class YlFairPlayViewFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "yl_player_apple/protected_video"
  let registry: YlFairPlayViewRegistry
  init(registry: YlFairPlayViewRegistry) { self.registry = registry }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
  private func record(_ args: Any?) -> YlFairPlayViewRecord? {
    guard let values = args as? [String: Any],
      let player = values["playerId"] as? Int64, let surface = values["surfaceId"] as? Int64,
      let session = values["sessionId"] as? String, let generation = values["generation"] as? Int64 else { return nil }
    return registry.lookup(.init(playerId: player, surfaceId: surface, sessionId: session, generation: generation))
  }
  #if os(iOS)
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    YlFairPlayNativeView(frame: frame, viewId: viewId, record: record(args))
  }
  #else
  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    YlFairPlayNativeView(viewId: viewId, record: record(args))
  }
  #endif
}

#if os(iOS)
private final class YlFairPlayNativeView: UIView, FlutterPlatformView {
  let viewId: Int64
  private weak var record: YlFairPlayViewRecord?
  init(frame: CGRect, viewId: Int64, record: YlFairPlayViewRecord?) {
    self.viewId = viewId; super.init(frame: frame)
    backgroundColor = .black; isUserInteractionEnabled = false
    if record?.mount(viewId: viewId, container: layer) == true { self.record = record }
  }
  required init?(coder: NSCoder) { nil }
  func view() -> UIView { self }
  override func layoutSubviews() { super.layoutSubviews(); record?.layout() }
  deinit { record?.detach(viewId: viewId) }
}
#else
private final class YlFairPlayNativeView: NSView {
  let viewId: Int64
  private weak var record: YlFairPlayViewRecord?
  override var isFlipped: Bool { true }
  init(viewId: Int64, record: YlFairPlayViewRecord?) {
    self.viewId = viewId; super.init(frame: .zero)
    wantsLayer = true; layer = CALayer(); layer?.backgroundColor = NSColor.black.cgColor
    if let layer, record?.mount(viewId: viewId, container: layer) == true { self.record = record }
  }
  required init?(coder: NSCoder) { nil }
  override func layout() { super.layout(); record?.layout() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  deinit { record?.detach(viewId: viewId) }
}
#endif
