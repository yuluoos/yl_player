import AVFoundation
import CoreMedia
import Foundation
import YlFFmpegBridge

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

  init(prepared: YlPreparedFallback, lock: NSLock,
       opener: any YlDemuxOpening = YlFFmpegDemuxOpener()) throws {
    self.lock = lock
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

