import CoreMedia
import FlutterMacOS
import Foundation
import VideoToolbox

enum YlMacosChannelGeneration {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var value: UInt64 = 0

  static func next() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    value &+= 1
    return value
  }
}

enum YlMacosChannel {
  static let deviceCapabilities = capabilities(
    hardwareH264: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
    hardwareHevc: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
  )

  static func capabilities(
    hardwareH264: Bool,
    hardwareHevc: Bool
  ) -> [String: Any] {
    var hardwareVideoCodecs: [String] = []
    if hardwareH264 { hardwareVideoCodecs.append("video/avc") }
    if hardwareHevc { hardwareVideoCodecs.append("video/hevc") }

    return [
      "hardwareVideoCodecs": hardwareVideoCodecs,
      "supportedFormats": [
        "automatic",
        "hls",
        "httpFlv",
        "mp4",
        "mov",
        "matroska",
        "flv",
      ],
      "maxConcurrentVideoDecoders": 1,
    ]
  }

  static func fallbackMetrics(
    openDurationMs: Int64?,
    firstFrameDurationMs: Int64?,
    bufferedDurationMs: Int64,
    bufferedBytes: Int,
    droppedVideoFrames: Int,
    audioUnderruns: Int,
    reconnectCount: Int
  ) -> [String: Any?] {
    [
      "openDurationMs": openDurationMs,
      "firstFrameDurationMs": firstFrameDurationMs,
      "rebufferCount": 0,
      "rebufferDurationMs": 0,
      "bufferedDurationMs": bufferedDurationMs,
      "bufferedBytes": bufferedBytes,
      "droppedVideoFrames": droppedVideoFrames,
      "audioUnderruns": audioUnderruns,
      "reconnectCount": reconnectCount,
    ]
  }

  static func fullState(
    playerId: Int64,
    generation: UInt64,
    state: [String: Any?]
  ) -> [String: Any?] {
    [
      "playerId": playerId,
      "protocolVersion": 1,
      "generation": generation,
      "type": "state",
      "state": state,
    ]
  }

  static func stateDelta(
    playerId: Int64,
    generation: UInt64,
    delta: [String: Any?]
  ) -> [String: Any?] {
    [
      "playerId": playerId,
      "protocolVersion": 1,
      "generation": generation,
      "type": "stateDelta",
      "delta": delta,
    ]
  }
}

struct PlayerConfiguration {
  let bufferMode: String
  let decoderPolicy: String
  let maxBufferBytes: Int?
  let network: YlNetworkConfiguration
  let positionEventIntervalMs: Int64
  let preferredForwardBufferDuration: TimeInterval

  init(map: [String: Any?]) {
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

struct YlNetworkConfiguration: Equatable {
  let connectTimeoutMs: Int64
  let readTimeoutMs: Int64
  let maxRetries: Int
  let baseRetryDelayMs: Int64
  let maxRetryDelayMs: Int64
  let maxRedirects: Int

  init(map: [String: Any?]) {
    connectTimeoutMs = Self.clampedMilliseconds(
      int64(map["connectTimeoutMs"]) ?? 10_000
    )
    readTimeoutMs = Self.clampedMilliseconds(
      int64(map["readTimeoutMs"]) ?? 15_000
    )
    maxRetries = Self.clampedCount(int64(map["maxRetries"]) ?? 3)
    baseRetryDelayMs = Self.clampedMilliseconds(
      int64(map["baseRetryDelayMs"]) ?? 500
    )
    maxRetryDelayMs = Self.clampedMilliseconds(
      int64(map["maxRetryDelayMs"]) ?? 8_000
    )
    maxRedirects = Self.clampedCount(int64(map["maxRedirects"]) ?? 5)
  }

  private static func clampedMilliseconds(_ value: Int64) -> Int64 {
    min(max(value, 0), 60_000)
  }

  private static func clampedCount(_ value: Int64) -> Int {
    Int(min(max(value, 0), 20))
  }
}

struct NativePlayerError: Error {
  let category: String
  let code: String
  let message: String
  var diagnostic: String?

  init(
    category: String,
    code: String,
    message: String,
    diagnostic: String? = nil
  ) {
    self.category = category
    self.code = code
    self.message = message
    self.diagnostic = diagnostic
  }
}

func flutterError(_ error: NativePlayerError) -> FlutterError {
  FlutterError(
    code: error.code,
    message: error.message,
    details: errorMap(
      category: error.category,
      code: error.code,
      message: error.message,
      diagnostic: error.diagnostic
    )
  )
}

func errorMap(
  category: String,
  code: String,
  message: String,
  diagnostic: String? = nil
) -> [String: Any?] {
  [
    "category": category,
    "code": code,
    "message": message,
    "platformDiagnostic": diagnostic,
  ]
}

func stringMap(_ value: Any?) -> [String: Any?] {
  guard let source = value as? [AnyHashable: Any?] else { return [:] }
  return Dictionary(
    uniqueKeysWithValues: source.map { (String(describing: $0.key), $0.value) }
  )
}

func int64(_ value: Any?) -> Int64? {
  if let value = value as? NSNumber { return value.int64Value }
  return value as? Int64
}

func float(_ value: Any?) -> Float? {
  if let value = value as? NSNumber { return value.floatValue }
  return value as? Float
}
