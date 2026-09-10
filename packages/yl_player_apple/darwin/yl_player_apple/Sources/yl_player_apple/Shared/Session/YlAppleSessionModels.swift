import Foundation

/// Committed Load authority is immutable, including the private request identity.
struct YlAppleSessionIdentity: Equatable {
  let sessionId: String
  let loadRequestId: String
  let startedAtMs: Int64
  init(sessionId: String, loadRequestId: String, startedAtMs: Int64 = 0) {
    self.sessionId = sessionId
    self.loadRequestId = loadRequestId
    self.startedAtMs = startedAtMs
  }
}

enum YlAppleTimeline {
  /// A measurement before the live edge is known zero lag, not missing evidence.
  static func liveOffset(_ measuredMilliseconds: Int64?) -> Int64? {
    measuredMilliseconds.map { max(0, $0) }
  }
}

enum YlNativeEngine { case avPlayer, managedFallback }
enum YlNativeTrackKind: String { case audio, video }

struct YlNativeTrack {
  let id: String
  let kind: YlNativeTrackKind
  var label: String? = nil
  var language: String? = nil
  var codec: String? = nil
  var bitrate: Int? = nil
  var width: Int? = nil
  var height: Int? = nil
  var isSelected: Bool = false
}

struct YlNativeMetrics {
  var openDurationMs: Int64? = nil
  var firstFrameDurationMs: Int64? = nil
  var rebufferCount: Int? = nil
  var rebufferDurationMs: Int64? = nil
  var bufferedDurationMs: Int64? = nil
  var bufferedBytes: Int? = nil
  var droppedVideoFrames: Int? = nil
  var audioUnderruns: Int? = nil
  var reconnectCount: Int? = nil
  var liveOffsetMs: Int64? = nil
}

/// Native measurements only. This value contains neither wire keys nor Pigeon data.
struct YlNativeState {
  var status: String
  var positionMs: Int64
  let durationMs: Int64?
  var bufferedPositionMs: Int64
  let isLive: Bool
  let isSeekable: Bool
  var isAtLiveEdge: Bool
  var liveOffsetMs: Int64?
  let dvrStartMs: Int64?
  let dvrEndMs: Int64?
  let videoWidth: Int?
  let videoHeight: Int?
  let engine: YlNativeEngine
  let isHardwareDecoding: Bool
  let decoderName: String?
  let audioTracks: [YlNativeTrack]
  let videoTracks: [YlNativeTrack]
  var metrics: YlNativeMetrics
  let error: NativePlayerError?
  var decoderEvidence: YlHardwareDecoderEvidence? = nil
}

struct YlNativeTimelineDelta {
  let positionMs: Int64
  let bufferedPositionMs: Int64
  let isAtLiveEdge: Bool
  let liveOffsetMs: Int64?
  var metrics: YlNativeMetrics
}

enum YlNativeBackendEvent {
  case state(YlNativeState)
  case delta(YlNativeTimelineDelta)
  case firstFrame(width: Int?, height: Int?)
  case tracksChanged(audio: [YlNativeTrack], video: [YlNativeTrack])
  case engineActivated(YlNativeEngine)
  case failure(NativePlayerError)
  case retry(attempt: Int, delayMs: Int64, error: NativePlayerError)
}

/// Generation is an internal activity fence, separate from committed session ID.
struct YlNativeBackendCallback {
  let generation: UInt64
  var loadRequestId: String? = nil
  let event: YlNativeBackendEvent
}

/// Closed native compatibility projection. Only validated typed host inputs create it.
struct YlAppleLoadRecipe {
  let source: YlAppleSourceDescriptor
}

struct YlAppleVideoConstraints {
  let maxWidth: Int?
  let maxHeight: Int?
  let maxBitrate: Int?
  static let unconstrained = YlAppleVideoConstraints(maxWidth: nil, maxHeight: nil, maxBitrate: nil)
}

enum YlApplePlaybackCommand {
  case play, pause, liveEdge
  case seek(Int64), speed(Double), volume(Double), track(String)
  case constraints(YlAppleVideoConstraints)

  func apply(to backend: YlPlaybackBackend, cancellationToken: YlOpenCancellationToken? = nil) throws {
    switch self {
    case .play: try backend.play()
    case .pause: try backend.pause()
    case .liveEdge: try backend.seekToLiveEdge()
    case .seek(let position): try backend.seek(toMs: position, cancellationToken: cancellationToken)
    case .speed(let speed): try backend.setPlaybackSpeed(Float(speed))
    case .volume(let volume): try backend.setVolume(Float(volume))
    case .track(let track): try backend.selectAudioTrack(track, cancellationToken: cancellationToken)
    case .constraints(let constraints): try backend.setVideoConstraints(constraints)
    }
  }
}
