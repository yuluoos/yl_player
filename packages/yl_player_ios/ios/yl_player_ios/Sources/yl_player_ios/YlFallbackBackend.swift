import AVFoundation
import CoreMedia
import CoreVideo
import Flutter
import QuartzCore
import UIKit
import YlFFmpegBridge

struct YlFallbackLifecycleTransaction {
  let pauseClock: () -> Void
  let advanceGeneration: () -> UInt64
  let stopDemux: () -> Void
  let clearBuffers: (UInt64) -> Void
  let seekDemux: (Int64) throws -> Void
  let resetAudio: (UInt64) throws -> Void
  let recreateVideo: (UInt64) throws -> Void
  let suppressFramesBefore: (Int64) -> Void
  let restartDemux: () throws -> Void

  func seek(toUs targetUs: Int64) throws {
    pauseClock()
    let generation = advanceGeneration()
    stopDemux()
    clearBuffers(generation)
    try seekDemux(targetUs)
    try resetAudio(generation)
    try recreateVideo(generation)
    suppressFramesBefore(targetUs)
    try restartDemux()
  }
}

final class YlPostSeekGate {
  private let lock = NSLock()
  private var minimumVideoPtsUs: Int64?
  private var minimumAudioPtsUs: Int64?

  func reset(targetUs: Int64?) {
    lock.withLock {
      minimumVideoPtsUs = targetUs
      minimumAudioPtsUs = targetUs
    }
  }

  func acceptsVideo(ptsUs: Int64) -> Bool {
    lock.withLock {
      guard let minimumVideoPtsUs else { return true }
      guard ptsUs >= minimumVideoPtsUs else { return false }
      self.minimumVideoPtsUs = nil
      return true
    }
  }

  func acceptsAudio(ptsUs: Int64) -> Bool {
    lock.withLock {
      guard let minimumAudioPtsUs else { return true }
      guard ptsUs >= minimumAudioPtsUs else { return false }
      self.minimumAudioPtsUs = nil
      return true
    }
  }
}

final class YlPreparedFallback {
  let sourceRecipe: YlFallbackSourceRecipe
  let mediaInfo: YLFMediaInfo
  let videoStream: YLFStreamInfo
  let audioStreams: [YLFStreamInfo]
  let videoFormat: CMVideoFormatDescription
  let audioCookies: [Int32: Data]
  private var openedMedia: YlOpenedMedia?

  init(
    source: [String: Any?],
    requireHardwareProbe: Bool = true,
    configuration: PlayerConfiguration = PlayerConfiguration(map: [:]),
    sessionConfiguration: URLSessionConfiguration = .ephemeral
  ) throws {
    guard let uri = source["uri"] as? String,
          let url = URL(string: uri) else {
      throw NativePlayerError(
        category: "source",
        code: "source.invalid_uri",
        message: "A valid Matroska URI is required."
      )
    }
    if url.isFileURL {
      sourceRecipe = .local(path: url.path)
    } else if let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" {
      let headers = stringMap(source["headers"]).compactMapValues { $0 as? String }
      sourceRecipe = .network(request: YlNetworkRequestRecipe(
        url: url,
        headers: headers,
        configuration: configuration.network
      ))
    } else {
      throw NativePlayerError(
        category: "source",
        code: "source.invalid_uri",
        message: "Only file, HTTP, and HTTPS Matroska URIs are supported."
      )
    }
    let budget = try YlFallbackBufferBudget.make(configuration: configuration)
    let opened = try YlOpenedMedia(
      recipe: sourceRecipe,
      networkBufferBytes: budget.networkBytes,
      sessionConfiguration: sessionConfiguration
    )
    mediaInfo = opened.info
    guard let validContext = opened.context else {
      opened.close()
      throw NativePlayerError(
        category: "internal",
        code: "internal.fallback_invariant",
        message: "The opened Matroska context was unavailable."
      )
    }
    var mediaNeedsClose = true
    defer {
      if mediaNeedsClose { opened.close() }
    }

