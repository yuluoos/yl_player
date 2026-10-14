import AVFoundation

/// Clips decoded PCM in sample units while keeping the original allocation's
/// reservation. Fractional boundaries never synthesize or stretch audio frames.
enum YlDashPCMClipper {
  static func clip(_ buffer: YlScheduledAudioBuffer, pts: YlDashProgramTime,
                   window: YlDashProgramTimeline.Window) throws -> YlScheduledAudioBuffer? {
    guard let pcm = buffer.payload as? AVAudioPCMBuffer,
          pcm.format.sampleRate.isFinite, pcm.format.sampleRate.rounded() == pcm.format.sampleRate,
          pcm.format.sampleRate > 0, pcm.format.sampleRate <= 768_000 else { throw invalid() }
    let rate = Int64(pcm.format.sampleRate)
    let frames = try YlDashSampleWindow.pcmFrames(pts: pts, sampleRate: rate,
      count: Int(pcm.frameLength), window: window)
    guard frames.count > 0 else { return nil }
    let list = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
    for channel in list {
      let stride = Int(pcm.format.streamDescription.pointee.mBytesPerFrame)
      guard let bytes = channel.mData, stride > 0,
            Int(channel.mDataByteSize) >= Int(pcm.frameLength) * stride else { throw invalid() }
      memmove(bytes, bytes.advanced(by: frames.skip * stride), frames.count * stride)
    }
    pcm.frameLength = AVAudioFrameCount(frames.count)
    let start = try pts.adding(YlDashProgramTime(Int64(frames.skip), rate))
    let duration = try YlDashProgramTime(Int64(frames.count), rate)
    return try .init(reservation: buffer.reservation, payload: pcm,
      ptsUs: start.converted(to: 1_000_000, rounding: .floor),
      durationUs: duration.converted(to: 1_000_000, rounding: .floor),
      byteCount: buffer.byteCount, generation: buffer.generation)
  }
  private static func invalid() -> NativePlayerError {
    NativePlayerError(category: "decoder", code: "decoder.dash_audio_invalid",
      message: "The DASH audio decoder did not produce bounded PCM samples.")
  }
}
