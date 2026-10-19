#if os(iOS)
import UIKit
import Flutter
import AVFoundation
import CoreVideo
enum YlIosPlatformAdapter {
  static func makeServices(textures: FlutterTextureRegistry, textureId: Int64? = nil,
    activateAudioSession: (() throws -> Void)? = nil,
    nativeViews: YlIosVideoViewFactory? = nil) -> YlPlatformServices {
    var services = YlPlatformServices(platform: .ios,
      textureOutput: YlIosTextureOutput(textures: textures, textureId: textureId, nativeViews: nativeViews),
      makeDisplayDriver: { tick in YlIosDisplayDriver(onTick: tick) },
      activateAudioSession: activateAudioSession ?? {})
    services.externalAudioRouteIdentity = {
      let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        .filter { $0.portType == .airPlay || $0.portType == .carAudio }
      return outputs.isEmpty ? nil : outputs.map(\.uid).sorted().joined(separator: "|")
    }
    return services
  }
}

private final class YlIosDisplayDriver: NSObject, YlDisplayDriving {
  private var link: CADisplayLink?
  private let onTick: () -> Void
  init(onTick: @escaping () -> Void) {
    self.onTick = onTick
    super.init()
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 30)
    link.add(to: .main, forMode: .common)
    self.link = link
  }
  var isPaused: Bool {
    get { link?.isPaused ?? true }
    set { link?.isPaused = newValue }
  }
  @objc private func tick() { onTick() }
  func invalidate() { link?.invalidate(); link = nil }
}
#endif
