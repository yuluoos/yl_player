import yl_player_media_core
import AVFoundation

/// Serial DASH worker adapter. Decode with the existing codec converter, then
/// submit exact PCM or bounded silence through the existing renderer's normal
/// capacity/lifetime contract. One decoded buffer and one output quantum may be
/// pending; gaps never allocate their entire duration or bypass backpressure.
final class YlDashAudioTimeline: YlAudioPacketConverting {
  typealias Time = YlDashProgramTime
  private let decoder: YlDashAudioConverter
  private let window: YlDashProgramTimeline.Window
  private let scope: YlManagedBufferScope
  private var pending: YlDashPCMClipper.Output?
  private var output: YlDashPCMClipper.Output?
  private var nextTime: Time
  private var generation: UInt64 = 0
  var reservesOutputBuffers: Bool { true }
  var pcmFormat: AVAudioFormat? { decoder.pcmFormat }
  var hasPendingOutput: Bool { pending != nil || output != nil }

  init(window: YlDashProgramTimeline.Window, scope: YlManagedBufferScope) {
    self.window = window; self.scope = scope; nextTime = window.start
    decoder = YlDashAudioConverter(window: window, scope: scope)
  }
  func configure(stream: YlAudioStreamConfiguration) throws {
    try decoder.configure(stream: stream); generation = stream.generation
    pending = nil; output = nil; nextTime = window.start
  }
  /// Decode one real compressed packet only when the preceding PCM has been
  /// admitted. Codec-delayed output keeps its own exact timestamp mapping.
  func decode(_ packet: YlCompressedAudioPacket, pts: Time) throws {
    guard !hasPendingOutput, packet.generation == generation else { throw invalid() }
    try decoder.register(pts, forMicroseconds: packet.ptsUs)
    _ = try decoder.convert(packet: packet)
    guard var decoded = decoder.lastOutput else { return }
    if decoded.start < nextTime {
      guard let clipped = try YlDashPCMClipper.timed(decoded.buffer, pts: decoded.start,
        window: .init(start: nextTime, end: window.end)) else { return }
      decoded = clipped
    }
    pending = decoded
  }
  /// The packet is an internal submission token, not compressed media. Its
  /// estimate is the exact staged PCM allocation used by the renderer below.
  func nextSubmission() throws -> YlCompressedAudioPacket? {
    if output == nil, let pending {
      guard let pcm = pending.buffer.payload as? AVAudioPCMBuffer,
            pcm.format.sampleRate.isFinite, pcm.format.sampleRate > 0,
            pcm.format.sampleRate <= 768_000,
            pcm.format.sampleRate.rounded() == pcm.format.sampleRate else { throw invalid() }
      let rate = Int64(pcm.format.sampleRate)
      let gap = try pending.start.subtracting(nextTime).converted(to: rate, rounding: .floor)
      if gap > 0 {
        let frames = Int(min(gap, max(1, rate / 10)))
        let stride = Int(pcm.format.streamDescription.pointee.mBytesPerFrame)
        let channels = pcm.format.isInterleaved ? 1 : Int(pcm.format.channelCount)
        guard stride > 0, channels > 0, frames <= Int.max / stride / channels else { throw invalid() }
        let bytes = frames * stride * channels
        let reservation = try scope.require(category: .scheduledAudio, bytes: bytes)
        guard let silence = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: AVAudioFrameCount(frames)) else { throw invalid() }
        silence.frameLength = AVAudioFrameCount(frames)
        for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
          guard let data = buffer.mData else { throw invalid() }
          memset(data, 0, Int(buffer.mDataByteSize))
        }
        let duration = try Time(Int64(frames), rate)
        output = try .init(buffer: .init(reservation: reservation, payload: silence,
          ptsUs: nextTime.converted(to: 1_000_000, rounding: .floor),
          durationUs: duration.converted(to: 1_000_000, rounding: .floor),
          byteCount: bytes, generation: generation), start: nextTime, end: nextTime.adding(duration))
      } else { output = pending; self.pending = nil }
    }
    guard let output else { return nil }
    return .init(data: Data(), ptsUs: output.buffer.ptsUs,
      durationUs: output.buffer.durationUs, generation: generation)
  }
  func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate {
    .init(durationUs: output?.buffer.durationUs ?? 0, byteCount: output?.buffer.byteCount ?? 0)
  }
  func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer? {
    guard let output, output.buffer.ptsUs == packet.ptsUs, packet.generation == generation else { throw invalid() }
    self.output = nil; nextTime = output.end
    return output.buffer
  }
  func reset() {
    decoder.reset(); pending = nil; output = nil; nextTime = window.start
  }
  private func invalid() -> NativePlayerError {
    NativePlayerError(category: "decoder", code: "decoder.dash_audio_invalid",
      message: "The DASH PCM timeline could not admit a bounded audio window.")
  }
}
