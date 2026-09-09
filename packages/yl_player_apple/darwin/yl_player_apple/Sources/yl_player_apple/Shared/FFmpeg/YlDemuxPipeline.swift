import AVFoundation
import CoreMedia
import Foundation
import YlFFmpegBridge

protocol YlDemuxControlling {
  func interrupt(_ media: YlOpenedMedia)
  func join(_ worker: DispatchQueue, operation: () -> Void)
  func resume(_ media: YlOpenedMedia)
  func seek(_ media: YlOpenedMedia, toMediaTimeUs: Int64) throws
}
struct YlOpenedMediaControl: YlDemuxControlling {
  func interrupt(_ media: YlOpenedMedia) { media.interruptRead() }
  func join(_ worker: DispatchQueue, operation: () -> Void) { worker.sync(execute: operation) }
  func resume(_ media: YlOpenedMedia) { media.resumeReads() }
  func seek(_ media: YlOpenedMedia, toMediaTimeUs targetUs: Int64) throws {
    try media.seek(toMediaTimeUs: targetUs)
  }
}

protocol YlDemuxOutput: YlAudioPipelineOutput {
  func demuxDidReachEOF(generation: UInt64)
  func shouldReportDemuxFailure(generation: UInt64) -> Bool
  func beginLiveReconnect(after error: NativePlayerError, packetGeneration: UInt64)
  func consumeDemuxVideo(packet: inout YLFPacketRef?, ownedPacket: YLFPacketRef, generation: UInt64) -> Void?
  var demuxAudioGeneration: UInt64 { get }
  func acceptsDemuxAudio(ptsUs: Int64) -> Bool
  func consumeDemuxAudio(_ packet: YlCompressedAudioPacket, onBackpressure: (TimeInterval) -> Void) -> Void?
}

protocol YlDemuxOpening {
  func open(recipe: YlFallbackSourceRecipe, networkBufferBytes: Int,
            sessionConfiguration: URLSessionConfiguration,
            onSourceCreated: ((YlByteSource) -> Void)?) throws -> YlOpenedMedia
}

struct YlFFmpegDemuxOpener: YlDemuxOpening {
  func open(recipe: YlFallbackSourceRecipe, networkBufferBytes: Int,
            sessionConfiguration: URLSessionConfiguration,
            onSourceCreated: ((YlByteSource) -> Void)?) throws -> YlOpenedMedia {
    try YlOpenedMedia(recipe: recipe, networkBufferBytes: networkBufferBytes,
      sessionConfiguration: sessionConfiguration, onSourceCreated: onSourceCreated)
  }
}

/// Owns the opened cursor, cancellation authority, track catalog and serial demux queue.
/// The session lock keeps detach/install atomic with the lifecycle generation.
final class YlDemuxPipeline {
  final class Resource {
    fileprivate let media: YlOpenedMedia
    fileprivate init(_ media: YlOpenedMedia) { self.media = media }
    var context: YLFMediaContextRef? { media.context }
    var info: YLFMediaInfo { media.info }
    var lastInputError: NativePlayerError? { media.lastInputError }
    func close() { media.close() }
    func cancelInput() { media.cancelInput() }
    func interruptRead() { media.interruptRead() }
    func resumeReads() { media.resumeReads() }
    func beginControlOperation(_ token: YlOpenCancellationToken?) { media.beginControlOperation(token) }
    func endControlOperation() { media.endControlOperation() }
    func handleMemoryWarning() { media.handleMemoryWarning() }
  }
  private let lock: NSLock
  private let control: any YlDemuxControlling
  private let opener: any YlDemuxOpening
  private let bufferBudget: YlFallbackBufferBudget
  weak var output: (any YlDemuxOutput)?
  let sourceRecipe: YlFallbackSourceRecipe
  let sessionConfiguration: URLSessionConfiguration
  let mediaPolicy: YlFallbackMediaPolicy
  private(set) var mediaInfo: YLFMediaInfo
  private(set) var videoStream: YLFStreamInfo
  private(set) var audioStreams: [YLFStreamInfo]
  private(set) var audioCookies: [Int32: Data]
  private(set) var isSeekable: Bool
  private var initialKeyframeGate = YlInitialKeyframeGate()
  private var openedMedia: Resource?
  private var sourceCancellationToken: YlOpenCancellationToken?
  private(set) var selectedAudioStream: YLFStreamInfo?
  private let worker = DispatchQueue(label: "dev.ylplayer.\(YlApplePlatform.current.rawValue).fallback.demux")

