import AVFoundation
import CoreMedia
import CoreVideo
import Flutter
import QuartzCore
import UIKit
import YlFFmpegBridge

final class YlPreparedFallback {
  let mediaInfo: YLFMediaInfo
  let videoStream: YLFStreamInfo
  let audioStream: YLFStreamInfo?
  let videoFormat: CMVideoFormatDescription
  let audioCookie: Data?
  private var context: YLFMediaContextRef?

  init(source: [String: Any?]) throws {
    guard let uri = source["uri"] as? String,
          let url = URL(string: uri),
          url.isFileURL else {
      throw NativePlayerError(
        category: "source",
        code: "source.invalid_uri",
        message: "A valid local file URI is required."
      )
    }
    var openedContext: YLFMediaContextRef?
    var openedInfo = YLFMediaInfo()
    let openResult = url.path.withCString {
      ylf_open_local($0, &openedContext, &openedInfo)
    }
    guard openResult == 0, let validContext = openedContext else {
      throw NativePlayerError(
        category: "container",
        code: openResult == -3 ? "container.mkv_malformed" : "container.mkv_open_failed",
        message: "The local Matroska file could not be opened.",
        diagnostic: "YlFFmpegBridge result \(openResult)"
      )
    }
    mediaInfo = openedInfo
    var contextNeedsClose = true
    defer {
      if contextNeedsClose { ylf_close(&openedContext) }
    }

    var selectedVideo: YLFStreamInfo?
    var selectedAudio: YLFStreamInfo?
    var sawUnsupportedAudio = false
    for index in 0..<openedInfo.stream_count {
      var stream = YLFStreamInfo()
      guard ylf_copy_stream_info(validContext, index, &stream) == 0 else { continue }
      if Int(stream.kind) == YLFStreamVideo,
         (Int(stream.codec) == YLFCodecH264 || Int(stream.codec) == YLFCodecHEVC),
         selectedVideo == nil {
        selectedVideo = stream
      } else if Int(stream.kind) == YLFStreamAudio {
        if Int(stream.codec) == YLFCodecAAC, selectedAudio == nil {
          selectedAudio = stream
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
    if selectedAudio == nil && sawUnsupportedAudio {
      throw NativePlayerError(
        category: "decoderUnsupported",
        code: "decoder.audio_aac_unsupported",
        message: "The selected Matroska audio track is not AAC."
      )
    }
    videoStream = selectedVideo
    audioStream = selectedAudio
    videoFormat = try YlVideoToolboxDecoder.makeFormatDescription(
      context: validContext,
      streamIndex: selectedVideo.index
    )

    if let selectedAudio {
      let size = ylf_stream_codec_config_size(validContext, selectedAudio.index)
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
        selectedAudio.index,
        &bytes,
        bytes.count
      ) == 0 else {
        throw NativePlayerError(
          category: "decoderUnsupported",
          code: "decoder.audio_aac_unsupported",
          message: "The AAC codec configuration is invalid."
        )
      }
      audioCookie = Data(bytes)
    } else {
      audioCookie = nil
    }

    let probe = try YlVideoToolboxDecoder(
      formatDescription: videoFormat,
      onFrame: { _ in },
      onError: { _ in }
    )
    probe.dispose()
    context = validContext
    contextNeedsClose = false
  }

  func takeContext() throws -> YLFMediaContextRef {
    guard let context else {
      throw NativePlayerError(
        category: "internal",
        code: "internal.fallback_invariant",
        message: "The prepared Matroska context was already consumed."
      )
    }
    self.context = nil
    return context
  }

  deinit {
    ylf_close(&context)
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
  private let mediaInfo: YLFMediaInfo
  private let videoStream: YLFStreamInfo
  private let audioStream: YLFStreamInfo?
  private let videoFormat: CMVideoFormatDescription
  private let worker = DispatchQueue(label: "dev.ylplayer.ios.fallback.demux")
  private let stateLock = NSLock()
  private let frameScheduler = YlFrameScheduler()
  private let audioRenderer = YlAudioRenderer()
  private let outputRelay = YlFallbackOutputRelay()
  private var mediaClock: YlMediaClock!
  private var decoder: YlVideoToolboxDecoder!
  private var context: YLFMediaContextRef?
  private var displayLink: CADisplayLink?
  private var currentPixelBuffer: CVPixelBuffer?
  private var active = false
  private var playing = false
  private var disposed = false
  private var pumping = false
  private var generation: UInt64
  private var status = "ready"
  private var firstFrameSent = false
  private var prebufferedVideoSample = false
  private var demuxEOF = false
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
    self.mediaInfo = prepared.mediaInfo
    self.videoStream = prepared.videoStream
    self.audioStream = prepared.audioStream
    self.videoFormat = prepared.videoFormat
    self.generation = generation
    self.emit = emit
    var ownedContext: YLFMediaContextRef? = try prepared.takeContext()
    self.context = ownedContext
    super.init()

    mediaClock = YlMediaClock(audioTime: { [weak audioRenderer] in
      audioRenderer?.renderedAudioTime
    })
    outputRelay.backend = self
    do {
      decoder = try YlVideoToolboxDecoder(
        formatDescription: videoFormat,
        onFrame: { [outputRelay] frame in outputRelay.frame(frame) },
        onError: { [outputRelay] error in outputRelay.error(error) }
      )
      if let audioStream, let cookie = prepared.audioCookie {
        try audioRenderer.configure(stream: YlAudioStreamConfiguration(
          codec: .aac,
          sampleRate: Double(audioStream.sample_rate),
          channelCount: Int(audioStream.channel_count),
          magicCookie: cookie,
          generation: generation
        ))
      }
    } catch {
      self.context = nil
      ylf_close(&ownedContext)
      throw error
    }
    frameScheduler.flush(generation: generation)
    openDurationMs = Int64((CACurrentMediaTime() - openStartedAt) * 1_000)
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
    link.isPaused = true
    displayLink = link
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
    stateLock.withLock { active = true }
    displayLink?.isPaused = false
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
    active = false
    playing = false
    let currentGeneration = generation
    stateLock.unlock()
    displayLink?.isPaused = true
    audioRenderer.pause()
    audioRenderer.flush()
    decoder.flush()
    frameScheduler.flush(generation: currentGeneration)
    mediaClock.pause(atHostTimeUs: Self.hostTimeUs())
    status = "paused"
    emitState()
  }

  func command(name: String, arguments: [String: Any?]) throws {
    switch name {
    case "open":
      emitState()
    case "play":
      stateLock.withLock { playing = true }
      if audioStream != nil { try audioRenderer.play() }
      mediaClock.play(atHostTimeUs: Self.hostTimeUs())
      status = "playing"
      emitState()
      requestPump()
    case "pause":
      stateLock.withLock { playing = false }
      if audioStream != nil { audioRenderer.pause() }
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
      if audioStream != nil { audioRenderer.setRate(rate) }
      mediaClock.setRate(Double(rate), atHostTimeUs: Self.hostTimeUs())
    case "setVolume":
      if audioStream != nil {
        audioRenderer.setVolume(float(arguments["volume"]) ?? 1)
      }
    case "selectAudioTrack":
      let requested = arguments["trackId"] as? String
      guard requested == audioTrackId else {
        throw NativePlayerError(
          category: "source",
          code: "track.not_found",
          message: "The requested audio track is unavailable."
        )
      }
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
    emit([
      "playerId": playerId,
      "type": "state",
      "state": [
        "status": status,
        "positionMs": positionUs / 1_000,
        "durationMs": durationMs,
        "bufferedPositionMs": (positionUs + audioRenderer.scheduledDurationUs) / 1_000,
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
          "bufferedDurationMs": audioRenderer.scheduledDurationUs / 1_000,
          "bufferedBytes": audioRenderer.scheduledBytes,
          "droppedFrames": frameScheduler.lateFrameDropCount,
          "audioUnderruns": audioRenderer.underrunCount,
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
    generation &+= 1
    stateLock.unlock()
    displayLink?.invalidate()
    displayLink = nil
    worker.sync {
      decoder.dispose()
      audioRenderer.dispose()
      frameScheduler.dispose()
      ylf_close(&context)
    }
    stateLock.withLock { currentPixelBuffer = nil }
  }

  fileprivate func receive(_ frame: YlVideoFrame) {
    let accepted = frameScheduler.enqueue(YlFrameEnvelope(
      payload: frame.pixelBuffer,
      ptsUs: frame.ptsUs == .min ? 0 : frame.ptsUs,
      durationUs: frame.durationUs,
      keyframe: frame.keyframe,
      generation: frame.generation
    ))
    guard accepted else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.firstFrameSent else { return }
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
    guard !disposed, active, !pumping, !demuxEOF else {
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
          category: "decoder",
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
      decoder.flush()
      if stateLock.withLock({ playing }) {
        DispatchQueue.main.async { [weak self] in
          self?.status = "completed"
          self?.emitState()
        }
      }
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
        decoder.decode(
          sample: unmanagedSample.takeRetainedValue(),
          generation: packetGeneration
        )
      } else {
        ylf_packet_release(&packet)
      }
    } else if streamIndex == audioStream?.index,
              let bytes = ylf_packet_data(ownedPacket) {
      let audioPacket = YlCompressedAudioPacket(
        data: Data(bytes: bytes, count: ylf_packet_size(ownedPacket)),
        ptsUs: ylf_packet_pts_us(ownedPacket),
        durationUs: ylf_packet_duration_us(ownedPacket),
        generation: packetGeneration
      )
      ylf_packet_release(&packet)
      do {
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
          category: "decoder",
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
    stateLock.withLock { generation &+= 1 }
    let nextGeneration = stateLock.withLock { generation }
    let seekResult = worker.sync { ylf_seek(context, targetUs) }
    guard seekResult == 0 else {
      throw NativePlayerError(
        category: "container",
        code: "container.mkv_seek_failed",
        message: "The Matroska file could not be seeked.",
        diagnostic: "YlFFmpegBridge result \(seekResult)"
      )
    }
    decoder.flush()
    audioRenderer.reset(generation: nextGeneration)
    frameScheduler.flush(generation: nextGeneration)
    mediaClock.seek(to: targetUs)
    audioAnchored = false
    pendingAudioPacket = nil
    prebufferedVideoSample = false
    demuxEOF = false
    requestPump()
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

  private func anchorAudioIfNeeded(_ packet: YlCompressedAudioPacket) {
    guard !audioAnchored else { return }
    audioAnchored = true
    mediaClock.anchorAudio(
      ptsUs: max(0, packet.ptsUs),
      sampleTime: audioRenderer.renderedAudioTime?.sampleTime ?? 0
    )
  }

  private var audioTrackId: String? {
    audioStream.map { "audio-\($0.index)" }
  }

  private var audioTracks: [[String: Any?]] {
    guard let audioStream else { return [] }
    return [[
      "id": "audio-\(audioStream.index)",
      "kind": "audio",
      "label": "AAC",
      "language": nil,
      "isSelected": true,
    ]]
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
