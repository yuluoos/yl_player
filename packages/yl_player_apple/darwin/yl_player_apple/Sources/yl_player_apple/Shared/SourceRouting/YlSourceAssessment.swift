import Foundation

enum YlSourceKind { case file, network, content }
enum YlSourceFormat: String { case automatic, hls, mp4, mov, matroska, webm, mpegTs, mpegPs, flv, avi }
enum YlSourceIntent { case automatic, onDemand, live }
enum YlDecoderPolicy: String { case systemDefault, hardwarePreferred, hardwareRequired }
enum YlBufferGoal: String { case automatic, lowLatency, smoothPlayback, bounded }
enum YlNetworkPolicy { case platformDefault, managed }

struct YlAppleLoadOptions {
  var autoplay = false
  var startPositionMs: Int64? = nil
  var bufferStrategy: YlBufferGoal = .automatic
  var minDurationMs: Int64? = nil
  var maxDurationMs: Int64? = nil
  var maxManagedBytes: Int? = nil
  var videoConstraints = YlAppleVideoConstraints.unconstrained
  var decoderPolicy: YlDecoderPolicy = .systemDefault
}

/// Exact validated public request settings. Task 3 wires their enforcement;
/// legacy configuration clamps must not erase requested guarantees at this boundary.
struct YlAppleNetworkOptions {
  let connectTimeoutMs: Int64
  let readTimeoutMs: Int64
  let maxRetries: Int
  let baseRetryDelayMs: Int64
  let maxRetryDelayMs: Int64
  let maxRedirects: Int
}

/// Native input contains only validated fields; header dictionaries carry HTTP
/// metadata, never dispatch or playback state. Credential history is per Load.
struct YlAppleSourceDescriptor {
  var uri: String
  var kind: YlSourceKind
  var formatHint: YlSourceFormat = .automatic
  var intent: YlSourceIntent = .automatic
  var headers: [String: String] = [:]
  var credentials: [String: String] = [:]
  var networkPolicy: YlNetworkPolicy = .platformDefault
  var networkConfiguration: YlAppleNetworkOptions? = nil
  var loadOptions: YlAppleLoadOptions? = nil
  var loadRequestId: String? = nil
  var credentialContext = YlNetworkCredentialContext()
  var managedRequestIntent = YlManagedRequestIntent()
  var bufferScope: YlManagedBufferScope? = nil
  var boundedPlan: YlBoundedBufferPlan? = nil
  var isLive: Bool { intent == .live }
  var hasHeaders: Bool { !headers.isEmpty || !credentials.isEmpty }
  var url: URL? { URL(string: uri) }
}

enum YlRequirement: String {
  case networkPlatformDefault = "network.platformDefault", networkManaged = "network.managed"
  case bufferAutomatic = "buffer.automatic", bufferLowLatency = "buffer.lowLatency"
  case bufferSmoothPlayback = "buffer.smoothPlayback", bufferBounded = "buffer.bounded"
  case decoderSystemDefault = "decoder.systemDefault", decoderHardwarePreferred = "decoder.hardwarePreferred"
  case decoderHardwareRequired = "decoder.hardwareRequired"
}
enum YlLimitation: String {
  case sourceRequiresInspection = "source.requiresInspection", codecRequiresInspection = "codec.requiresInspection"
  case decoderModeUnknown = "decoder.modeUnknown", bufferOsMemoryExcluded = "buffer.osMemoryExcluded"
  case networkSystemStackOpaque = "network.systemStackOpaque"
}

struct YlSourceAssessment {
  enum Outcome { case compatible, incompatible, requiresInspection }
  let outcome: Outcome
  let candidate: YlAppleSourceRoute?
  let satisfiedRequirements: [YlRequirement]
  let limitations: [YlLimitation]
  let rejection: NativePlayerError?
  var engine: YlNativeEngine? {
    guard let candidate else { return nil }
    switch candidate {
    case .avPlayer, .headeredHls: return .avPlayer
    case .localMatroska, .networkMatroska, .networkFlv: return .managedFallback
    case .inspect, .reject: return nil
    }
  }
}

/// Each production flag stays false until its mechanism and integration proof
/// land. Tests may inject evidence; eligibility is never enforcement by itself.
struct YlRoutingAvailability {
  var managedNetwork = false
  var boundedBuffer = false
  var hardwareEvidence = false
  var inspectedWebM = false
  var inspectedLocalFlv = false
  static let production = YlRoutingAvailability(managedNetwork: true, boundedBuffer: true)
}

struct YlSourceInspection {
  let format: YlSourceFormat
  let demuxerSupported: Bool
  let codecsSupported: Bool
  let hasVideo: Bool
  let hardwareAccelerated: Bool?
}