  var context: YLFMediaContextRef? { lock.withLock { openedMedia }?.context }

  init(prepared: YlPreparedFallback, lock: NSLock, bufferBudget: YlFallbackBufferBudget,
       opener: any YlDemuxOpening = YlFFmpegDemuxOpener(),
       control: any YlDemuxControlling = YlOpenedMediaControl()) throws {
    self.control = control
    self.lock = lock
    self.bufferBudget = bufferBudget
    self.opener = opener
    self.sourceRecipe = prepared.sourceRecipe
    self.sessionConfiguration = prepared.sessionConfiguration
    self.mediaPolicy = prepared.policy
    self.mediaInfo = prepared.mediaInfo
    self.videoStream = prepared.videoStream
    self.audioStreams = prepared.audioStreams
    self.audioCookies = prepared.audioCookies
    self.isSeekable = prepared.isSeekable
    let resumeState = prepared.resumeState
    self.selectedAudioStream = resumeState?.selectedAudioStreamIndex.flatMap { index in
      prepared.audioStreams.first { $0.index == index }
    } ?? prepared.audioStreams.first
    self.openedMedia = try Resource(prepared.takeMedia())
    self.sourceCancellationToken = prepared.takeCancellationToken()
  }

  var currentMedia: Resource? { openedMedia }
  var recoveryScheduler: any YlRecoveryScheduling { YlDispatchRecoveryScheduler(queue: worker) }
  func performSync<T>(_ operation: () throws -> T) rethrows -> T { try worker.sync(execute: operation) }
  func performAsync(_ operation: @escaping () -> Void) { worker.async(execute: operation) }
  func schedulePump(after delay: TimeInterval, operation: @escaping () -> Void) {
    worker.asyncAfter(deadline: .now() + delay, execute: operation)
  }
  func joinForControl(_ operation: () -> Void) { control.join(worker, operation: operation) }
  func detachMedia() -> Resource? { let old = openedMedia; openedMedia = nil; return old }
  @discardableResult
  func installMedia(_ media: Resource) -> Resource? { let old = openedMedia; openedMedia = media; return old }
  func discardMedia() { openedMedia?.close(); openedMedia = nil }
  func detachCancellationToken() -> YlOpenCancellationToken? {
    let old = sourceCancellationToken; sourceCancellationToken = nil; return old
  }
  func detachOrphanedCancellation() -> YlOpenCancellationToken? {
    let token = openedMedia == nil ? sourceCancellationToken : nil
    if token != nil { sourceCancellationToken = nil }
    return token
  }
  func installCancellation(_ token: YlOpenCancellationToken) { sourceCancellationToken = token }
  func ownsCancellation(_ token: YlOpenCancellationToken) -> Bool { sourceCancellationToken === token }
  func clearCancellation(ifOwned token: YlOpenCancellationToken) {
    if sourceCancellationToken === token { sourceCancellationToken = nil }
  }
  func resetInitialKeyframeGate() { initialKeyframeGate.reset() }
  func selectAudio(_ stream: YLFStreamInfo) { selectedAudioStream = stream }
  func clearStoppedCatalog() {
    selectedAudioStream = nil; audioStreams.removeAll(); audioCookies.removeAll(); isSeekable = false
  }
  func installReconnect(_ candidate: YlFallbackReconnectPipeline) {
    mediaInfo = candidate.info; videoStream = candidate.videoStream
    audioStreams = candidate.audioStreams; audioCookies = candidate.audioCookies
    selectedAudioStream = candidate.selectedAudioStream; openedMedia = candidate.media
  }

  func audioTracks(codecName: (YLFStreamInfo) -> String) -> [YlNativeTrack] {
    YlFallbackTrackCatalog.audioTracks(
      streams: audioStreams,
      selectedIndex: selectedAudioStream?.index,
      codecName: codecName
    )
  }

