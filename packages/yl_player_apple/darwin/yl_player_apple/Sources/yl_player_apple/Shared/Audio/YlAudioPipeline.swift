import Foundation
import YlFFmpegBridge

protocol YlAudioRendererMaking {
  func makeRenderer(bufferBudget: YlFallbackBufferBudget) -> YlAudioRenderer
}
struct YlPlatformAudioRendererFactory: YlAudioRendererMaking {
  func makeRenderer(bufferBudget: YlFallbackBufferBudget) -> YlAudioRenderer {
    YlAudioRenderer(bufferBudget: bufferBudget)
  }
}
protocol YlAudioTimeline: AnyObject {
  func anchorAudio(ptsUs: Int64, sampleTime: Int64)
}
extension YlMediaClock: YlAudioTimeline {}
protocol YlAudioPipelineOutput: AnyObject {
  func setDemuxPumping(_ value: Bool)
  func requestAudioPump()
  func requestAudioPump(after delay: TimeInterval)
  func fail(_ error: NativePlayerError)
}

/// Retains the configured renderer and any packet waiting for audio capacity.
/// Converter/output behavior remains in the existing protocol-driven renderer.
final class YlAudioPipeline {
  private let lock: NSLock
  private let bufferBudget: YlFallbackBufferBudget
  private let factory: any YlAudioRendererMaking
  weak var output: (any YlAudioPipelineOutput)?
  weak var timeline: (any YlAudioTimeline)?
  var audioRenderer: YlAudioRenderer!
  var audioGeneration: UInt64
  var desiredVolume: Float = 1
  var desiredRate: Float = 1
  var audioAnchored = false
  var pendingAudioPacket: YlCompressedAudioPacket?

  var currentAudioRenderer: YlAudioRenderer? { lock.withLock { audioRenderer } }

  init(bufferBudget: YlFallbackBufferBudget, lock: NSLock, generation: UInt64,
       factory: any YlAudioRendererMaking = YlPlatformAudioRendererFactory()) {
    self.bufferBudget = bufferBudget
    self.lock = lock
    self.factory = factory
    self.audioGeneration = generation
  }

  func makeRenderer() -> YlAudioRenderer { factory.makeRenderer(bufferBudget: bufferBudget) }

  func setVolume(_ volume: Float, hasAudio: Bool) {
      desiredVolume = volume
      if hasAudio {
        currentAudioRenderer?.setVolume(desiredVolume)
      }
  }

  func observeUnderruns(renderer: YlAudioRenderer?) -> Int? { renderer?.underrunCount }

  func retryPending(codecName: String) {
    if let pendingAudioPacket, let output {
      do {
        guard let audioRenderer else {
          output.setDemuxPumping(false)
          return
        }
        let enqueueResult = try audioRenderer.enqueue(packet: pendingAudioPacket)
        if enqueueResult == .scheduled {
          self.pendingAudioPacket = nil
          anchorAudioIfNeeded(pendingAudioPacket)
          output.setDemuxPumping(false)
          output.requestAudioPump()
        } else if enqueueResult == .buffered {
          self.pendingAudioPacket = nil
          output.setDemuxPumping(false)
          output.requestAudioPump()
        } else if enqueueResult == .wouldExceedBytes || enqueueResult == .wouldExceedDuration {
          output.setDemuxPumping(false)
          output.requestAudioPump(after: 0.02)
        } else {
          self.pendingAudioPacket = nil
          output.setDemuxPumping(false)
        }
      } catch let error as NativePlayerError {
        self.pendingAudioPacket = nil
        output.setDemuxPumping(false)
        output.fail(error)
      } catch {
        self.pendingAudioPacket = nil
        output.setDemuxPumping(false)
        output.fail(NativePlayerError(
          category: "decoderFailure",
          code: "decoder.audio_failed",
          message: "\(codecName) audio conversion failed.",
          diagnostic: String(describing: error)
        ))
      }
      return
    }

  }

  /// Nil means the renderer is unavailable and the demux turn must stop.
  func enqueue(_ audioPacket: YlCompressedAudioPacket, codecName: String,
               onBackpressure: (TimeInterval) -> Void) -> Void? {
    guard let output else { return nil }
      do {
        guard let audioRenderer else {
          output.setDemuxPumping(false)
          return nil
        }
        let enqueueResult = try audioRenderer.enqueue(packet: audioPacket)
        if enqueueResult == .wouldExceedBytes || enqueueResult == .wouldExceedDuration {
          pendingAudioPacket = audioPacket
          onBackpressure(0.02)
        } else if enqueueResult == .scheduled {
          anchorAudioIfNeeded(audioPacket)
        }
      } catch let error as NativePlayerError {
        output.fail(error)
      } catch {
        output.fail(NativePlayerError(
          category: "decoderFailure",
          code: "decoder.audio_failed",
          message: "\(codecName) audio conversion failed.",
          diagnostic: String(describing: error)
        ))
      }
    return ()
  }

  func anchorAudioIfNeeded(_ packet: YlCompressedAudioPacket) {
    guard !audioAnchored else { return }
    audioAnchored = true
    timeline?.anchorAudio(
      ptsUs: max(0, packet.ptsUs),
      sampleTime: currentAudioRenderer?.renderedAudioTime?.sampleTime ?? 0
    )
  }

  func configuration(
    for stream: YLFStreamInfo,
    generation: UInt64, audioCookies: [Int32: Data]
  ) -> YlAudioStreamConfiguration {
    YlAudioStreamConfiguration(
      codec: Int(stream.codec) == YLFCodecAAC
        ? .aac : (Int(stream.codec) == YLFCodecMP3 ? .mp3 : .unsupported),
      sampleRate: Double(stream.sample_rate),
      channelCount: Int(stream.channel_count),
      magicCookie: audioCookies[stream.index] ?? Data(),
      generation: generation
    )
  }

  func reconnectConfiguration(for stream: YLFStreamInfo, generation: UInt64,
                              copiedAudioCookies: [Int32: Data]) -> YlAudioStreamConfiguration {
    YlAudioStreamConfiguration(
        codec: Int(stream.codec) == YLFCodecAAC ? .aac : .mp3,
        sampleRate: Double(stream.sample_rate),
        channelCount: Int(stream.channel_count),
        magicCookie: copiedAudioCookies[stream.index] ?? Data(),
        generation: generation
      )
  }

  func codecName(_ stream: YLFStreamInfo) -> String {
    Int(stream.codec) == YLFCodecMP3 ? "MP3" : "AAC"
  }

}
