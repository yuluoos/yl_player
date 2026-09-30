import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
#if DEBUG
    YlProtectedViewProbe.register(flutterViewController.registrar(forPlugin: "YlProtectedViewProbe"))
    YlDisplayReadbackProbe.register(flutterViewController.registrar(forPlugin: "YlDisplayReadbackProbe"), window: self)
#endif

    super.awakeFromNib()
  }
}

// Example-only inspection of owned clear SDR fixtures; no screen capture or
// production API. This is a paused display-layer buffer, not compositor timing.
#if DEBUG
import CoreImage
private enum YlDisplayReadbackProbe {
  static func register(_ registrar: FlutterPluginRegistrar, window: NSWindow) {
    let channel = FlutterMethodChannel(name: "yl_player_example/display_readback", binaryMessenger: registrar.messenger)
    let context = CIContext(options: [.cacheIntermediates: false])
    channel.setMethodCallHandler { [weak window] call, reply in
      guard call.method == "snapshot", call.arguments == nil else { reply(FlutterMethodNotImplemented); return }
      // Flutter macOS method handlers execute on the platform main thread.
      guard Thread.isMainThread else {
        reply(FlutterError(code: "probe.thread", message: "Display probe unavailable", details: nil)); return
      }
      var result: [String: Any] = ["status": "noLayer", "layerCount": 0, "ready": false,
        "width": NSNull(), "height": NSNull(), "pixels": NSNull()]
      guard #available(macOS 14.4, *) else { result["status"] = "unsupported"; reply(result); return }
      var visited = Set<ObjectIdentifier>()
      var displays: [AVSampleBufferDisplayLayer] = []
      var exhausted = false
      func visitLayer(_ layer: CALayer) {
        guard visited.insert(ObjectIdentifier(layer)).inserted else { return }
        guard visited.count <= 2048 else { exhausted = true; return }
        if let display = layer as? AVSampleBufferDisplayLayer { displays.append(display) }
        for child in layer.sublayers ?? [] { visitLayer(child) }
      }
      var viewCount = 0
      func visitView(_ view: NSView) {
        viewCount += 1
        guard viewCount <= 512 else { exhausted = true; return }
        if let layer = view.layer { visitLayer(layer) }
        for child in view.subviews { visitView(child) }
      }
      if let view = window?.contentView { visitView(view) }
      result["layerCount"] = displays.count
      guard !exhausted, displays.count <= 1 else { result["status"] = "ambiguous"; reply(result); return }
      guard let display = displays.first else { reply(result); return }
      result["status"] = "noImage"
      result["ready"] = display.isReadyForDisplay
      guard display.isReadyForDisplay,
        let pixelBuffer = display.sampleBufferRenderer.displayedPixelBuffer() else { reply(result); return }
      let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
      guard width == 320, height == 180 else { reply(result); return }
      let image = CIImage(cvPixelBuffer: pixelBuffer)
      var rgba = [UInt8](repeating: 0, count: width * height * 4)
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
      rgba.withUnsafeMutableBytes { bytes in
        context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 4,
          bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: colorSpace)
      }
      var pixels: [Int] = []
      for y in [height / 4, height / 2, height * 3 / 4] {
        for x in [width / 4, width / 2, width * 3 / 4] {
          let index = (y * width + x) * 4
          pixels.append(contentsOf: rgba[index..<index + 3].map(Int.init))
        }
      }
      result["status"] = "observed"; result["width"] = width; result["height"] = height
      result["pixels"] = pixels
      reply(result)
    }
  }
}
#endif

// BEGIN GENERATED PROTECTED VIEW PROBE
// Example Debug-only clear-media feasibility probe, not a DRM implementation.
#if DEBUG
import AVFoundation
#if os(iOS)
import Flutter
import UIKit
#else
import FlutterMacOS
import AppKit
#endif