  var videoTracks: [YlNativeTrack] {
    [YlFallbackTrackCatalog.videoTrack(
      stream: videoStream,
      codecName: Int(videoStream.codec) == YLFCodecHEVC ? "hevc" : "h264",
      bitrate: nil
    )]
  }

  func interruptControlOperation() { lock.withLock { openedMedia }?.interruptRead() }
  func resumeControlOperation() { lock.withLock { openedMedia }?.resumeReads() }

  func inspectReopened(context validContext: YLFMediaContextRef, info: YLFMediaInfo,
                       validateVideo: (YLFStreamInfo) throws -> Void) throws -> (
    video: YLFStreamInfo, audio: [YLFStreamInfo], cookies: [Int32: Data]
  ) {
    var selectedVideo: YLFStreamInfo?
    var supportedAudio: [YLFStreamInfo] = []
    var sawUnsupportedAudio = false
    for index in 0..<info.stream_count {
      var stream = YLFStreamInfo()
      guard ylf_copy_stream_info(validContext, index, &stream) == 0 else { continue }
      if Int(stream.kind) == YLFStreamVideo,
         (Int(stream.codec) == YLFCodecH264 || Int(stream.codec) == YLFCodecHEVC),
         selectedVideo == nil {
        selectedVideo = stream
      } else if Int(stream.kind) == YLFStreamAudio {
        if Int(stream.codec) == YLFCodecAAC || Int(stream.codec) == YLFCodecMP3 {
          supportedAudio.append(stream)
        } else {
          sawUnsupportedAudio = true
        }
      }
    }
    guard let selectedVideo else {
      throw NativePlayerError(
        category: "decoderUnsupported",
        code: "decoder.video_hardware_unavailable",
        message: "The reconnected FLV stream has no supported H.264 or H.265 video."
      )
    }
    if supportedAudio.isEmpty && sawUnsupportedAudio {
      throw NativePlayerError(
        category: "decoderUnsupported",
        code: "decoder.audio_aac_unsupported",
        message: "The reconnected FLV audio track is not AAC or MP3."
      )
    }

    try validateVideo(selectedVideo)

    var copiedAudioCookies: [Int32: Data] = [:]
    for audioStream in supportedAudio where Int(audioStream.codec) == YLFCodecAAC {
      let size = ylf_stream_codec_config_size(validContext, audioStream.index)
      guard size > 0 else {
        throw NativePlayerError(
          category: "decoderUnsupported",
          code: "decoder.audio_aac_unsupported",
          message: "The reconnected AAC codec configuration is missing."
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
          message: "The reconnected AAC codec configuration is invalid."
        )
      }
      copiedAudioCookies[audioStream.index] = Data(bytes)
    }

    return (selectedVideo, supportedAudio, copiedAudioCookies)
  }

  func audioStream(for trackId: String?) throws -> YLFStreamInfo {
    guard let trackId, trackId.hasPrefix("audio-"),
          let requestedIndex = Int32(trackId.dropFirst("audio-".count)),
          let requestedStream = audioStreams.first(where: { $0.index == requestedIndex }) else {
      throw NativePlayerError(
        category: "source",
        code: "track.not_found",
        message: "The requested audio track is unavailable."
      )
    }
    return requestedStream
  }

  func seek(_ media: Resource, toMediaTimeUs position: Int64) throws {
    try control.seek(media.media, toMediaTimeUs: position)
  }

  func interrupt(_ media: Resource) { control.interrupt(media.media) }
  func resume(_ media: Resource) { control.resume(media.media) }

