import Foundation

/// Source admission is independent of receiver discovery. Compatible is not
/// physical receiver evidence; compressed stream profiles are checked in remux.
enum YlAirPlayPolicy {
  enum Route { case native, remux, liveRemux, inspect, unsupported }
  static func route(format: String, network: Bool, live: Bool, headers: Bool,
                    drm: Bool, strict: Bool) -> Route {
    guard !drm, !strict else { return .unsupported }
    if format == "automatic" { return .inspect }
    if network && !headers && ["hls", "mp4", "mov"].contains(format) { return .native }
    if network && live && format == "flv" { return .liveRemux }
    guard !live, ["automatic", "mp4", "mov", "matroska", "flv", "mpegTs", "mpegPs", "avi"].contains(format) else {
      return .unsupported
    }
    return .remux
  }
  static func resumeAfterInterruption(enabled: Bool, backgroundAudio: Bool,
                                      previousRoute: String?, currentRoute: String?) -> Bool {
    enabled && backgroundAudio && previousRoute != nil && previousRoute == currentRoute
  }
  static func keepInBackground(enabled: Bool, active: Bool, backgroundAudio: Bool) -> Bool {
    enabled && active && backgroundAudio
  }
}
