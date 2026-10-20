import Foundation
import yl_player_media_core

extension YlNetworkConfiguration {
  init(options: YlAppleNetworkOptions) {
    self.init(connectTimeoutMs: options.connectTimeoutMs, readTimeoutMs: options.readTimeoutMs,
      maxRetries: options.maxRetries, baseRetryDelayMs: options.baseRetryDelayMs,
      maxRetryDelayMs: options.maxRetryDelayMs, maxRedirects: options.maxRedirects)
  }
}

extension YlRtmpAddress {
  static func validate(_ source: YlAppleSourceDescriptor) throws -> YlRtmpAddress {
    let address = try YlRtmpAddress(source.uri)
    let options = source.loadOptions ?? .init()
    guard [.automatic, .flv].contains(source.formatHint) else { throw ylRtmpError("container.unsupported") }
    guard source.kind == .network,
      source.intent != .onDemand, !source.hasHeaders, source.networkPolicy != .managed,
      options.bufferStrategy != .bounded, (options.startPositionMs ?? 0) == 0 else {
      throw ylRtmpError("policy.unsupported")
    }
    return address
  }
}
