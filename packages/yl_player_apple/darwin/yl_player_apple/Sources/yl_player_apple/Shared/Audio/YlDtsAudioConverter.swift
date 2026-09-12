import AVFoundation
import Foundation
import YlFFmpegBridge

/// The bridge applies DTS metadata or a channel-layout stereo matrix, including
/// center and surround channels. Only sample storage conversion happens here.
final class YlDtsAudioConverter: YlAudioPacketConverting {
  var bufferScope: YlManagedBufferScope?
  private var decoder: YLFDtsDecoderRef?
  private var format: AVAudioFormat?
  private let maximumFrames = 8192

  func configure(stream: YlAudioStreamConfiguration) throws {
    guard stream.codec == .dts, stream.sampleRate > 0, stream.sampleRate.isFinite,
          (1...8).contains(stream.channelCount),
          let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: stream.sampleRate, channels: 2,
            interleaved: YlAudioFormatPolicy.usesInterleavedPCM),
          let created = ylf_dts_create() else { throw YlDtsConversionError.invalidConfiguration }
    if let decoder { ylf_dts_free(decoder) }
    decoder = created
    self.format = format
  }

  func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate {
    guard let format else { return .init(durationUs: 0, byteCount: 0) }
    // DTS packets can carry up to 8192 PCM samples. Reserve before advancing the
    // decoder so renderer backpressure never consumes a packet it cannot queue.
    return .init(durationUs: packet.durationUs > 0 ? packet.durationUs
      : Int64((Double(maximumFrames) * 1_000_000 / format.sampleRate).rounded(.up)),
      byteCount: maximumFrames * 2 * MemoryLayout<Float>.size)
  }

  func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer? {
    guard let decoder, let format, !packet.data.isEmpty else { throw YlDtsConversionError.invalidConfiguration }
    let packetCopy = try bufferScope?.require(category: .compressedPackets, bytes: packet.data.count + 64)
    defer { withExtendedLifetime(packetCopy) {} }
    let scratch = try bufferScope?.require(category: .scheduledAudio, bytes: maximumFrames * 8)
    defer { withExtendedLifetime(scratch) {} }
    var samples = [Float](repeating: 0, count: maximumFrames * 2)
    var frames: Int32 = 0
    var sampleRate: Int32 = 0
    let result = samples.withUnsafeMutableBufferPointer { output in
      packet.data.withUnsafeBytes { input in
        ylf_dts_decode(decoder, input.bindMemory(to: UInt8.self).baseAddress, input.count,
          output.baseAddress, Int32(maximumFrames), &frames, &sampleRate)
      }
    }
    guard result == 0, frames > 0, Double(sampleRate) == format.sampleRate else {
      throw YlDtsConversionError.conversionFailed
    }
    let byteCount = Int(frames) * 8
    let reservation = try bufferScope?.require(category: .scheduledAudio, bytes: byteCount)
    guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
          let channels = pcm.floatChannelData else { throw YlDtsConversionError.allocationFailed }
    pcm.frameLength = AVAudioFrameCount(frames)
    if format.isInterleaved {
      samples.withUnsafeBufferPointer { input in
        if let base = input.baseAddress { channels[0].update(from: base, count: Int(frames) * 2) }
      }
    } else {
      for frame in 0..<Int(frames) {
        channels[0][frame] = samples[frame * 2]
        channels[1][frame] = samples[frame * 2 + 1]
      }
    }
    let duration = Int64(Double(frames) * 1_000_000 / format.sampleRate)
    guard reservation?.carryTiming(ptsUs: packet.ptsUs, durationUs: duration, from: packet.reservation) ?? true else {
      throw YlManagedBufferLedger.unsupported()
    }
    packet.reservation?.endQueuedTiming()
    return .init(reservation: reservation, payload: pcm, ptsUs: packet.ptsUs,
      durationUs: duration, byteCount: byteCount, generation: packet.generation)
  }

  func reset() { if let decoder { ylf_dts_reset(decoder) } }
  deinit { if let decoder { ylf_dts_free(decoder) } }
}

private enum YlDtsConversionError: Error { case invalidConfiguration, conversionFailed, allocationFailed }
