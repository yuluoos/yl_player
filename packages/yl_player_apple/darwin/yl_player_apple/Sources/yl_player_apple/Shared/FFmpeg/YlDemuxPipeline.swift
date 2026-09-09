import AVFoundation
import CoreMedia
import Foundation
import YlFFmpegBridge

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
  private let lock: NSLock
  private let opener: any YlDemuxOpening
  private let bufferBudget: YlFallbackBufferBudget
  weak var output: (any YlDemuxOutput)?
  let sourceRecipe: YlFallbackSourceRecipe
  let sessionConfiguration: URLSessionConfiguration
  let mediaPolicy: YlFallbackMediaPolicy
  var mediaInfo: YLFMediaInfo
  var videoStream: YLFStreamInfo
  var audioStreams: [YLFStreamInfo]
  var audioCookies: [Int32: Data]
  var isSeekable: Bool
  var initialKeyframeGate = YlInitialKeyframeGate()
  var openedMedia: YlOpenedMedia?
  var sourceCancellationToken: YlOpenCancellationToken?
  var selectedAudioStream: YLFStreamInfo?
  let worker = DispatchQueue(label: "dev.ylplayer.\(YlApplePlatform.current.rawValue).fallback.demux")

  var context: YLFMediaContextRef? { lock.withLock { openedMedia }?.context }

  init(prepared: YlPreparedFallback, lock: NSLock, bufferBudget: YlFallbackBufferBudget,
       opener: any YlDemuxOpening = YlFFmpegDemuxOpener()) throws {
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
    self.openedMedia = try prepared.takeMedia()
    self.sourceCancellationToken = prepared.takeCancellationToken()
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

  func seek(_ media: YlOpenedMedia, toMediaTimeUs position: Int64) throws {
    try media.seek(toMediaTimeUs: position)
  }

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
            onSourceCreated: ((YlByteSource) -> Void)? = nil) throws -> YlOpenedMedia {
    try opener.open(recipe: recipe, networkBufferBytes: networkBufferBytes,
      sessionConfiguration: sessionConfiguration, onSourceCreated: onSourceCreated)
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
