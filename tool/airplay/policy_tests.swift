import Foundation
@main struct AirPlayPolicyTests {
  static func main() {
    func route(_ format: String, network: Bool = true, live: Bool = false,
               headers: Bool = false, drm: Bool = false, strict: Bool = false) -> YlAirPlayPolicy.Route {
      YlAirPlayPolicy.route(format: format, network: network, live: live,
                           headers: headers, drm: drm, strict: strict)
    }
    precondition(route("hls") == .native, "clear HLS must use system external playback")
    precondition(route("mp4") == .native)
    precondition(route("matroska") == .remux)
    precondition(route("mp4", headers: true) == .remux)
    precondition(route("mp4", network: false) == .remux)
    precondition(route("hls", headers: true) == .unsupported)
    precondition(route("dash") == .unsupported)
    precondition(route("webm") == .unsupported)
    precondition(route("automatic", live: true) == .inspect)
    precondition(route("hls", live: true) == .native)
    precondition(route("matroska", live: true) == .unsupported)
    precondition(route("flv", live: true) == .liveRemux)
    precondition(route("flv", live: true, headers: true) == .liveRemux)
    precondition(route("flv", network: false, live: true) == .unsupported)
    precondition(route("flv", live: true, strict: true) == .unsupported)
    precondition(route("flv", live: true, drm: true) == .unsupported)
    precondition(route("flv", live: false) == .remux)
    for format in ["hls", "mp4", "matroska"] {
      precondition(route(format, strict: true) == .unsupported)
      precondition(route(format, drm: true) == .unsupported)
    }
    precondition(YlAirPlayPolicy.keepInBackground(enabled: true, active: true, backgroundAudio: true))
    precondition(!YlAirPlayPolicy.keepInBackground(enabled: true, active: false, backgroundAudio: true))
    precondition(!YlAirPlayPolicy.keepInBackground(enabled: true, active: true, backgroundAudio: false))
    precondition(!YlAirPlayPolicy.keepInBackground(enabled: false, active: true, backgroundAudio: true))
    precondition(YlAirPlayPolicy.resumeAfterInterruption(enabled: true, backgroundAudio: true, previousRoute: "receiver", currentRoute: "receiver"))
    precondition(!YlAirPlayPolicy.resumeAfterInterruption(enabled: true, backgroundAudio: true, previousRoute: "receiver", currentRoute: nil))
    precondition(!YlAirPlayPolicy.resumeAfterInterruption(enabled: true, backgroundAudio: true, previousRoute: "receiver", currentRoute: "different"))
    precondition(!YlAirPlayPolicy.resumeAfterInterruption(enabled: false, backgroundAudio: true, previousRoute: "receiver", currentRoute: "receiver"))
    print("AirPlay source policy and background gates passed")
  }
}