    var selectedVideo: YLFStreamInfo?
    var selectedAudio: [YLFStreamInfo] = []
    var sawUnsupportedAudio = false
    for index in 0..<mediaInfo.stream_count {
      var stream = YLFStreamInfo()
      guard ylf_copy_stream_info(validContext, index, &stream) == 0 else { continue }
      if Int(stream.kind) == YLFStreamVideo,
         (Int(stream.codec) == YLFCodecH264 || Int(stream.codec) == YLFCodecHEVC),
         selectedVideo == nil {
        selectedVideo = stream
      } else if Int(stream.kind) == YLFStreamAudio {
        if Int(stream.codec) == YLFCodecAAC {
          selectedAudio.append(stream)
        } else if Int(stream.codec) != YLFCodecAAC {
          sawUnsupportedAudio = true
        }
      }
    }
    guard let selectedVideo else {
      throw NativePlayerError(
        category: "decoderUnsupported",
        code: "decoder.video_hardware_unavailable",
        message: "The file does not contain supported H.264 or H.265 video."
      )
    }
    if selectedAudio.isEmpty && sawUnsupportedAudio {
      throw NativePlayerError(
        category: "decoderUnsupported",
        code: "decoder.audio_aac_unsupported",
        message: "The selected Matroska audio track is not AAC."
      )
    }
    videoStream = selectedVideo
    audioStreams = selectedAudio
    videoFormat = try YlVideoToolboxDecoder.makeFormatDescription(
      context: validContext,
      streamIndex: selectedVideo.index
    )

    var copiedAudioCookies: [Int32: Data] = [:]
    for audioStream in selectedAudio {
      let size = ylf_stream_codec_config_size(validContext, audioStream.index)
      guard size > 0 else {
        throw NativePlayerError(
          category: "decoderUnsupported",
          code: "decoder.audio_aac_unsupported",
          message: "The AAC codec configuration is missing."
        )
      }
      var bytes = [UInt8](repeating: 0, count: size)
      guard ylf_copy_stream_codec_config(
        validContext,
        audioStream.index,
        &bytes,
        bytes.count
      ) == 0 else {
        throw NativePlayerError(
          category: "decoderUnsupported",
          code: "decoder.audio_aac_unsupported",
          message: "The AAC codec configuration is invalid."
        )
      }
      copiedAudioCookies[audioStream.index] = Data(bytes)
    }
    audioCookies = copiedAudioCookies

    if requireHardwareProbe {
      let probe = try YlVideoToolboxDecoder(
        formatDescription: videoFormat,
        onFrame: { _ in },
        onError: { _ in }
      )
      probe.dispose()
    }
    openedMedia = opened
    mediaNeedsClose = false
  }

  func takeMedia() throws -> YlOpenedMedia {
    guard let openedMedia else {
      throw NativePlayerError(
        category: "internal",
        code: "internal.fallback_invariant",
        message: "The prepared Matroska context was already consumed."
      )
    }
    self.openedMedia = nil
    return openedMedia
  }

  deinit {
    openedMedia?.close()
  }
}

private final class YlFallbackOutputRelay {
  weak var backend: YlFallbackBackend?
  func frame(_ frame: YlVideoFrame) { backend?.receive(frame) }
  func error(_ error: NativePlayerError) { backend?.fail(error) }
}

final class YlFallbackBackend: NSObject, YlPlaybackBackend {
  let playerId: Int64
  var textureId: Int64 = -1
  var isActive: Bool { stateLock.withLock { active } }

  private let textures: FlutterTextureRegistry
  private let configuration: PlayerConfiguration
  private let emit: ([String: Any?]) -> Void
  private let sourceRecipe: YlFallbackSourceRecipe
  private let bufferBudget: YlFallbackBufferBudget
  private let mediaInfo: YLFMediaInfo
  private let videoStream: YLFStreamInfo
  private let audioStreams: [YLFStreamInfo]
  private let audioCookies: [Int32: Data]
  private var videoFormat: CMVideoFormatDescription
  private let worker = DispatchQueue(label: "dev.ylplayer.ios.fallback.demux")
  private let stateLock = NSLock()
  private let frameScheduler = YlFrameScheduler()
  private let postSeekGate = YlPostSeekGate()
  private var audioRenderer: YlAudioRenderer!
  private let outputRelay = YlFallbackOutputRelay()
  private var mediaClock: YlMediaClock!
  private var decoder: YlVideoToolboxDecoder?
  private var openedMedia: YlOpenedMedia?
  private var context: YLFMediaContextRef? { openedMedia?.context }
  private var displayLink: CADisplayLink?
  private var currentPixelBuffer: CVPixelBuffer?
  private var active = false
  private var playing = false
  private var disposed = false
  private var pumping = false
  private var reconfiguring = false
  private var generation: UInt64
  private var audioGeneration: UInt64
  private var selectedAudioStream: YLFStreamInfo?
  private var desiredVolume: Float = 1
  private var desiredRate: Float = 1
  private var savedPositionUs: Int64 = 0
  private var status = "ready"
  private var firstFrameSent = false
  private var prebufferedVideoSample = false
  private var demuxEOF = false
  private var completionSent = false
  private var audioAnchored = false
  private var pendingAudioPacket: YlCompressedAudioPacket?
  private var openStartedAt = CACurrentMediaTime()
  private var openDurationMs: Int64?
  private var firstFrameDurationMs: Int64?
  private var currentError: [String: Any?]?
  private var lastStateEmitAt = CFTimeInterval(0)

