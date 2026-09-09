@testable import yl_player_apple
#if os(iOS)
import UIKit
import Flutter
import AVFoundation
import CoreVideo
extension YlAvPlayerBackend {
  convenience init(playerId: Int64, textures: FlutterTextureRegistry,
    configuration: PlayerConfiguration, player: AVPlayer = AVPlayer(),
    activateAudioSession: (() throws -> Void)? = nil,
    emit: @escaping ([String: Any?]) -> Void) {
    self.init(playerId: playerId,
      services: YlIosPlatformAdapter.makeServices(textures: textures, activateAudioSession: activateAudioSession),
      configuration: configuration, player: player, emit: { emit($0.characterizationMap(playerId: playerId)) })
  }
}

extension YlFallbackBackend {
  convenience init(playerId: Int64, textureId: Int64, textures: FlutterTextureRegistry,
    configuration: PlayerConfiguration, prepared: YlPreparedFallback,
    qualityConstraint: YlFallbackQualityConstraint = .unconstrained,
    generation: UInt64, videoSessionFactory: YlVTSessionFactory = YlHardwareVTSessionFactory(),
    mediaClock: YlMediaClock? = nil, loadToken: Any? = nil,
    channelIdentity: UInt64? = nil, emit: @escaping ([String: Any?]) -> Void) throws {
    try self.init(playerId: playerId,
      services: YlIosPlatformAdapter.makeServices(textures: textures, textureId: textureId),
      configuration: configuration, prepared: prepared, qualityConstraint: qualityConstraint, generation: generation,
      videoSessionFactory: videoSessionFactory, mediaClock: mediaClock, loadRequestId: loadToken.map { String(describing: $0) },
      channelIdentity: channelIdentity, emit: { emit($0.characterizationMap(playerId: playerId)) })
  }
}

#endif
