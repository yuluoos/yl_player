import AVFoundation
import Foundation
import YlFFmpegBridge

func ylOpusUnsupportedError() -> NativePlayerError {
  NativePlayerError(category: "decoderUnsupported", code: "decoder.audio_opus_unsupported",
    message: "Opus currently requires CELT mode, mapping family 0 and mono or stereo at 48 kHz. Try another audio track.")
}
func ylOpusPacketError() -> NativePlayerError {
  NativePlayerError(category: "decoderFailure", code: "decoder.audio_opus_failed",
    message: "The Opus audio packet or timing is invalid. Try another audio track or a complete media file.")
}

/// Decode preroll to restore codec history, then trim PCM to the presentation
/// target. OpusHead pre-skip is not reapplied here: the demux packet owns trim.
final class YlOpusAudioConverter: YlAudioPacketConverting {
  var bufferScope: YlManagedBufferScope?
  private var decoder: YLFOpusDecoderRef?
  private(set) var pcmFormat: AVAudioFormat?
  private let maximumFrames = 5760

  func configure(stream: YlAudioStreamConfiguration) throws {
    guard stream.codec == .opus, stream.sampleRate == 48000,
          (1...2).contains(stream.channelCount), stream.magicCookie.count == 19,
          stream.magicCookie[stream.magicCookie.startIndex + 9] == stream.channelCount,
          let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
            channels: AVAudioChannelCount(stream.channelCount), interleaved: YlAudioFormatPolicy.usesInterleavedPCM),
          let created = stream.magicCookie.withUnsafeBytes({ bytes in
            ylf_opus_create(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
          }) else { throw ylOpusUnsupportedError() }
    if let decoder { ylf_opus_free(decoder) }
    decoder = created; pcmFormat = format
  }

  func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate {
    // Fixed maximum before decoding, regardless of untrusted packet duration.
    .init(durationUs: 120000, byteCount: maximumFrames * Int(pcmFormat?.channelCount ?? 2) * 4)
  }

  func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer? {
    guard let decoder, let format = pcmFormat, !packet.data.isEmpty,
          packet.data.count <= 65536, packet.ptsUs != Int64.min else { throw ylOpusPacketError() }
    let channelCount = Int(format.channelCount)
    let packetCopy = try bufferScope?.require(category: .compressedPackets, bytes: packet.data.count + 64)
    let scratch = try bufferScope?.require(category: .scheduledAudio, bytes: maximumFrames * channelCount * 4)
    defer { withExtendedLifetime((packetCopy, scratch)) {} }
    var samples = [Float](repeating: 0, count: maximumFrames * channelCount)
    var frames: Int32 = 0, offset: Int32 = 0
    let result = samples.withUnsafeMutableBufferPointer { output in
      packet.data.withUnsafeBytes { input in
        ylf_opus_decode(decoder, input.bindMemory(to: UInt8.self).baseAddress, input.count,
          packet.skipSamples, packet.discardSamples, output.baseAddress, Int32(maximumFrames), &frames, &offset)
      }
    }
    if result == YLFResultAudioConfigurationUnsupported { throw ylOpusUnsupportedError() }
    guard result == 0 else { throw ylOpusPacketError() }
    defer { packet.reservation?.endQueuedTiming() }
    guard frames > 0 else { return nil }
    let shifted = packet.ptsUs.addingReportingOverflow(Int64(offset) * 1_000_000 / 48000)
    guard !shifted.overflow else { throw ylOpusPacketError() }
    var ptsUs = shifted.partialValue
    var startFrame = 0
    if let target = packet.presentationStartUs, target > ptsUs {
      let end = ptsUs.addingReportingOverflow(Int64(frames) * 1_000_000 / 48000)
      guard !end.overflow else { throw ylOpusPacketError() }
      if target >= end.partialValue { return nil }
      // Difference is now bounded by 120 ms, so this multiplication is safe.
      startFrame = Int(((target - ptsUs) * 48000 + 999999) / 1_000_000)
      if startFrame >= Int(frames) { return nil }
      ptsUs += Int64(startFrame) * 1_000_000 / 48000
    }
    let outputFrames = Int(frames) - startFrame
    let bytes = outputFrames * channelCount * 4
    let reservation = try bufferScope?.require(category: .scheduledAudio, bytes: bytes)
    guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(outputFrames)),
          let channels = pcm.floatChannelData else { throw ylOpusPacketError() }
    pcm.frameLength = AVAudioFrameCount(outputFrames)
    for frame in 0..<outputFrames {
      for channel in 0..<channelCount {
        let value = samples[(startFrame + frame) * channelCount + channel]
        if format.isInterleaved { channels[0][frame * channelCount + channel] = value }
        else { channels[channel][frame] = value }
      }
    }
    let duration = Int64(outputFrames) * 1_000_000 / 48000
    guard reservation?.carryTiming(ptsUs: ptsUs, durationUs: duration, from: packet.reservation) ?? true else {
      throw YlManagedBufferLedger.unsupported()
    }
    return .init(reservation: reservation, payload: pcm, ptsUs: ptsUs, durationUs: duration,
      byteCount: bytes, generation: packet.generation)
  }

  func reset() { if let decoder { ylf_opus_reset(decoder) } }
  deinit { if let decoder { ylf_opus_free(decoder) } }
}
