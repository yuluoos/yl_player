import AVFoundation
import CoreMedia
import Foundation
import YlFFmpegBridge

enum YlPreparedOpen {
  case avPlayer(source: [String: Any?])
  case headeredHls(source: [String: Any?], prepared: YlPreparedHlsAsset)
  case fallback(source: [String: Any?], prepared: YlPreparedFallback)

  func discard() {
    switch self {
    case .avPlayer:
      break
    case let .headeredHls(_, prepared):
      prepared.discard()
    case let .fallback(_, prepared):
      prepared.discard()
    }
  }
}

final class YlPreparedFallback {
  let sourceRecipe: YlFallbackSourceRecipe
  let policy: YlFallbackMediaPolicy
  let mediaInfo: YLFMediaInfo
  let videoStream: YLFStreamInfo
  let audioStreams: [YLFStreamInfo]
  let videoFormat: CMVideoFormatDescription
  let audioCookies: [Int32: Data]
  let sessionConfiguration: URLSessionConfiguration
  var container: YlFallbackContainer { policy.container }
  var isSeekable: Bool { policy.isSeekable }
  private(set) var resumeState: YlFallbackResumeState?
  private var openedMedia: YlOpenedMedia?
  private var cancellationToken: YlOpenCancellationToken?

  init(
    source: [String: Any?],
    requireHardwareProbe: Bool = true,
    configuration: PlayerConfiguration = PlayerConfiguration(map: [:]),
    sessionConfiguration: URLSessionConfiguration = .ephemeral,
    cancellationToken: YlOpenCancellationToken? = nil,
    onRetry: YlNetworkByteSource.RetryCallback? = nil
  ) throws {
    self.sessionConfiguration = sessionConfiguration
    try cancellationToken?.throwIfCancelled()
    guard let uri = source["uri"] as? String,
          let url = URL(string: uri) else {
      throw NativePlayerError(
        category: "source",
        code: "source.invalid_uri",
        message: "A valid fallback media URI is required."
      )
    }
    let formatHint = source["formatHint"] as? String ?? "automatic"
    let container: YlFallbackContainer = formatHint == "httpFlv"
      || formatHint == "flv"
      || (formatHint == "automatic" && url.pathExtension.lowercased() == "flv")
      ? .flv : .matroska
    if url.isFileURL {
      sourceRecipe = .local(path: url.path, container: container)
    } else if let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" {
      let headers = stringMap(source["headers"]).compactMapValues { $0 as? String }
      sourceRecipe = .network(request: YlNetworkRequestRecipe(
        url: url,
        headers: headers,
        configuration: configuration.network,
        mode: container == .flv ? .sequentialLive : .randomAccessVOD
      ), container: container)
    } else {
      throw NativePlayerError(
        category: "source",
        code: "source.invalid_uri",
        message: "Only file, HTTP, and HTTPS fallback media URIs are supported."
      )
    }
    let budget = try YlFallbackBufferBudget.make(configuration: configuration)
    let opened = try YlOpenedMedia(
      recipe: sourceRecipe,
      networkBufferBytes: budget.networkBytes,
      sessionConfiguration: sessionConfiguration,
      onRetry: onRetry,
      onSourceCreated: { source in
        cancellationToken?.onCancel { source.cancel() }
      }
    )
    try cancellationToken?.throwIfCancelled()
    mediaInfo = opened.info
    policy = YlFallbackMediaPolicy(
      container: container,
      sourceSupportsRandomAccess: opened.supportsRandomAccess
    )
    guard let validContext = opened.context else {
      opened.close()
      throw NativePlayerError(
        category: "internal",
        code: "internal.fallback_invariant",
        message: "The opened fallback media context was unavailable."
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
        if Int(stream.codec) == YLFCodecAAC || Int(stream.codec) == YLFCodecMP3 {
          selectedAudio.append(stream)
        } else {
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
        message: container == .flv
          ? "The selected FLV audio track is not AAC or MP3."
          : "The selected Matroska audio track is not AAC."
      )
    }
    videoStream = selectedVideo
    audioStreams = selectedAudio
    videoFormat = try YlVideoToolboxDecoder.makeFormatDescription(
      context: validContext,
      streamIndex: selectedVideo.index
    )

    var copiedAudioCookies: [Int32: Data] = [:]
    for audioStream in selectedAudio where Int(audioStream.codec) == YLFCodecAAC {
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
    self.cancellationToken = cancellationToken
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

  func prepareForReactivation(_ requested: YlFallbackResumeState) throws {
    guard let openedMedia else {
      throw NativePlayerError(
        category: "internal",
        code: "internal.fallback_invariant",
        message: "The prepared Matroska context was already consumed."
      )
    }
    let resolved = YlFallbackReactivationPolicy.resolve(
      isSeekable: isSeekable,
      savedPositionUs: requested.positionUs,
      selectedAudioStreamIndex: requested.selectedAudioStreamIndex,
      shouldPlay: requested.shouldPlay
    )
    if resolved.positionUs > 0 {
      try openedMedia.seek(toMediaTimeUs: resolved.positionUs)
    }
    resumeState = resolved
  }

  func takeCancellationToken() -> YlOpenCancellationToken? {
    defer { cancellationToken = nil }
    return cancellationToken
  }

  func discard() {
    cancellationToken?.cancel()
    cancellationToken = nil
    openedMedia?.close()
    openedMedia = nil
  }

  deinit {
    discard()
  }
}
