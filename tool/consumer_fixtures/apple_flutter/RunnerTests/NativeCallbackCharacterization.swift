@testable import yl_player_apple

// Fixture-only projection preserves the old engine assertions during the typed
// migration. Production contains no counterpart and never serializes this shape.
extension YlNativeBackendCallback {
  func characterizationMap(playerId: Int64) -> [String: Any?] {
    var result: [String: Any?] = ["playerId": playerId, "generation": generation]
    switch event {
    case .state(let value):
      result["type"] = "state"
      result["state"] = value.characterizationMap
      result["loadRequestId"] = loadRequestId
    case .delta(let value):
      result["type"] = "stateDelta"
      result["delta"] = ["positionMs": value.positionMs,
        "bufferedPositionMs": value.bufferedPositionMs,
        "isAtLiveEdge": value.isAtLiveEdge, "liveOffsetMs": value.liveOffsetMs,
        "metrics": value.metrics.characterizationMap] as [String: Any?]
    case let .firstFrame(width, height):
      result["type"] = "firstFrame"; result["width"] = width; result["height"] = height
    case let .tracksChanged(audio, video):
      result["type"] = "tracksChanged"
      result["audioTracks"] = audio.map(\.characterizationMap)
      result["videoTracks"] = video.map(\.characterizationMap)
    case .engineActivated:
      result["type"] = "fallbackActivated"; result["engine"] = "nativeFallback"
    case .failure(let error):
      result["type"] = "error"; result["error"] = error.characterizationMap
    case let .retry(attempt, delayMs, error):
      result["type"] = "retry"; result["attempt"] = attempt; result["delayMs"] = delayMs
      result["error"] = error.characterizationMap
    }
    return result
  }
}

extension YlNativeState {
  var characterizationMap: [String: Any?] {
    ["status": status, "positionMs": positionMs, "durationMs": durationMs,
     "bufferedPositionMs": bufferedPositionMs, "isLive": isLive,
     "isSeekable": isSeekable, "isAtLiveEdge": isAtLiveEdge,
     "liveOffsetMs": liveOffsetMs, "dvrStartMs": dvrStartMs, "dvrEndMs": dvrEndMs,
     "videoWidth": videoWidth, "videoHeight": videoHeight,
     "engine": engine == .avPlayer ? "avPlayer" : "nativeFallback",
     "isHardwareDecoding": isHardwareDecoding, "decoderName": decoderName,
     "audioTracks": audioTracks.map(\.characterizationMap),
     "videoTracks": videoTracks.map(\.characterizationMap),
     "metrics": metrics.characterizationMap, "error": error?.characterizationMap]
  }
}

extension YlNativeTrack {
  var characterizationMap: [String: Any?] {
    ["id": id, "kind": kind.rawValue, "label": label, "language": language,
     "codec": codec, "width": width, "height": height, "bitrate": bitrate,
     "isSelected": isSelected]
  }
}

extension YlNativeMetrics {
  var characterizationMap: [String: Any?] {
    ["openDurationMs": openDurationMs, "firstFrameDurationMs": firstFrameDurationMs,
     "rebufferCount": rebufferCount, "rebufferDurationMs": rebufferDurationMs,
     "bufferedDurationMs": bufferedDurationMs, "bufferedBytes": bufferedBytes,
     "droppedVideoFrames": droppedVideoFrames, "audioUnderruns": audioUnderruns,
     "reconnectCount": reconnectCount, "liveOffsetMs": liveOffsetMs]
  }
}

extension NativePlayerError {
  var characterizationMap: [String: Any?] {
    ["category": category, "code": code, "message": message, "platformDiagnostic": diagnostic]
  }
}

extension YlNativeState {
  static var characterizationReady: Self {
    Self(status: "ready", positionMs: 0, durationMs: nil,
      bufferedPositionMs: 0, isLive: false, isSeekable: false, isAtLiveEdge: false,
      liveOffsetMs: nil, dvrStartMs: nil, dvrEndMs: nil, videoWidth: nil,
      videoHeight: nil, engine: .avPlayer, isHardwareDecoding: false,
      decoderName: nil, audioTracks: [], videoTracks: [], metrics: .init(), error: nil)
  }
}