final class YlProtectedViewProbe: NSObject, FlutterPlatformViewFactory {
  private var players: [Int64: YlProbePlayer] = [:]
  static func register(_ registrar: FlutterPluginRegistrar) {
    let probe = YlProtectedViewProbe()
#if os(iOS)
    let messenger = registrar.messenger()
#else
    let messenger = registrar.messenger
#endif
    let channel = FlutterMethodChannel(name: "yl_player_example/protected_probe", binaryMessenger: messenger)
    registrar.register(probe, withId: "yl_player_example/protected_probe_view")
    channel.setMethodCallHandler { call, reply in probe.handle(call, reply) }
  }
  private func handle(_ call: FlutterMethodCall, _ reply: FlutterResult) {
    if call.method == "reset" {
      players.values.forEach { $0.dispose() }; players.removeAll(); reply(nil); return
    }
    if call.method == "count" { reply(players.count); return }
    guard let args = call.arguments as? [String: Any], let number = args["id"] as? NSNumber else {
      reply(FlutterError(code: "probe.arguments", message: "Invalid probe arguments", details: nil)); return
    }
    let id = number.int64Value
    if call.method == "create" || call.method == "replace" {
      guard let path = args["path"] as? String, path.hasPrefix("/"),
        FileManager.default.fileExists(atPath: path),
        let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber,
        size.int64Value > 0, size.int64Value <= 8 * 1024 * 1024 else {
        reply(FlutterError(code: "probe.arguments", message: "Expected a bounded local clear fixture", details: nil)); return
      }
      if call.method == "create" {
        guard players[id] == nil, players.count < 4 else {
          reply(FlutterError(code: "probe.capacity", message: "Duplicate identity or capacity reached", details: nil)); return
        }
        players[id] = YlProbePlayer(id: id)
      }
      guard let player = players[id] else { missing(reply); return }
      player.replace(URL(fileURLWithPath: path)); reply(nil); return
    }
    guard let player = players[id] else { missing(reply); return }
    switch call.method {
    case "snapshot": reply(player.snapshot())
    case "dispose": player.dispose(); players[id] = nil; reply(nil)
    default: reply(FlutterMethodNotImplemented)
    }
  }
  private func missing(_ reply: FlutterResult) {
    reply(FlutterError(code: "probe.missing", message: "Probe identity is no longer active", details: nil))
  }
#if os(iOS)
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
#else
  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? { FlutterStandardMessageCodec.sharedInstance() }
#endif
  private func content(_ args: Any?) -> YlProbeNativeView {
    let id = ((args as? [String: Any])?["id"] as? NSNumber)?.int64Value
    return YlProbeNativeView(owner: id.flatMap { players[$0] })
  }
#if os(iOS)
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    let view = content(args); view.frame = frame
    return YlProbePlatformView(view)
  }
#else
  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView { content(args) }
#endif
}

private final class YlProbePlayer {
  let id: Int64
  private var epoch = 0
  private var player: AVPlayer?
  private var display = AVPlayerLayer()
  private weak var container: CALayer?
  init(id: Int64) { self.id = id }
  func replace(_ url: URL) {
    epoch += 1
    // A fresh layer/player makes first-frame readiness belong to this epoch.
    player?.pause(); display.player = nil; display.removeFromSuperlayer()
    player?.replaceCurrentItem(with: nil)
    let next = AVPlayer(url: url)
    next.isMuted = true
    next.allowsExternalPlayback = false
    player = next
    display = AVPlayerLayer(player: next)
    display.videoGravity = .resizeAspect
    if let container { container.addSublayer(display); layout() }
    next.play()
  }
  func attach(_ layer: CALayer) {
    display.removeFromSuperlayer(); container = layer; layer.addSublayer(display); layout()
  }
  func detach(_ layer: CALayer) {
    guard container === layer else { return }
    display.removeFromSuperlayer(); container = nil
  }
  func layout() {
    CATransaction.begin(); CATransaction.setDisableActions(true)
    display.frame = container?.bounds ?? .zero
    CATransaction.commit()
  }
  func snapshot() -> [String: Any] {
    let seconds = player?.currentTime().seconds ?? 0
    return ["id": id, "epoch": epoch, "readyEpoch": display.isReadyForDisplay ? epoch : 0,
      "positionMs": seconds.isFinite ? seconds * 1000 : 0,
      "width": display.bounds.width, "height": display.bounds.height,
      "pixelReadback": false, "protectionVerified": false,
      "status": player?.currentItem?.status.rawValue ?? 0]
  }
  func dispose() {
    epoch += 1; player?.pause(); display.player = nil; display.removeFromSuperlayer()
    player?.replaceCurrentItem(with: nil); player = nil; container = nil
  }
  deinit { dispose() }
}
#if os(iOS)
private final class YlProbeNativeView: UIView {
  private weak var owner: YlProbePlayer?
  init(owner: YlProbePlayer?) {
    self.owner = owner; super.init(frame: .zero)
    backgroundColor = .black; isUserInteractionEnabled = false; layer.masksToBounds = true; owner?.attach(layer)
  }
  required init?(coder: NSCoder) { nil }
  override func layoutSubviews() { super.layoutSubviews(); owner?.layout() }
  deinit { owner?.detach(layer) }
}
private final class YlProbePlatformView: NSObject, FlutterPlatformView {
  let content: YlProbeNativeView
  init(_ content: YlProbeNativeView) { self.content = content }
  func view() -> UIView { content }
}
#else
private final class YlProbeNativeView: NSView {
  private weak var owner: YlProbePlayer?
  override var isFlipped: Bool { true }
  init(owner: YlProbePlayer?) {
    self.owner = owner; super.init(frame: .zero)
    wantsLayer = true; layer = CALayer(); layer?.backgroundColor = NSColor.black.cgColor
    layer?.masksToBounds = true
    if let layer { owner?.attach(layer) }
  }
  required init?(coder: NSCoder) { nil }
  override func layout() { super.layout(); owner?.layout() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  deinit { if let layer { owner?.detach(layer) } }
}
#endif
#endif
// END GENERATED PROTECTED VIEW PROBE