  func pumpOne(generation packetGeneration: UInt64) {
    guard let output else { return }
    var packet: YLFPacketRef?
    let result = readPacket(&packet)
    if result == Int32(YLFResultEOF) {
      if mediaPolicy.isLive {
        output.beginLiveReconnect(
          after: NativePlayerError(
            category: "network",
            code: "network.http_status",
            message: "The HTTP-FLV connection ended."
          ),
          packetGeneration: packetGeneration
        )
        return
      }
      output.demuxDidReachEOF(generation: packetGeneration)
      return
    }
    guard result == Int32(YLFResultOK), let ownedPacket = packet else {
      let inputError = lock.withLock { openedMedia?.lastInputError }
      if mediaPolicy.isLive, result == Int32(YLFResultCallbackFailed) {
        ylf_packet_release(&packet)
        output.beginLiveReconnect(
          after: inputError ?? NativePlayerError(
            category: "network",
            code: "network.http_status",
            message: "The HTTP-FLV network input failed.",
            diagnostic: "YlFFmpegBridge result \(result)"
          ),
          packetGeneration: packetGeneration
        )
        return
      }
      let shouldReport = output.shouldReportDemuxFailure(generation: packetGeneration)
      ylf_packet_release(&packet)
      if shouldReport {
        output.fail(ylFallbackPacketReadError(
          result: result,
          inputError: inputError,
          container: mediaPolicy.container
        ))
      }
      return
    }

    do {
      try bufferBudget.validateInFlightPacket(size: ylf_packet_size(ownedPacket))
    } catch let error as NativePlayerError {
      ylf_packet_release(&packet)
      output.setDemuxPumping(false)
      output.fail(error)
      return
    } catch {
      ylf_packet_release(&packet)
      output.setDemuxPumping(false)
      return
    }

    let streamIndex = ylf_packet_stream_index(ownedPacket)
    if mediaPolicy.requiresInitialVideoKeyframe {
      let isVideo = streamIndex == videoStream.index
      let accepted = lock.withLock {
        initialKeyframeGate.accepts(
          isVideo: isVideo,
          isKeyframe: isVideo && ylf_packet_is_keyframe(ownedPacket)
        )
      }
      if !accepted {
        ylf_packet_release(&packet)
        output.setDemuxPumping(false)
        output.requestAudioPump()
        return
      }
    }
    var retryDelay = TimeInterval(0)
    if streamIndex == videoStream.index {
      guard output.consumeDemuxVideo(packet: &packet, ownedPacket: ownedPacket, generation: packetGeneration) != nil else { return }
    } else if streamIndex == selectedAudioStream?.index,
              let bytes = ylf_packet_data(ownedPacket) {
      let audioPacket = YlCompressedAudioPacket(
        data: Data(bytes: bytes, count: ylf_packet_size(ownedPacket)),
        ptsUs: ylf_packet_pts_us(ownedPacket),
        durationUs: ylf_packet_duration_us(ownedPacket),
        generation: output.demuxAudioGeneration
      )
      ylf_packet_release(&packet)
      if !output.acceptsDemuxAudio(ptsUs: audioPacket.ptsUs) {
        output.setDemuxPumping(false)
        output.requestAudioPump()
        return
      }
      guard output.consumeDemuxAudio(audioPacket, onBackpressure: { delay in retryDelay = delay }) != nil else { return }
    } else {
      ylf_packet_release(&packet)
    }

    output.setDemuxPumping(false)
    output.requestAudioPump(after: retryDelay)
  }

  func releasePacket(_ packet: inout YLFPacketRef?) { ylf_packet_release(&packet) }

  func readPacket(_ packet: inout YLFPacketRef?) -> Int32 {
    ylf_read_packet(context, &packet)
  }

  func open(recipe: YlFallbackSourceRecipe, networkBufferBytes: Int,
            sessionConfiguration: URLSessionConfiguration,
            onSourceCreated: ((YlByteSource) -> Void)? = nil) throws -> Resource {
    try Resource(opener.open(recipe: recipe, networkBufferBytes: networkBufferBytes,
      sessionConfiguration: sessionConfiguration, onSourceCreated: onSourceCreated))
  }
}

func ylFallbackPacketReadError(
  result: Int32,
  inputError: NativePlayerError?,
  container: YlFallbackContainer
) -> NativePlayerError {
  if result == Int32(YLFResultCallbackFailed), let inputError {
    return inputError
  }
  return NativePlayerError(
    category: "container",
    code: container == .flv
      ? "container.flv_malformed" : "container.mkv_malformed",
    message: container == .flv
      ? "The FLV packet stream is malformed."
      : "The Matroska packet stream is malformed.",
    diagnostic: "YlFFmpegBridge result \(result)"
  )
}
