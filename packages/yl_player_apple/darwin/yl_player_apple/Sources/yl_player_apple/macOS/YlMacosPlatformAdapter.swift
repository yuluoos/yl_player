#if os(macOS)
import AppKit
import FlutterMacOS
import AVFoundation
import CoreVideo
enum YlMacosPlatformAdapter {
  static func makeServices(textures: FlutterTextureRegistry, textureId: Int64? = nil,
    displayView: NSView? = nil, activateAudioSession: (() throws -> Void)? = nil) -> YlPlatformServices {
    YlPlatformServices(platform: .macos,
      textureOutput: YlMacosTextureOutput(textures: textures, textureId: textureId),
      makeDisplayDriver: { [weak displayView] tick in YlDisplayTimer(view: displayView, onTick: tick) },
      activateAudioSession: activateAudioSession ?? {})
  }
}

#endif
