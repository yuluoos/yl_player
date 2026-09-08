import Foundation

struct YlFallbackErrorEvent {
  let playerId: Int64
  let error: [String: Any?]

  var eventMap: [String: Any?] {
    [
      "playerId": playerId,
      "type": "error",
      "error": error,
    ]
  }
}

struct YlFallbackDynamicSnapshot {
  let positionMs: Int64
  let bufferedPositionMs: Int64
  let isAtLiveEdge: Bool
  let liveOffsetMs: Int64?
  let metrics: [String: Any?]

  var deltaMap: [String: Any?] {
    [
      "positionMs": positionMs,
      "bufferedPositionMs": bufferedPositionMs,
      "isAtLiveEdge": isAtLiveEdge,
      "liveOffsetMs": liveOffsetMs,
      "metrics": metrics,
    ]
  }
}

struct YlFallbackStateSnapshot {
  let status: String
  let positionMs: Int64
  let durationMs: Int64?
  let bufferedPositionMs: Int64
  let isLive: Bool
  let isSeekable: Bool
  let isAtLiveEdge: Bool
  let liveOffsetMs: Int64?
  let dvrStartMs: Int64?
  let dvrEndMs: Int64?
  let videoWidth: Int
  let videoHeight: Int
  let engine: String
  let isHardwareDecoding: Bool
  let decoderName: String?
  let audioTracks: [[String: Any?]]
  let videoTracks: [[String: Any?]]
  let capabilities: [String: Any]
  let metrics: [String: Any?]
  let error: [String: Any?]?

  var fullMap: [String: Any?] {
    [
      "status": status,
      "positionMs": positionMs,
      "durationMs": durationMs,
      "bufferedPositionMs": bufferedPositionMs,
      "isLive": isLive,
      "isSeekable": isSeekable,
      "isAtLiveEdge": isAtLiveEdge,
      "liveOffsetMs": liveOffsetMs,
      "dvrStartMs": dvrStartMs,
      "dvrEndMs": dvrEndMs,
      "videoWidth": videoWidth,
      "videoHeight": videoHeight,
      "engine": engine,
      "isHardwareDecoding": isHardwareDecoding,
      "decoderName": decoderName,
      "audioTracks": audioTracks,
      "videoTracks": videoTracks,
      "capabilities": capabilities,
      "metrics": metrics,
      "error": error,
    ]
  }
}
