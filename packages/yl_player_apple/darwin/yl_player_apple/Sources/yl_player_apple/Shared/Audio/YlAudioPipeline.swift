import yl_player_media_core
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
  func anchorSubmittedAudio(ptsUs: Int64, sampleTime: Int64)
}
extension YlAudioTimeline {
  func anchorSubmittedAudio(ptsUs: Int64, sampleTime: Int64) {
    anchorAudio(ptsUs: ptsUs, sampleTime: sampleTime)
  }
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
    func advanceSilence(through videoPTS: Int64?, atHostTimeUs now: Int64, expectedGeneration: UInt64? = nil) {
      renderer.advanceSilence(through: videoPTS, atHostTimeUs: now, expectedGeneration: expectedGeneration)
    }
    func play() throws { try renderer.play() }
    var scheduledDurationUs: Int64 { renderer.scheduledDurationUs }
    var hasPendingPlayback: Bool { renderer.hasPendingPlayback }
    var scheduledBytes: Int { renderer.scheduledBytes }
    var underrunCount: Int { renderer.underrunCount }
    var renderedAudioTime: YlRenderedAudioTime? { renderer.renderedAudioTime }
    func clockObservation(expectedGeneration: UInt64) -> YlAudioClockObservation {
      renderer.clockObservation(expectedGeneration: expectedGeneration)
    }
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
  private var completionContext: YlAudioCompletionContext?
  weak var output: (any YlAudioPipelineOutput)?
  weak var timeline: (any YlAudioTimeline)?
  // Separate from session lock: native controls may start while that lock is held.
  // Revocation only touches the bounded clock cache, never native output.
  private let clockOwnerLock = NSLock()
  private weak var clockOwner: YlAudioRenderer?
  private var audioRenderer: YlAudioRenderer! {
    didSet {
      clockOwnerLock.withLock {
        clockOwner = audioRenderer
        beforeClockControl?()
      }
    }
  }
  private(set) var audioGeneration: UInt64
  private var desiredVolume: Float = 1
  private var desiredRate: Float = 1
  private var audioAnchored = false
  var beforeClockControl: (() -> Void)?
  var onClockGenerationChanged: ((UInt64) -> Void)?
  var beforeOutput: () throws -> Void = {}
  func prepareForPlayback() throws { try beforeOutput() }
  private var pendingAudioPacket: YlCompressedAudioPacket?

  private var currentAudioRenderer: YlAudioRenderer? { lock.withLock { audioRenderer } }

  init(bufferBudget: YlFallbackBufferBudget, lock: NSLock, generation: UInt64,
       factory: any YlAudioRendererMaking = YlPlatformAudioRendererFactory(),
       completionContext: YlAudioCompletionContext? = nil) {
    self.bufferBudget = bufferBudget
    self.lock = lock
    self.factory = factory
    self.completionContext = completionContext
    self.audioGeneration = generation
  }

  private func makeRenderer() -> YlAudioRenderer {
    let renderer = factory.makeRenderer(bufferBudget: bufferBudget)
    if beforeClockControl != nil {
      renderer.onClockControlBegin = { [weak self, weak renderer] in
        guard let self, let renderer else { return }
        self.clockOwnerLock.withLock {
          guard self.clockOwner === renderer else { return }
          self.beforeClockControl?()
        }
      }
    }
    renderer.onOutputFailure = { [weak self, weak renderer] error in
      // Output can fail while a renderer operation or session state lock is held.
      // Publish later, only if this exact renderer still owns installed output.
      DispatchQueue.main.async { [weak self, weak renderer] in
        guard let self, let renderer, self.currentAudioRenderer === renderer else { return }
        self.output?.fail(error)
      }
    }
    renderer.onFirstPCMSubmitted = { [weak self, weak renderer] generation, ptsUs in
      DispatchQueue.main.async { [weak self, weak renderer] in
        guard let self, let renderer else { return }
        self.lock.withLock {
          guard self.audioRenderer === renderer, self.audioGeneration == generation,
                !self.audioAnchored else { return }
          self.audioAnchored = true
          self.timeline?.anchorSubmittedAudio(ptsUs: max(0, ptsUs), sampleTime: ptsUs)
        }
      }
    }
    return renderer
  }

