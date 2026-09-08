import Foundation

struct PlayerConfiguration {
  let managesAudioSession: Bool
  private(set) var bufferMode: String
  let decoderPolicy: String
  let maxBufferBytes: Int?
  let network: YlNetworkConfiguration
  let positionEventIntervalMs: Int64
  private(set) var preferredForwardBufferDuration: TimeInterval

  /// v1 absent options keep the original player policy; v2 always supplies goals.
  func forLoad(_ source: [String: Any?]) -> Self {
    guard source["loadOptions"] != nil else { return self }
    let goal = stringMap(source["loadOptions"])["bufferStrategy"] as? String
    var result = self
    result.bufferMode = goal == "smoothPlayback" ? "stable" : (goal == "lowLatency" ? "lowLatency" : "automatic")
    result.preferredForwardBufferDuration = result.bufferMode == "stable" ? 30 : (result.bufferMode == "lowLatency" ? 2 : 10)
    return result
  }

  init(map: [String: Any?]) {
    managesAudioSession = map["audioPolicy"] as? String != "appManaged"
    bufferMode = map["bufferMode"] as? String ?? "automatic"
    decoderPolicy = map["decoderPolicy"] as? String ?? "hardwareOnly"
    maxBufferBytes = int64(map["maxBufferBytes"]).map { Int(clamping: max(0, $0)) }
    network = YlNetworkConfiguration(map: stringMap(map["network"]))
    positionEventIntervalMs = min(
      max(int64(map["positionEventIntervalMs"]) ?? 250, 100),
      2_000
    )
    preferredForwardBufferDuration = switch bufferMode {
    case "lowLatency": 2
    case "stable": 30
    default: 10
    }
  }
}
