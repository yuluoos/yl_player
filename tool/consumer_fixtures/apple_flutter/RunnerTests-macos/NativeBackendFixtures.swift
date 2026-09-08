@testable import yl_player_apple
#if os(macOS)
import AppKit
import FlutterMacOS
import AVFoundation
import CoreVideo
extension YlAvPlayerBackend {
  convenience init(playerId: Int64, textures: FlutterTextureRegistry,
    configuration: PlayerConfiguration, displayView: NSView? = nil, player: AVPlayer = AVPlayer(),
    activateAudioSession: (() throws -> Void)? = nil,
    emit: @escaping ([String: Any?]) -> Void) {
    self.init(playerId: playerId,
      services: YlMacosPlatformAdapter.makeServices(textures: textures, displayView: displayView, activateAudioSession: activateAudioSession),
      configuration: configuration, player: player, emit: emit)
  }
}

extension YlFallbackBackend {
  convenience init(playerId: Int64, textureId: Int64, textures: FlutterTextureRegistry,
    configuration: PlayerConfiguration, prepared: YlPreparedFallback,
    qualityConstraint: YlFallbackQualityConstraint = .unconstrained,
    generation: UInt64, videoSessionFactory: YlVTSessionFactory = YlHardwareVTSessionFactory(),
    mediaClock: YlMediaClock? = nil, displayView: NSView? = nil, loadToken: Any? = nil,
    channelIdentity: UInt64? = nil, emit: @escaping ([String: Any?]) -> Void) throws {
    try self.init(playerId: playerId,
      services: YlMacosPlatformAdapter.makeServices(textures: textures, textureId: textureId, displayView: displayView),
      configuration: configuration, prepared: prepared, qualityConstraint: qualityConstraint, generation: generation,
      videoSessionFactory: videoSessionFactory, mediaClock: mediaClock, loadToken: loadToken,
      channelIdentity: channelIdentity, emit: emit)
  }
}
#endif
