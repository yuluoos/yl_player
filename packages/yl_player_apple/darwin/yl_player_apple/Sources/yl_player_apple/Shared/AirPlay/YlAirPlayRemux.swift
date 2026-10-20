import Foundation
import yl_player_media_core

typealias YlAirPlayPreparedMedia = YlDeliveredMedia

/// Compatibility projection only; production lives in the optional delivery module.
enum YlAirPlayRemux {
  static let maximumBytes = 512 * 1024 * 1024
  static func failure(_ code: String, _ message: String, diagnostic: String? = nil) -> NativePlayerError {
    NativePlayerError(category: "unsupported", code: "airplay.\(code)", message: message, diagnostic: diagnostic)
  }
}

enum YlAppleDeliveryInput {
  static func make(source: YlAppleSourceDescriptor, configuration: PlayerConfiguration,
                   live: Bool) throws -> YlMediaDeliveryInput {
    guard source.drm == nil, let url = source.url else {
      throw YlAirPlayRemux.failure("unsupported_source", "Unprotected media is required.")
    }
    let recipe: YlFallbackSourceRecipe
    let scope = try source.bufferScope ?? YlManagedBufferLedger().makeScope(maxBytes: nil)
    if live {
      guard source.kind == .network, source.intent != .onDemand else {
        throw YlAirPlayRemux.failure("unsupported_source", "Live network media is required.")
      }
      if ["rtmp", "rtmps"].contains(url.scheme?.lowercased() ?? "") {
        recipe = .rtmp(request: YlRtmpRequestRecipe(address: try YlRtmpAddress.validate(source),
          recovery: source.rtmpRecovery, bufferScope: scope))
      } else {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          source.formatHint == .flv || (source.formatHint == .automatic && url.pathExtension.lowercased() == "flv") else {
          throw YlAirPlayRemux.failure("unsupported_source", "HTTP live delivery requires FLV.")
        }
        recipe = .network(request: request(source, configuration, url, .sequentialLive, scope), container: .flv)
      }
    } else {
      guard !source.isLive, source.formatHint != .hls, source.formatHint != .dash,
        url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
        throw YlAirPlayRemux.failure("unsupported_source", "Finite file or HTTP media is required.")
      }
      let container: YlFallbackContainer
      switch source.formatHint {
      case .flv: container = .flv
      case .mp4, .mov: container = .mp4
      case .avi: container = .avi
      case .mpegTs: container = .mpegTs
      case .mpegPs: container = .mpegPs
      default:
        switch url.pathExtension.lowercased() {
        case "flv": container = .flv
        case "mp4", "mov", "m4v": container = .mp4
        case "avi": container = .avi
        case "ts", "mts", "m2ts": container = .mpegTs
        case "mpg", "mpeg", "vob": container = .mpegPs
        case "m3u8", "mpd": throw YlAirPlayRemux.failure("unsupported_source", "Playlists cannot be remuxed.")
        default: container = .matroska
        }
      }
      recipe = url.isFileURL ? .local(path: url.path, container: container)
        : .network(request: request(source, configuration, url, .randomAccessVOD, scope), container: container)
    }
    return YlMediaDeliveryInput(recipe: recipe, isLive: live)
  }
  private static func request(_ source: YlAppleSourceDescriptor, _ configuration: PlayerConfiguration,
                              _ url: URL, _ mode: YlNetworkInputMode, _ scope: YlManagedBufferScope) -> YlNetworkRequestRecipe {
    YlNetworkRequestRecipe(url: url, headers: source.headers, credentials: source.credentials,
      credentialContext: source.credentialContext,
      configuration: source.networkConfiguration.map(YlNetworkConfiguration.init(options:)) ?? configuration.network,
      mode: mode, managedIntent: source.networkPolicy == .managed ? source.managedRequestIntent : nil, bufferScope: scope)
  }
}