  func updateSourceEligibility(localFiniteSeekable: Bool) {
    guard let context = completionContext else { return }
    completionContext = .init(enabled: context.enabled, platform: context.platform,
      localFiniteSeekable: localFiniteSeekable, hasBoundedPlan: context.hasBoundedPlan,
      codec: context.codec, sampleRate: context.sampleRate, channels: context.channels, rate: desiredRate)
  }

  private func configureCompletion(_ renderer: YlAudioRenderer, stream: YLFStreamInfo) {
    guard let context = completionContext else { return }
    renderer.setCompletionContext(.init(enabled: context.enabled, platform: context.platform,
      localFiniteSeekable: context.localFiniteSeekable, hasBoundedPlan: bufferBudget.boundedPlan != nil || context.hasBoundedPlan,
      codec: YlAudioCodec(bridgeCodec: stream.codec), sampleRate: Double(stream.sample_rate),
      channels: Int(stream.channel_count), rate: desiredRate))
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
    configureCompletion(audioRenderer, stream: stream)
    try audioRenderer.configure(stream: configuration(for: stream, generation: audioGeneration, audioCookies: cookies))
  }
  func discardRenderer() { audioRenderer?.dispose(); audioRenderer = nil }
  func advanceGeneration() { audioGeneration &+= 1; onClockGenerationChanged?(audioGeneration) }
  func adoptGeneration(_ generation: UInt64) { audioGeneration = generation; onClockGenerationChanged?(generation) }
  func nextGeneration() -> UInt64 { audioGeneration &+ 1 }
  func discardPendingPacket() { pendingAudioPacket = nil }
  func resetAnchor() { audioAnchored = false }
  func finishInput() { currentAudioRenderer?.finishInput() }
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
    adoptGeneration(generation)
    return Reset(resource: audioRenderer.map(Resource.init), generation: generation)
  }
  func playInstalled() throws { try audioRenderer.play() }
  func setRate(_ rate: Float, hasAudio: Bool, updateTimeline: () -> Void) {
    desiredRate = rate
    if beforeClockControl == nil { updateTimeline() }
    if hasAudio { currentAudioRenderer?.setRate(rate) }
    if beforeClockControl != nil { updateTimeline() }
  }
  func prepareTrack(stream: YLFStreamInfo, generation: UInt64,
                    cookies: [Int32: Data]) throws -> Resource {
    let candidate = makeRenderer()
    do {
      configureCompletion(candidate, stream: stream)
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
      configureCompletion(renderer, stream: stream)
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
      configureCompletion(renderer, stream: stream)
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
    guard !audioAnchored, currentAudioRenderer?.usesSubmissionAnchor != true else { return }
    audioAnchored = true
    // Renderer time is normalized to media microseconds and starts at the
    // first scheduled PCM, after codec delay and presentation-target trimming.
    // Compressed packet PTS can precede that PCM (or belong to a buffered batch).
    let rendered = currentAudioRenderer?.renderedAudioTime
    timeline?.anchorAudio(
      ptsUs: max(0, rendered?.sampleTime ?? packet.ptsUs),
      sampleTime: rendered?.sampleTime ?? 0
    )
  }

  func configuration(
    for stream: YLFStreamInfo,
    generation: UInt64, audioCookies: [Int32: Data]
  ) -> YlAudioStreamConfiguration {
    YlAudioStreamConfiguration(
      codec: YlAudioCodec(bridgeCodec: stream.codec),
      sampleRate: Double(stream.sample_rate),
      channelCount: Int(stream.channel_count),
      magicCookie: audioCookies[stream.index] ?? Data(),
      generation: generation, channelMask: stream.channel_layout_mask
    )
  }

  func reconnectConfiguration(for stream: YLFStreamInfo, generation: UInt64,
                              copiedAudioCookies: [Int32: Data]) -> YlAudioStreamConfiguration {
    configuration(for: stream, generation: generation, audioCookies: copiedAudioCookies)
  }

  func codecName(_ stream: YLFStreamInfo) -> String {
    YlAudioCodec(bridgeCodec: stream.codec).label
  }

}