  init(
    playerId: Int64,
    textureId: Int64,
    textures: FlutterTextureRegistry,
    configuration: PlayerConfiguration,
    prepared: YlPreparedFallback,
    generation: UInt64,
    emit: @escaping ([String: Any?]) -> Void
  ) throws {
    self.playerId = playerId
    self.textureId = textureId
    self.textures = textures
    self.configuration = configuration
    self.sourceRecipe = prepared.sourceRecipe
    self.bufferBudget = try YlFallbackBufferBudget.make(configuration: configuration)
    self.mediaInfo = prepared.mediaInfo
    self.videoStream = prepared.videoStream
    self.audioStreams = prepared.audioStreams
    self.audioCookies = prepared.audioCookies
    self.selectedAudioStream = prepared.audioStreams.first
    self.videoFormat = prepared.videoFormat
    self.generation = generation
    self.audioGeneration = generation
    self.emit = emit
    self.openedMedia = try prepared.takeMedia()
    super.init()

    audioRenderer = YlAudioRenderer(bufferBudget: bufferBudget)
    mediaClock = YlMediaClock(audioTime: { [weak self] in
      self?.audioRenderer?.renderedAudioTime
    })
    outputRelay.backend = self
    do {
      decoder = try YlVideoToolboxDecoder(
        formatDescription: videoFormat,
        onFrame: { [outputRelay] frame in outputRelay.frame(frame) },
        onError: { [outputRelay] error in outputRelay.error(error) }
      )
      if let audioStream = selectedAudioStream,
         let cookie = audioCookies[audioStream.index] {
        try audioRenderer.configure(stream: YlAudioStreamConfiguration(
          codec: .aac,
          sampleRate: Double(audioStream.sample_rate),
          channelCount: Int(audioStream.channel_count),
          magicCookie: cookie,
          generation: audioGeneration
        ))
      }
    } catch {
      decoder?.dispose()
      decoder = nil
      audioRenderer?.dispose()
      audioRenderer = nil
      openedMedia?.close()
      openedMedia = nil
      throw error
    }
    frameScheduler.flush(generation: generation)
    openDurationMs = Int64((CACurrentMediaTime() - openStartedAt) * 1_000)
    installDisplayLink(paused: true)
  }

