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
  /// Opaque ownership handle: disposal/play may intentionally occur after the
  /// session releases its lifecycle lock. Configuration stays inside this owner.
  struct Resource {
    fileprivate let renderer: YlAudioRenderer
    func dispose() { renderer.dispose() }
    func pause() { renderer.pause() }
    func play() throws { try renderer.play() }
    var scheduledDurationUs: Int64 { renderer.scheduledDurationUs }
    var scheduledBytes: Int { renderer.scheduledBytes }
    var underrunCount: Int { renderer.underrunCount }
    var renderedAudioTime: YlRenderedAudioTime? { renderer.renderedAudioTime }
  }
  struct Reset {
    private let resource: Resource?
    private let generation: UInt64
    fileprivate init(resource: Resource?, generation: UInt64) {
      self.resource = resource; self.generation = generation
    }
    func perform() { resource?.renderer.reset(generation: generation) }
  }
  private let lock: NSLock
  private let bufferBudget: YlFallbackBufferBudget
  private let factory: any YlAudioRendererMaking
  weak var output: (any YlAudioPipelineOutput)?
  weak var timeline: (any YlAudioTimeline)?
  private var audioRenderer: YlAudioRenderer!
  private(set) var audioGeneration: UInt64
  private var desiredVolume: Float = 1
  private var desiredRate: Float = 1
  private var audioAnchored = false
  var beforeOutput: () throws -> Void = {}
  func prepareForPlayback() throws { try beforeOutput() }
  private var pendingAudioPacket: YlCompressedAudioPacket?

  private var currentAudioRenderer: YlAudioRenderer? { lock.withLock { audioRenderer } }

  init(bufferBudget: YlFallbackBufferBudget, lock: NSLock, generation: UInt64,
       factory: any YlAudioRendererMaking = YlPlatformAudioRendererFactory()) {
    self.bufferBudget = bufferBudget
    self.lock = lock
    self.factory = factory
    self.audioGeneration = generation
  }

  private func makeRenderer() -> YlAudioRenderer {
    let renderer = factory.makeRenderer(bufferBudget: bufferBudget)
    renderer.onOutputFailure = { [weak self, weak renderer] error in
      // Output can fail while a renderer operation or session state lock is held.
      // Publish later, only if this exact renderer still owns installed output.
      DispatchQueue.main.async { [weak self, weak renderer] in
        guard let self, let renderer, self.currentAudioRenderer === renderer else { return }
        self.output?.fail(error)
      }
    }
    return renderer
  }

  func setVolume(_ volume: Float, hasAudio: Bool) {
      desiredVolume = volume
      if hasAudio {
        currentAudioRenderer?.setVolume(desiredVolume)
      }
  }

  func observeUnderruns(renderer: Resource?) -> Int? { renderer?.underrunCount }

  var hasRenderer: Bool { audioRenderer != nil }
  var hasPendingPacket: Bool { pendingAudioPacket != nil }
  var currentResource: Resource? { currentAudioRenderer.map(Resource.init) }
  func initializeRenderer() { audioRenderer = makeRenderer() }
  func configureInitial(stream: YLFStreamInfo, cookies: [Int32: Data]) throws {
    try audioRenderer.configure(stream: configuration(for: stream, generation: audioGeneration, audioCookies: cookies))
  }
  func discardRenderer() { audioRenderer?.dispose(); audioRenderer = nil }
  func advanceGeneration() { audioGeneration &+= 1 }
  func adoptGeneration(_ generation: UInt64) { audioGeneration = generation }
  func nextGeneration() -> UInt64 { audioGeneration &+ 1 }
  func discardPendingPacket() { pendingAudioPacket = nil }
  func resetAnchor() { audioAnchored = false }
  func detach() -> Resource? {
    let old = audioRenderer
    audioRenderer = nil
    return old.map(Resource.init)
  }
  @discardableResult
  func install(_ resource: Resource?) -> Resource? {
    let old = audioRenderer
    audioRenderer = resource?.renderer
    return old.map(Resource.init)
  }
  func prepareReset(generation: UInt64) -> Reset {
    audioGeneration = generation
    return Reset(resource: audioRenderer.map(Resource.init), generation: generation)
  }
  func playInstalled() throws { try audioRenderer.play() }
  func setRate(_ rate: Float, hasAudio: Bool, updateTimeline: () -> Void) {
    desiredRate = rate
    updateTimeline()
    if hasAudio { currentAudioRenderer?.setRate(rate) }
  }
  func prepareTrack(stream: YLFStreamInfo, generation: UInt64,
                    cookies: [Int32: Data]) throws -> Resource {
    let candidate = makeRenderer()
    do {
      try candidate.configure(stream: configuration(for: stream, generation: generation, audioCookies: cookies))
      candidate.setVolume(desiredVolume)
      candidate.setRate(desiredRate)
    } catch { candidate.dispose(); throw error }
    return Resource(renderer: candidate)
  }
  // Publish ownership before configuration so the session's cross-component
  // failure cleanup can preserve decoder-before-audio disposal ordering.
  func prepareRebuild(stream: YLFStreamInfo?, cookies: [Int32: Data],
                      onCreated: (Resource) -> Void) throws -> Resource {
    let renderer = makeRenderer()
    let resource = Resource(renderer: renderer)
    onCreated(resource)
    if let stream {
      try renderer.configure(stream: configuration(for: stream, generation: audioGeneration, audioCookies: cookies))
      renderer.setVolume(desiredVolume)
      renderer.setRate(desiredRate)
    }
    return resource
  }
  func prepareReconnect(stream: YLFStreamInfo?, generation: UInt64,
                        cookies: [Int32: Data], onCreated: (Resource) -> Void) throws -> Resource {
    let renderer = makeRenderer()
    let resource = Resource(renderer: renderer)
    onCreated(resource)
    if let stream {
      try renderer.configure(stream: reconnectConfiguration(for: stream, generation: generation, copiedAudioCookies: cookies))
      renderer.setVolume(desiredVolume)
      renderer.setRate(desiredRate)
    }
    return resource
  }

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
          diagnostic: YlAppleSafeDiagnostics.diagnostic(error)
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
          diagnostic: YlAppleSafeDiagnostics.diagnostic(error)
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
