import AVFoundation

/// Adapts the existing codec converter to an exact DASH presentation window.
/// A small timing map follows converter-delayed output instead of assuming each
/// call returns PCM for the packet supplied in that same call.
final class YlDashAudioConverter: YlAudioPacketConverting {
  private let converter: YlAppleCompressedAudioConverter
  private let window: YlDashProgramTimeline.Window
  private var timestamps: [Int64: YlDashProgramTime] = [:]
  private(set) var lastOutput: YlDashPCMClipper.Output?
  var reservesOutputBuffers: Bool { converter.reservesOutputBuffers }
  var pcmFormat: AVAudioFormat? { converter.pcmFormat }
  init(window: YlDashProgramTimeline.Window, scope: YlManagedBufferScope) {
    self.window = window
    converter = YlAppleCompressedAudioConverter(); converter.bufferScope = scope
  }
  /// Call before enqueue, including a backpressure retry. A duplicate timestamp
  /// for the same pending packet does not consume another map entry.
  func register(_ time: YlDashProgramTime, forMicroseconds key: Int64) throws {
    guard timestamps.count < 256 || timestamps[key] != nil else { throw YlManagedBufferLedger.unsupported() }
    timestamps[key] = time
  }
  func configure(stream: YlAudioStreamConfiguration) throws {
    timestamps.removeAll(); try converter.configure(stream: stream)
  }
  func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate {
    converter.estimateOutput(for: packet)
  }
  func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer? {
    lastOutput = nil
    guard let output = try converter.convert(packet: packet) else { return nil }
    guard let pts = timestamps.removeValue(forKey: output.ptsUs) else {
      throw NativePlayerError(category: "decoder", code: "decoder.dash_audio_invalid",
        message: "Decoded DASH audio has no matching source timestamp.")
    }
    lastOutput = try YlDashPCMClipper.timed(output, pts: pts, window: window)
    return lastOutput?.buffer
  }
  func reset() { converter.reset(); timestamps.removeAll(); lastOutput = nil }
}
