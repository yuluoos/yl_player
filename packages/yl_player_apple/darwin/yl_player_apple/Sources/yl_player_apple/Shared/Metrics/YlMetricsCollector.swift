import Foundation

final class YlMetricsCollector {
  static func decoderMode(state: YlNativeState?) -> AppleDecoderMode {
    guard state?.engine == .managedFallback else { return .unknown }
    switch state?.decoderEvidence?.mode {
    case .hardware: return .hardware
    case .software: return .software
    default: return .unknown
    }
  }
  enum Signal {
    case ready(durationMs: Int64?)
    case firstFrame(durationMs: Int64?)
    case playback(String)
    case videoDropped(total: Int)
    case audioUnderruns(total: Int?)
    case reconnect(id: UInt64)
  }
  private let scope: YlManagedBufferScope?
  private let bounded: Bool
  private let clock: () -> Int64
  private let startedAt: Int64
  private let lock = NSLock()
  private var values = YlNativeMetrics()
  private var bufferingSince: Int64?
  private var completedBufferingMs: Int64 = 0
  private var lastReconnect: UInt64?
  private var playbackStarted = false

  init(scope: YlManagedBufferScope? = nil, bounded: Bool = false,
       clock: @escaping () -> Int64 = YlAppleSafeDiagnostics.nowMilliseconds) {
    self.scope = scope; self.bounded = bounded; self.clock = clock; self.startedAt = clock()
  }
  var managedBufferedBytes: Int? { bounded ? scope?.ledger.snapshot.currentBytes : nil }
  var managedBufferedDurationMs: Int64? { bounded ? scope.map { $0.bufferedDurationUs / 1000 } : nil }

  func observe(_ signal: Signal) {
    lock.withLock {
      switch signal {
      case .ready(let duration):
        if values.openDurationMs == nil {
          values.openDurationMs = max(0, duration ?? clock() - startedAt)
          values.rebufferCount = 0; values.rebufferDurationMs = 0
          values.reconnectCount = 0
        }
      case .firstFrame(let duration):
        if values.firstFrameDurationMs == nil { values.firstFrameDurationMs = max(0, duration ?? clock() - startedAt) }
      case .playback(let status):
        guard values.openDurationMs != nil else { return }
        if status == "playing" { playbackStarted = true }
        if status == "buffering" {
          guard playbackStarted else { return }
          if bufferingSince == nil {
            bufferingSince = clock(); values.rebufferCount = (values.rebufferCount ?? 0) + 1
          }
        } else if let start = bufferingSince {
          completedBufferingMs += max(0, clock() - start); bufferingSince = nil
        }
      case .videoDropped(let total): values.droppedVideoFrames = max(values.droppedVideoFrames ?? 0, max(0, total))
      case .audioUnderruns(let total):
        if let total { values.audioUnderruns = max(values.audioUnderruns ?? 0, max(0, total)) }
      case .reconnect(let id):
        guard lastReconnect.map({ id > $0 }) ?? true else { return }
        lastReconnect = id; values.reconnectCount = (values.reconnectCount ?? 0) + 1
      }
    }
  }
  var snapshot: YlNativeMetrics {
    var result = lock.withLock { () -> YlNativeMetrics in
      var copy = values
      if copy.rebufferCount != nil {
        copy.rebufferDurationMs = completedBufferingMs + (bufferingSince.map { max(0, clock() - $0) } ?? 0)
      }
      return copy
    }
    // No second ledger and no payload/generation ownership mutation.
    result.bufferedBytes = managedBufferedBytes
    result.bufferedDurationMs = managedBufferedDurationMs
    return result
  }
}