  func activate() throws {
    stateLock.lock()
    guard !disposed, !active else {
      stateLock.unlock()
      return
    }
    stateLock.unlock()
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .moviePlayback)
      try session.setActive(true)
    } catch {
      throw NativePlayerError(
        category: "resource",
        code: "ios.audio_session_failed",
        message: "The playback audio session could not be activated.",
        diagnostic: String(describing: error)
      )
    }
    if context == nil || decoder == nil || audioRenderer == nil {
      try rebuildPipeline(positionUs: savedPositionUs)
    }
    if displayLink == nil { installDisplayLink(paused: false) }
    stateLock.withLock {
      active = true
      reconfiguring = false
    }
    displayLink?.isPaused = false
    if playing {
      if selectedAudioStream != nil { try audioRenderer.play() }
      mediaClock.play(atHostTimeUs: Self.hostTimeUs())
      status = "playing"
    }
    emit([
      "playerId": playerId,
      "type": "fallbackActivated",
      "engine": "nativeFallback",
    ])
    emitState()
    requestPump()
  }

  func deactivate() {
    stateLock.lock()
    guard !disposed, active else {
      stateLock.unlock()
      return
    }
    savedPositionUs = mediaClock.position(atHostTimeUs: Self.hostTimeUs())
    active = false
    reconfiguring = true
    generation &+= 1
    audioGeneration &+= 1
    let currentGeneration = generation
    stateLock.unlock()
    displayLink?.invalidate()
    displayLink = nil
    audioRenderer?.pause()
    mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
    worker.sync {
      pendingAudioPacket = nil
      decoder?.dispose()
      decoder = nil
      audioRenderer?.dispose()
      audioRenderer = nil
      openedMedia?.close()
      openedMedia = nil
    }
    frameScheduler.flush(generation: currentGeneration)
    stateLock.withLock {
      currentPixelBuffer = nil
      pumping = false
      demuxEOF = false
      completionSent = false
      prebufferedVideoSample = false
      audioAnchored = false
      reconfiguring = false
    }
    postSeekGate.reset(targetUs: nil)
    mediaClock.seek(to: savedPositionUs)
    status = "paused"
    emitState()
  }

  func command(name: String, arguments: [String: Any?]) throws {
    switch name {
    case "open":
      emitState()
    case "play":
      let wasPlaying = stateLock.withLock { () -> Bool in
        let previous = playing
        playing = true
        return previous
      }
      if !wasPlaying {
        if selectedAudioStream != nil { try audioRenderer?.play() }
        mediaClock.play(atHostTimeUs: Self.hostTimeUs())
      }
      status = "playing"
      emitState()
      requestPump()
    case "pause":
      stateLock.withLock { playing = false }
      if selectedAudioStream != nil { audioRenderer?.pause() }
      mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
      status = "paused"
      emitState()
    case "seekTo":
      try seek(toMs: int64(arguments["positionMs"]) ?? 0)
    case "seekToLiveEdge":
      throw NativePlayerError(
        category: "source",
        code: "source.not_live",
        message: "Local Matroska playback is not live."
      )
    case "setPlaybackSpeed":
      let rate = float(arguments["speed"]) ?? 1
      guard rate >= 0.25, rate <= 4 else {
        throw NativePlayerError(
          category: "source",
          code: "playback.speed_invalid",
          message: "Playback speed must be between 0.25 and 4.0."
        )
      }
      desiredRate = rate
      if selectedAudioStream != nil { audioRenderer?.setRate(rate) }
      mediaClock.setRate(Double(rate), atHostTimeUs: Self.hostTimeUs())
    case "setVolume":
      desiredVolume = float(arguments["volume"]) ?? 1
      if selectedAudioStream != nil {
        audioRenderer?.setVolume(desiredVolume)
      }
    case "selectAudioTrack":
      try selectAudioTrack(arguments["trackId"] as? String)
    case "setQualityConstraint":
      return
    default:
      throw NativePlayerError(
        category: "internal",
        code: "ios.command_unknown",
        message: "Unknown player command: \(name)"
      )
    }
  }

  func emitState() {
    guard !stateLock.withLock({ disposed }) else { return }
    let positionUs = mediaClock.position(atHostTimeUs: Self.hostTimeUs())
    let durationMs = mediaInfo.duration_us > 0 ? mediaInfo.duration_us / 1_000 : nil
    let scheduledAudioDurationUs = audioRenderer?.scheduledDurationUs ?? 0
    let scheduledAudioBytes = audioRenderer?.scheduledBytes ?? 0
    let audioUnderruns = audioRenderer?.underrunCount ?? 0
    emit([
      "playerId": playerId,
      "type": "state",
      "state": [
        "status": status,
        "positionMs": positionUs / 1_000,
        "durationMs": durationMs,
        "bufferedPositionMs": (positionUs + scheduledAudioDurationUs) / 1_000,
        "isLive": false,
        "isSeekable": true,
        "isAtLiveEdge": false,
        "liveOffsetMs": nil,
        "dvrStartMs": nil,
        "dvrEndMs": nil,
        "videoWidth": Int(videoStream.width),
        "videoHeight": Int(videoStream.height),
        "engine": "nativeFallback",
        "isHardwareDecoding": true,
        "decoderName": "VideoToolbox",
        "audioTracks": audioTracks,
        "videoTracks": videoTracks,
        "capabilities": [
          "hardwareVideoCodecs": ["h264", "hevc"],
          "supportedFormats": ["matroska"],
          "maxConcurrentVideoDecoders": 1,
        ],
        "metrics": [
          "openDurationMs": openDurationMs,
          "firstFrameDurationMs": firstFrameDurationMs,
          "rebufferCount": 0,
          "rebufferDurationMs": 0,
          "bufferedDurationMs": scheduledAudioDurationUs / 1_000,
          "bufferedBytes": scheduledAudioBytes,
          "droppedFrames": frameScheduler.lateFrameDropCount,
          "audioUnderruns": audioUnderruns,
        ],
        "error": currentError,
      ],
    ])
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    stateLock.lock()
    let buffer = currentPixelBuffer
    stateLock.unlock()
    return buffer.map(Unmanaged.passRetained)
  }

  func dispose() {
    stateLock.lock()
    guard !disposed else {
      stateLock.unlock()
      return
    }
    disposed = true
    active = false
    playing = false
    reconfiguring = true
    generation &+= 1
    audioGeneration &+= 1
    stateLock.unlock()
    displayLink?.invalidate()
    displayLink = nil
    worker.sync {
      pendingAudioPacket = nil
      decoder?.dispose()
      decoder = nil
      audioRenderer?.dispose()
      audioRenderer = nil
      frameScheduler.dispose()
      openedMedia?.close()
      openedMedia = nil
    }
    stateLock.withLock { currentPixelBuffer = nil }
  }

  fileprivate func receive(_ frame: YlVideoFrame) {
    guard stateLock.withLock({ active && generation == frame.generation }),
          postSeekGate.acceptsVideo(ptsUs: frame.ptsUs) else { return }
    let accepted = frameScheduler.enqueue(YlFrameEnvelope(
      payload: frame.pixelBuffer,
      ptsUs: frame.ptsUs == .min ? 0 : frame.ptsUs,
      durationUs: frame.durationUs,
      keyframe: frame.keyframe,
      generation: frame.generation
    ))
    guard accepted else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.firstFrameSent,
            self.stateLock.withLock({ self.active && self.generation == frame.generation })
      else { return }
      self.present(frame.pixelBuffer)
      self.firstFrameSent = true
      self.firstFrameDurationMs = Int64(
        (CACurrentMediaTime() - self.openStartedAt) * 1_000
      )
      self.emit([
        "playerId": self.playerId,
        "type": "firstFrame",
        "width": Int(self.videoStream.width),
        "height": Int(self.videoStream.height),
      ])
      self.emitState()
    }
  }

  fileprivate func fail(_ error: NativePlayerError) {
    DispatchQueue.main.async { [weak self] in self?.setFailure(error) }
  }

  @objc private func displayLinkTick() {
    let now = Self.hostTimeUs()
    let position = mediaClock.position(atHostTimeUs: now)
    let currentGeneration = stateLock.withLock { generation }
    if let frame = frameScheduler.frame(at: position, generation: currentGeneration) {
      let pixelBuffer = unsafeBitCast(frame.payload, to: CVPixelBuffer.self)
      present(pixelBuffer)
    }
    completeIfDrained(atHostTimeUs: now)
    let wallNow = CACurrentMediaTime()
    if wallNow - lastStateEmitAt >= Double(configuration.positionEventIntervalMs) / 1_000 {
      lastStateEmitAt = wallNow
      emitState()
    }
  }

  private func present(_ pixelBuffer: CVPixelBuffer) {
    stateLock.withLock { currentPixelBuffer = pixelBuffer }
    if textureId >= 0 { textures.textureFrameAvailable(textureId) }
  }

  private func requestPump(after delay: TimeInterval = 0) {
    stateLock.lock()
    guard !disposed, active, !reconfiguring, !pumping, !demuxEOF else {
      stateLock.unlock()
      return
    }
    pumping = true
    stateLock.unlock()
    worker.asyncAfter(deadline: .now() + delay) { [weak self] in self?.pumpOne() }
  }

  private func pumpOne() {
    stateLock.lock()
    let shouldContinue = !disposed && active && (playing || !prebufferedVideoSample)
    let packetGeneration = generation
    if !shouldContinue {
      pumping = false
      stateLock.unlock()
      return
    }
    stateLock.unlock()

    if let pendingAudioPacket {
      do {
        guard let audioRenderer else {
          stateLock.withLock { pumping = false }
          return
        }
        let enqueueResult = try audioRenderer.enqueue(packet: pendingAudioPacket)
        if enqueueResult == .scheduled {
          self.pendingAudioPacket = nil
          anchorAudioIfNeeded(pendingAudioPacket)
          stateLock.withLock { pumping = false }
          requestPump()
        } else if enqueueResult == .wouldExceedBytes || enqueueResult == .wouldExceedDuration {
          stateLock.withLock { pumping = false }
          requestPump(after: 0.02)
        } else {
          self.pendingAudioPacket = nil
          stateLock.withLock { pumping = false }
        }
      } catch let error as NativePlayerError {
        self.pendingAudioPacket = nil
        stateLock.withLock { pumping = false }
        fail(error)
      } catch {
        self.pendingAudioPacket = nil
        stateLock.withLock { pumping = false }
        fail(NativePlayerError(
          category: "decoderFailure",
          code: "decoder.audio_failed",
          message: "AAC audio conversion failed.",
          diagnostic: String(describing: error)
        ))
      }
      return
    }

    var packet: YLFPacketRef?
    let result = ylf_read_packet(context, &packet)
    if result == 1 {
      stateLock.withLock {
        pumping = false
        demuxEOF = true
      }
      decoder?.flush()
      return
    }
    guard result == 0, let ownedPacket = packet else {
      stateLock.withLock { pumping = false }
      ylf_packet_release(&packet)
      fail(NativePlayerError(
        category: "container",
        code: "container.mkv_malformed",
        message: "The Matroska packet stream is malformed.",
        diagnostic: "YlFFmpegBridge result \(result)"
      ))
      return
    }

    do {
      try bufferBudget.validateInFlightPacket(size: ylf_packet_size(ownedPacket))
    } catch let error as NativePlayerError {
      ylf_packet_release(&packet)
      stateLock.withLock { pumping = false }
      fail(error)
      return
    } catch {
      ylf_packet_release(&packet)
      stateLock.withLock { pumping = false }
      return
    }

    let streamIndex = ylf_packet_stream_index(ownedPacket)
    var retryDelay = TimeInterval(0)
    if streamIndex == videoStream.index {
      var unmanagedSample: Unmanaged<CMSampleBuffer>?
      let sampleResult = ylf_create_video_sample_buffer(
        &packet,
        videoFormat,
        &unmanagedSample
      )
      if sampleResult == 0, let unmanagedSample {
        stateLock.withLock { prebufferedVideoSample = true }
        decoder?.decode(
          sample: unmanagedSample.takeRetainedValue(),
          generation: packetGeneration
        )
      } else {
        ylf_packet_release(&packet)
      }
    } else if streamIndex == selectedAudioStream?.index,
              let bytes = ylf_packet_data(ownedPacket) {
      let audioPacket = YlCompressedAudioPacket(
        data: Data(bytes: bytes, count: ylf_packet_size(ownedPacket)),
        ptsUs: ylf_packet_pts_us(ownedPacket),
        durationUs: ylf_packet_duration_us(ownedPacket),
        generation: stateLock.withLock { audioGeneration }
      )
      ylf_packet_release(&packet)
      if !postSeekGate.acceptsAudio(ptsUs: audioPacket.ptsUs) {
        stateLock.withLock { pumping = false }
        requestPump()
        return
      }
      do {
        guard let audioRenderer else {
          stateLock.withLock { pumping = false }
          return
        }
        let enqueueResult = try audioRenderer.enqueue(packet: audioPacket)
        if enqueueResult == .wouldExceedBytes || enqueueResult == .wouldExceedDuration {
          pendingAudioPacket = audioPacket
          retryDelay = 0.02
        } else if enqueueResult == .scheduled {
          anchorAudioIfNeeded(audioPacket)
        }
      } catch let error as NativePlayerError {
        fail(error)
      } catch {
        fail(NativePlayerError(
          category: "decoderFailure",
          code: "decoder.audio_failed",
          message: "AAC audio conversion failed.",
          diagnostic: String(describing: error)
        ))
      }
    } else {
      ylf_packet_release(&packet)
    }

    stateLock.withLock { pumping = false }
    requestPump(after: retryDelay)
  }

  private func seek(toMs positionMs: Int64) throws {
    let targetUs = max(0, positionMs) * 1_000
    guard stateLock.withLock({ active }) else {
      savedPositionUs = targetUs
      mediaClock.seek(to: targetUs)
      emitState()
      return
    }
    let wasPlaying = stateLock.withLock { () -> Bool in
      reconfiguring = true
      pumping = false
      return playing
    }
    status = "buffering"
    emitState()
    let transaction = YlFallbackLifecycleTransaction(
      pauseClock: { [self] in
        audioRenderer?.pause()
        mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
      },
      advanceGeneration: { [self] in
        stateLock.withLock {
          generation &+= 1
          return generation
        }
      },
      stopDemux: { [self] in worker.sync {} },
      clearBuffers: { [self] nextGeneration in
        pendingAudioPacket = nil
        prebufferedVideoSample = false
        demuxEOF = false
        completionSent = false
        audioAnchored = false
        frameScheduler.flush(generation: nextGeneration)
        stateLock.withLock { currentPixelBuffer = nil }
      },
      seekDemux: { [self] targetUs in
        guard let openedMedia else {
          throw NativePlayerError(
            category: "internal",
            code: "internal.fallback_invariant",
            message: "The Matroska media input is unavailable."
          )
        }
        try openedMedia.seek(toMediaTimeUs: targetUs)
      },
      resetAudio: { [self] nextGeneration in
        audioRenderer?.reset(generation: nextGeneration)
        stateLock.withLock { audioGeneration = nextGeneration }
      },
      recreateVideo: { [self] _ in
        let candidate = try makeDecoder()
        let previous = decoder
        decoder = candidate
        previous?.dispose()
      },
      suppressFramesBefore: { [self] targetUs in
        postSeekGate.reset(targetUs: targetUs)
        mediaClock.seek(to: targetUs)
      },
      restartDemux: { [self] in
        stateLock.withLock {
          reconfiguring = false
          playing = wasPlaying
        }
        if wasPlaying {
          if selectedAudioStream != nil { try audioRenderer?.play() }
          mediaClock.play(atHostTimeUs: Self.hostTimeUs())
          status = "playing"
        } else {
          status = "paused"
        }
        requestPump()
      }
    )
    do {
      try transaction.seek(toUs: targetUs)
    } catch {
      stateLock.withLock { reconfiguring = false }
      throw error
    }
    emitState()
  }

  private func makeDecoder() throws -> YlVideoToolboxDecoder {
    try YlVideoToolboxDecoder(
      formatDescription: videoFormat,
      onFrame: { [outputRelay] frame in outputRelay.frame(frame) },
      onError: { [outputRelay] error in outputRelay.error(error) }
    )
  }

  private func rebuildPipeline(positionUs: Int64) throws {
    let reopenedMedia = try YlOpenedMedia(
      recipe: sourceRecipe,
      networkBufferBytes: bufferBudget.networkBytes
    )
    guard let validContext = reopenedMedia.context else {
      reopenedMedia.close()
      throw NativePlayerError(
        category: "internal",
        code: "internal.fallback_invariant",
        message: "The reopened Matroska context was unavailable."
      )
    }

    var mediaNeedsClose = true
    var candidateDecoder: YlVideoToolboxDecoder?
    var candidateAudio: YlAudioRenderer?
    defer {
      if mediaNeedsClose {
        candidateDecoder?.dispose()
        candidateAudio?.dispose()
        reopenedMedia.close()
      }
    }

    let candidateFormat = try YlVideoToolboxDecoder.makeFormatDescription(
      context: validContext,
      streamIndex: videoStream.index
    )
    candidateDecoder = try YlVideoToolboxDecoder(
      formatDescription: candidateFormat,
      onFrame: { [outputRelay] frame in outputRelay.frame(frame) },
      onError: { [outputRelay] error in outputRelay.error(error) }
    )
    let renderer = YlAudioRenderer(bufferBudget: bufferBudget)
    candidateAudio = renderer
    if let selectedAudioStream,
       let cookie = audioCookies[selectedAudioStream.index] {
      try renderer.configure(stream: YlAudioStreamConfiguration(
        codec: .aac,
        sampleRate: Double(selectedAudioStream.sample_rate),
        channelCount: Int(selectedAudioStream.channel_count),
        magicCookie: cookie,
        generation: audioGeneration
      ))
      renderer.setVolume(desiredVolume)
      renderer.setRate(desiredRate)
    }
    if positionUs > 0 {
      try reopenedMedia.seek(toMediaTimeUs: positionUs)
      postSeekGate.reset(targetUs: positionUs)
    }

    videoFormat = candidateFormat
    openedMedia = reopenedMedia
    decoder = candidateDecoder
    candidateDecoder = nil
    audioRenderer = renderer
    candidateAudio = nil
    pendingAudioPacket = nil
    prebufferedVideoSample = false
    demuxEOF = false
    completionSent = false
    audioAnchored = false
    frameScheduler.flush(generation: generation)
    mediaClock.seek(to: positionUs)
    mediaNeedsClose = false
  }

  private func installDisplayLink(paused: Bool) {
    guard displayLink == nil else {
      displayLink?.isPaused = paused
      return
    }
    let link = CADisplayLink(target: self, selector: #selector(displayLinkTick))
    if #available(iOS 15.0, *) {
      link.preferredFrameRateRange = CAFrameRateRange(
        minimum: 15,
        maximum: 60,
        preferred: 30
      )
    } else {
      link.preferredFramesPerSecond = 30
    }
    link.add(to: .main, forMode: .common)
    link.isPaused = paused
    displayLink = link
  }

  private func completeIfDrained(atHostTimeUs hostTimeUs: Int64) {
    let shouldComplete = stateLock.withLock {
      active && playing && demuxEOF && !completionSent && pendingAudioPacket == nil
    }
    guard shouldComplete,
          frameScheduler.pendingPTS.isEmpty,
          (audioRenderer?.scheduledDurationUs ?? 0) == 0 else { return }
    stateLock.withLock {
      guard !completionSent else { return }
      completionSent = true
      playing = false
    }
    mediaClock.pause(atHostTimeUs: hostTimeUs)
    displayLink?.isPaused = true
    status = "completed"
    emitState()
  }

  private func setFailure(_ error: NativePlayerError) {
    guard !stateLock.withLock({ disposed }) else { return }
    status = "error"
    let details = errorMap(
      category: error.category,
      code: error.code,
      message: error.message,
      diagnostic: error.diagnostic
    )
    currentError = details
    emit(["playerId": playerId, "type": "error", "error": details])
    emitState()
  }

  private func selectAudioTrack(_ trackId: String?) throws {
    guard let trackId, trackId.hasPrefix("audio-"),
          let requestedIndex = Int32(trackId.dropFirst("audio-".count)),
          let requestedStream = audioStreams.first(where: { $0.index == requestedIndex }),
          let cookie = audioCookies[requestedIndex] else {
      throw NativePlayerError(
        category: "source",
        code: "track.not_found",
        message: "The requested audio track is unavailable."
      )
    }
    guard requestedStream.index != selectedAudioStream?.index else { return }

    guard stateLock.withLock({ active }) else {
      selectedAudioStream = requestedStream
      stateLock.withLock { audioGeneration &+= 1 }
      emit([
        "playerId": playerId,
        "type": "tracksChanged",
        "audioTracks": audioTracks,
        "videoTracks": videoTracks,
      ])
      emitState()
      return
    }

    let nextAudioGeneration = stateLock.withLock { audioGeneration &+ 1 }
    let candidate = YlAudioRenderer(bufferBudget: bufferBudget)
    do {
      try candidate.configure(stream: YlAudioStreamConfiguration(
        codec: .aac,
        sampleRate: Double(requestedStream.sample_rate),
        channelCount: Int(requestedStream.channel_count),
        magicCookie: cookie,
        generation: nextAudioGeneration
      ))
      candidate.setVolume(desiredVolume)
      candidate.setRate(desiredRate)
    } catch {
      candidate.dispose()
      throw error
    }

    let now = Self.hostTimeUs()
    let positionUs = mediaClock.position(atHostTimeUs: now)
    let wasPlaying = stateLock.withLock { () -> Bool in
      reconfiguring = true
      pumping = false
      return playing
    }
    mediaClock.pause(atHostTimeUs: now)
    worker.sync {}

    let previous = audioRenderer
    audioRenderer = candidate
    selectedAudioStream = requestedStream
    pendingAudioPacket = nil
    audioAnchored = false
    stateLock.withLock {
      audioGeneration = nextAudioGeneration
      reconfiguring = false
    }
    previous?.dispose()
    mediaClock.seek(to: positionUs)
    if wasPlaying {
      try candidate.play()
      mediaClock.play(atHostTimeUs: Self.hostTimeUs())
    }
    emit([
      "playerId": playerId,
      "type": "tracksChanged",
      "audioTracks": audioTracks,
      "videoTracks": videoTracks,
    ])
    requestPump()
    emitState()
  }

  private func anchorAudioIfNeeded(_ packet: YlCompressedAudioPacket) {
    guard !audioAnchored else { return }
    audioAnchored = true
    mediaClock.anchorAudio(
      ptsUs: max(0, packet.ptsUs),
      sampleTime: audioRenderer?.renderedAudioTime?.sampleTime ?? 0
    )
  }

  private var audioTracks: [[String: Any?]] {
    audioStreams.map { audioStream in
      [
        "id": "audio-\(audioStream.index)",
        "kind": "audio",
        "label": "AAC \(audioStream.index)",
        "language": nil,
        "isSelected": audioStream.index == selectedAudioStream?.index,
      ]
    }
  }

  private var videoTracks: [[String: Any?]] {
    [[
      "id": "video-\(videoStream.index)",
      "kind": "video",
      "width": Int(videoStream.width),
      "height": Int(videoStream.height),
      "bitrate": nil,
      "isSelected": true,
    ]]
  }

  private static func hostTimeUs() -> Int64 {
    Int64(CACurrentMediaTime() * 1_000_000)
  }

  deinit {
    dispose()
  }
}

private extension NSLock {
  func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
