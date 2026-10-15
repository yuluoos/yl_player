import AVFoundation
import Foundation
import YlFFmpegBridge

func ylVorbisUnsupportedError() -> NativePlayerError {
  NativePlayerError(category: "decoderUnsupported", code: "decoder.audio_vorbis_unsupported",
    message: "Vorbis requires valid Vorbis I headers, mono or stereo at 44.1 or 48 kHz, and CodecDelay within 4096 samples. Try another audio track.")
}
func ylVorbisPacketError() -> NativePlayerError {
  NativePlayerError(category: "decoderFailure", code: "decoder.audio_vorbis_failed",
    message: "The Vorbis audio packet or timing is invalid. Try another audio track or a complete media file.")
}

/// Decode preroll to restore codec history, then trim PCM to the presentation
/// target. The decoder owns overlap priming; the container owns tail trim.
final class YlVorbisAudioConverter: YlAudioPacketConverting {
  var bufferScope: YlManagedBufferScope?
  private var decoder: YLFVorbisDecoderRef?
  private(set) var pcmFormat: AVAudioFormat?
  private let maximumFrames = 4096

  func configure(stream: YlAudioStreamConfiguration) throws {
    guard stream.codec == .vorbis, [44100.0, 48000.0].contains(stream.sampleRate),
          (1...2).contains(stream.channelCount), (3...65536).contains(stream.magicCookie.count),
          let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: stream.sampleRate,
            channels: AVAudioChannelCount(stream.channelCount), interleaved: YlAudioFormatPolicy.usesInterleavedPCM),
          let created = stream.magicCookie.withUnsafeBytes({ bytes in
            ylf_vorbis_create(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
              Int32(stream.sampleRate), Int32(stream.channelCount))
          }) else { throw ylVorbisUnsupportedError() }
    if let decoder { ylf_vorbis_free(decoder) }
    decoder = created; pcmFormat = format
  }

  func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate {
    // Fixed maximum before decoding, regardless of untrusted packet duration.
    .init(durationUs: Int64(ceil(Double(maximumFrames) * 1_000_000 / (pcmFormat?.sampleRate ?? 44100))),
      byteCount: maximumFrames * Int(pcmFormat?.channelCount ?? 2) * 4)
  }

  func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer? {
    guard let decoder, let format = pcmFormat, !packet.data.isEmpty,
          packet.data.count <= 65536, packet.skipSamples == 0, packet.ptsUs != Int64.min else { throw ylVorbisPacketError() }
    let channelCount = Int(format.channelCount)
    let packetCopy = try bufferScope?.require(category: .compressedPackets, bytes: packet.data.count + 64)
    let scratch = try bufferScope?.require(category: .scheduledAudio, bytes: maximumFrames * channelCount * 4)
    defer { withExtendedLifetime((packetCopy, scratch)) {} }
    var samples = [Float](repeating: 0, count: maximumFrames * channelCount)
    var frames: Int32 = 0
    let result = samples.withUnsafeMutableBufferPointer { output in
      packet.data.withUnsafeBytes { input in
        ylf_vorbis_decode(decoder, input.bindMemory(to: UInt8.self).baseAddress, input.count,
          packet.skipSamples, packet.discardSamples, output.baseAddress, Int32(maximumFrames), &frames)
      }
    }
    if result == YLFResultAudioConfigurationUnsupported { throw ylVorbisUnsupportedError() }
    guard result == 0 else { throw ylVorbisPacketError() }
    defer { packet.reservation?.endQueuedTiming() }
    guard frames > 0 else { return nil }
    let sampleRate = Int64(format.sampleRate)
    var ptsUs = packet.ptsUs
    var startFrame = 0
    // CodecDelay is already reflected in demux PTS. Decode every priming
    // packet, but never schedule PCM before programme zero, even on first load.
    let target = max(0, packet.presentationStartUs ?? 0)
    if target > ptsUs {
      let end = ptsUs.addingReportingOverflow(Int64(frames) * 1_000_000 / sampleRate)
      guard !end.overflow else { throw ylVorbisPacketError() }
      if target >= end.partialValue { return nil }
      // Difference is now bounded by 93 ms, so this multiplication is safe.
      startFrame = Int(((target - ptsUs) * sampleRate + 999999) / 1_000_000)
      if startFrame >= Int(frames) { return nil }
      ptsUs += Int64(startFrame) * 1_000_000 / sampleRate
    }
    let outputFrames = Int(frames) - startFrame
    let bytes = outputFrames * channelCount * 4
    let reservation = try bufferScope?.require(category: .scheduledAudio, bytes: bytes)
    guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(outputFrames)),
          let channels = pcm.floatChannelData else { throw ylVorbisPacketError() }
    pcm.frameLength = AVAudioFrameCount(outputFrames)
    for frame in 0..<outputFrames {
      for channel in 0..<channelCount {
        let value = samples[(startFrame + frame) * channelCount + channel]
        if format.isInterleaved { channels[0][frame * channelCount + channel] = value }
        else { channels[channel][frame] = value }
      }
    }
    let duration = Int64(outputFrames) * 1_000_000 / sampleRate
    guard reservation?.carryTiming(ptsUs: ptsUs, durationUs: duration, from: packet.reservation) ?? true else {
      throw YlManagedBufferLedger.unsupported()
    }
    return .init(reservation: reservation, payload: pcm, ptsUs: ptsUs, durationUs: duration,
      byteCount: bytes, generation: packet.generation)
  }

  func reset() { if let decoder { ylf_vorbis_reset(decoder) } }
  deinit { if let decoder { ylf_vorbis_free(decoder) } }
}
