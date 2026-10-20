import Foundation
import yl_player_media_core

/// Stateless factory, shared by standalone owners and the optional AirPlay hook.
public final class YlMediaDeliveryEngine: YlMediaDeliveryService {
  public init() {}
  public func prepare(input: YlMediaDeliveryInput, token: YlOpenCancellationToken) throws -> YlDeliveredMedia {
    try input.isLive
      ? YlAirPlayLiveRemux.prepare(input: input, token: token)
      : YlAirPlayRemux.prepare(input: input, token: token)
  }
  public func makeSession() -> any YlMediaDeliverySession { YlMediaDeliveryManager() }
}
