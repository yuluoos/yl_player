import AVKit
#if os(iOS)
import Flutter
import UIKit
#else
import FlutterMacOS
import AppKit
#endif

/// Uses Apple's visible picker; never enumerates or programmatically selects a
/// private route. A removed/stopped host hides even an already-mounted picker.
final class YlAirPlayRoutePickerFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "yl_player_apple/airplay"
  private let hosts = NSMapTable<NSString, YlApplePlayerHost>(keyOptions: .strongMemory, valueOptions: .weakMemory)
  private var views: [String: NSHashTable<AVRoutePickerView>] = [:]
  func register(suffix: String, host: YlApplePlayerHost?) {
    if let host { hosts.setObject(host, forKey: suffix as NSString) }
    else { hosts.removeObject(forKey: suffix as NSString) }
    refresh(suffix: suffix)
    if host == nil { views.removeValue(forKey: suffix) }
  }
  func refresh(suffix: String) {
    let player = hosts.object(forKey: suffix as NSString)?.airPlayPlayer
    for view in views[suffix]?.allObjects ?? [] {
      view.isHidden = player == nil
      #if os(macOS)
      view.player = player
      #else
      view.isUserInteractionEnabled = player != nil
      #endif
    }
  }
  #if os(iOS)
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
  #else
  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? { FlutterStandardMessageCodec.sharedInstance() }
  #endif
  private func make(frame: CGRect, arguments: Any?) -> AVRoutePickerView {
    let view = AVRoutePickerView(frame: frame)
    #if os(iOS)
    view.prioritizesVideoDevices = true
    #endif
    guard let suffix = (arguments as? [String: Any])?["channelSuffix"] as? String,
      hosts.object(forKey: suffix as NSString) != nil else { view.isHidden = true; return view }
    if views[suffix] == nil { views[suffix] = NSHashTable.weakObjects() }
    views[suffix]?.add(view)
    refresh(suffix: suffix)
    return view
  }
  #if os(iOS)
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    YlAirPlayPlatformView(content: make(frame: frame, arguments: args))
  }
  #else
  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    make(frame: .zero, arguments: args)
  }
  #endif
}
#if os(iOS)
private final class YlAirPlayPlatformView: NSObject, FlutterPlatformView {
  let content: AVRoutePickerView
  init(content: AVRoutePickerView) { self.content = content }
  func view() -> UIView { content }
}
#endif
