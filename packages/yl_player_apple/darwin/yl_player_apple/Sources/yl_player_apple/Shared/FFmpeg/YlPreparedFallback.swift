import AVFoundation
import CoreMedia
import Foundation
import YlFFmpegBridge

enum YlPreparedOpen {
  case fairPlay(source: YlAppleSourceDescriptor, backend: YlFairPlayBackend)
  case avPlayer(source: YlAppleSourceDescriptor)
  case headeredHls(source: YlAppleSourceDescriptor, prepared: YlPreparedHlsAsset)
  case fallback(source: YlAppleSourceDescriptor, prepared: YlPreparedFallback)

  func discard() {
    switch self {
    case let .fairPlay(_, backend):
      if Thread.isMainThread { backend.dispose() }
      else { DispatchQueue.main.async { backend.dispose() } }
    case .avPlayer:
      break
    case let .headeredHls(_, prepared):
      prepared.discard()
    case let .fallback(_, prepared):
      prepared.discard()
    }
  }

  var requiresHardwareDecoderLease: Bool {
    if case .fallback = self { return true }
    return false
  }
}

final class YlPreparedFallback {
  let decoderPolicy: YlDecoderPolicy
  let decoderFactoryPolicy: YlDecoderPolicy
  private var preparedVideo: YlVideoPipeline?
  let bufferScope: YlManagedBufferScope
  let boundedPlan: YlBoundedBufferPlan?
  let commitEvents: YlAppleCommitEmitter?
  let sourceRecipe: YlFallbackSourceRecipe
  let policy: YlFallbackMediaPolicy
  let mediaInfo: YLFMediaInfo
  let videoStream: YLFStreamInfo
  let audioStreams: [YLFStreamInfo]
  let videoFormat: CMVideoFormatDescription
  let felConfiguration: YlFELConfiguration?
  let usesInBandVideoConfiguration: Bool
  let audioCookies: [Int32: Data]
  let sessionConfiguration: URLSessionConfiguration
  var container: YlFallbackContainer { policy.container }
  var isSeekable: Bool { policy.isSeekable }
  private(set) var resumeState: YlFallbackResumeState?
  private var openedMedia: YlOpenedMedia?
  private var cancellationToken: YlOpenCancellationToken?

  init(
    source: YlAppleSourceDescriptor,
    requireHardwareProbe: Bool = true,
    configuration: PlayerConfiguration = PlayerConfiguration(map: [:]),
    sessionConfiguration: URLSessionConfiguration = .ephemeral,
    cancellationToken: YlOpenCancellationToken? = nil,
    commitEvents: YlAppleCommitEmitter? = nil,
    onRetry: YlNetworkByteSource.RetryCallback? = nil,
    rtmpSourceFactory: ((YlRtmpRequestRecipe) -> YlRtmpByteSource)? = nil
  ) throws {
    self.decoderPolicy = source.loadOptions?.decoderPolicy ?? .systemDefault
    self.decoderFactoryPolicy = source.loadOptions?.decoderPolicy ?? .hardwareRequired
    var plan = source.boundedPlan
    if plan == nil, let options = source.loadOptions, options.bufferStrategy == .bounded,
       let low = options.minDurationMs, let high = options.maxDurationMs, let bytes = options.maxManagedBytes {
      plan = try YlBoundedBufferPlan(minDurationMs: low, maxDurationMs: high, maxBytes: bytes)
    }
    self.bufferScope = try source.bufferScope ?? YlManagedBufferLedger().makeScope(maxBytes: plan?.maxBytes)
    self.boundedPlan = plan
    bufferScope.configureTimeline(plan)
    self.commitEvents = commitEvents
    self.sessionConfiguration = sessionConfiguration
    try cancellationToken?.throwIfCancelled()
    guard let url = source.url else {
      throw NativePlayerError(
        category: "source",
        code: "source.invalid_uri",
        message: "A valid fallback media URI is required."
      )
    }
    let formatHint = source.formatHint
    let resolvedFormat = YlEngineRouter.resolvedFormat(source, url: url)
    let container: YlFallbackContainer
    let flvIsLive = source.kind != .file && source.intent != .onDemand
    if ["rtmp", "rtmps"].contains(url.scheme?.lowercased() ?? "") {
      container = .flv
    } else if resolvedFormat == .avi {
      container = .avi
    } else if resolvedFormat == .mpegTs {
      container = .mpegTs
    } else if resolvedFormat == .hls {
      container = .hlsMpegTs
    } else if formatHint == .flv
      || (formatHint == .automatic && url.pathExtension.lowercased() == "flv") {
      container = .flv
    } else if [YlSourceFormat.mp4, .mov].contains(resolvedFormat) {
      container = .mp4
    } else {
      container = .matroska
    }
    if ["rtmp", "rtmps"].contains(url.scheme?.lowercased() ?? "") {
      sourceRecipe = .rtmp(request: .init(address: try YlRtmpAddress.validate(source),
        recovery: source.rtmpRecovery, bufferScope: bufferScope))
    } else if url.isFileURL {
      guard container != .hlsMpegTs else {
        throw NativePlayerError(
          category: "unsupported",
          code: "container.hls_managed_unsupported",
          message: "Managed MPEG-TS HLS currently supports network playlists only."
        )
      }
      sourceRecipe = .local(path: url.path, container: container)
    } else if let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" {
      let headers = source.headers
      let request = YlNetworkRequestRecipe(
        url: url,
        headers: headers,
        credentials: source.credentials,
        credentialContext: source.credentialContext,
        configuration: source.networkConfiguration.map(YlNetworkConfiguration.init(options:)) ?? configuration.network,
        mode: (container == .flv && flvIsLive) || container == .hlsMpegTs ? .sequentialLive : .randomAccessVOD,
        managedIntent: source.networkPolicy == .managed ? source.managedRequestIntent : nil,
        bufferScope: bufferScope
      )
      sourceRecipe = container == .hlsMpegTs
        ? .hls(request: request)
        : .network(request: request, container: container)
    } else {
      throw NativePlayerError(
        category: "source",
        code: "source.invalid_uri",
        message: "Only file, HTTP, and HTTPS fallback media URIs are supported."
      )
    }
    let budget: YlFallbackBufferBudget
    if let boundedPlan { budget = .bounded(boundedPlan, scope: bufferScope) }
    else { budget = try YlFallbackBufferBudget.make(configuration: configuration) }
    let opened = try YlOpenedMedia(
      recipe: sourceRecipe,
      networkBufferBytes: boundedPlan?.networkWatermark ?? budget.networkBytes,
      sessionConfiguration: sessionConfiguration,
      onRetry: onRetry,
      onSourceCreated: { source in
        cancellationToken?.onCancel { source.cancel() }
      }, rtmpSourceFactory: rtmpSourceFactory
    )
    try cancellationToken?.throwIfCancelled()
    mediaInfo = opened.info
    policy = YlFallbackMediaPolicy(
      container: container,
      sourceSupportsRandomAccess: opened.supportsRandomAccess,
      flvIsLive: flvIsLive
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
    let opusPolicyAllowed = container == .matroska && source.intent != .live && boundedPlan == nil
      && source.networkPolicy != .managed && decoderPolicy != .hardwareRequired
    var sawBlockedOpus = false
    var sawBlockedVorbis = false
    var sawUnsupportedAudio = false
    var sawVideo = false
    for index in 0..<mediaInfo.stream_count {
      var stream = YLFStreamInfo()
      guard ylf_copy_stream_info(validContext, index, &stream) == 0 else { continue }
      if sourceRecipe.isRtmp && ((Int(stream.kind) == YLFStreamVideo && Int(stream.codec) != YLFCodecH264)
          || (Int(stream.kind) == YLFStreamAudio && Int(stream.codec) != YLFCodecAAC)) {
        throw ylRtmpError("container.unsupported")
      }
      if Int(stream.kind) == YLFStreamVideo { sawVideo = true }
      if Int(stream.kind) == YLFStreamVideo,
         (Int(stream.codec) == YLFCodecH264 || Int(stream.codec) == YLFCodecHEVC || Int(stream.codec) == YLFCodecVP9),
         selectedVideo == nil {
        selectedVideo = stream
      } else if Int(stream.kind) == YLFStreamAudio {
        if Int(stream.codec) == YLFCodecOpus && !opusPolicyAllowed {
          // Retain existing AAC/etc. choices; excluded Opus is not advertised.
          sawBlockedOpus = true
          continue
        }
        if Int(stream.codec) == YLFCodecVorbis && !opusPolicyAllowed {
          sawBlockedVorbis = true
          continue
        }
        if YlAudioCodec(bridgeCodec: stream.codec) != .unsupported {
          selectedAudio.append(stream)
        } else {
          sawUnsupportedAudio = true
        }
      }
    }
    guard let selectedVideo else {
      throw NativePlayerError(
        category: sawVideo ? "decoderUnsupported" : "unsupported",
        code: sawVideo ? "decoder.unsupported" : "policy.unsupported",
        message: sawVideo ? "The video codec is unsupported." : "This fallback route does not implement audio-only playback."
      )
    }
    if Int(selectedVideo.codec) == YLFCodecVP9,
       container != .matroska || source.intent == .live || !policy.isSeekable || boundedPlan != nil || source.networkPolicy == .managed {
      throw NativePlayerError(category: "unsupported", code: "policy.vp9_unsupported",
        message: "VP9 currently supports seekable Matroska or WebM VOD without strict networking or buffer policies.")
    }
    if selectedAudio.isEmpty && sawBlockedOpus {
      throw NativePlayerError(category: "unsupported", code: "policy.opus_unsupported",
        message: "Opus currently supports ordinary Matroska VOD without strict networking, buffer or hardware policies.")
    }
    if selectedAudio.isEmpty && sawBlockedVorbis {
      throw NativePlayerError(category: "unsupported", code: "policy.vorbis_unsupported",
        message: "Vorbis currently supports ordinary Matroska VOD without strict networking, buffer or hardware policies.")
    }
    if selectedAudio.isEmpty && sawUnsupportedAudio {
      throw NativePlayerError(
        category: "decoderUnsupported",
        code: "decoder.audio_unsupported",
        message: container == .flv
          ? "The selected FLV audio codec is unsupported."
          : "The selected managed audio track is unsupported."
      )
    }
    try boundedPlan?.validate(width: Int(selectedVideo.width), height: Int(selectedVideo.height))
    if boundedPlan != nil { bufferScope.protectFrame(bytes: Int(selectedVideo.width) * Int(selectedVideo.height) * 8) }
    videoStream = selectedVideo
    felConfiguration = try YlFELConfiguration.probe(
      context: validContext, streamIndex: selectedVideo.index,
      maxPacketBytes: budget.inFlightPacketBytes,
      checkCancellation: { try cancellationToken?.throwIfCancelled() },
      reserveBytes: { [bufferScope] count in
        guard let reservation = bufferScope.reserve(category: .compressedPackets, bytes: count) else {
          throw YlManagedBufferLedger.unsupported()
        }
        return reservation
      },
      rewind: { _ = try opened.seek(toMediaTimeUs: 0) }
    )
    let inBandFormat: CMVideoFormatDescription?
    if Int(selectedVideo.codec) == YLFCodecVP9 {
      inBandFormat = try YlVP9Configuration.makeFormatDescription(context: validContext, stream: selectedVideo,
        maxPacketBytes: budget.inFlightPacketBytes, checkCancellation: { try cancellationToken?.throwIfCancelled() },
        reserveBytes: { [bufferScope] bytes in
          guard let token = bufferScope.reserve(category: .compressedPackets, bytes: bytes) else { throw YlManagedBufferLedger.unsupported() }
          return token
        }, readFailure: { result in
          ylFallbackPacketReadError(result: result, inputError: opened.lastInputError, container: container)
        }, rewind: { _ = try opened.seek(toMediaTimeUs: 0) })
    } else if felConfiguration == nil, container == .matroska, policy.isSeekable {
      inBandFormat = try YlHEVCInBandConfiguration.makeFormatDescription(
        context: validContext, streamIndex: selectedVideo.index,
        maxPacketBytes: budget.inFlightPacketBytes,
        checkCancellation: { try cancellationToken?.throwIfCancelled() },
        reserveBytes: { [bufferScope] count in
          guard let reservation = bufferScope.reserve(category: .compressedPackets, bytes: count) else {
            throw YlManagedBufferLedger.unsupported()
          }
          return reservation
        },
        readFailure: { result in
          ylFallbackPacketReadError(result: result, inputError: opened.lastInputError, container: container)
        },
        rewind: { _ = try opened.seek(toMediaTimeUs: 0) }
      )
    } else {
      inBandFormat = nil
    }
    usesInBandVideoConfiguration = inBandFormat != nil || felConfiguration != nil
    videoFormat = try felConfiguration?.baseFormat ?? inBandFormat ?? YlVideoToolboxDecoder.makeFormatDescription(
      context: validContext, streamIndex: selectedVideo.index)

    var copiedAudioCookies: [Int32: Data] = [:]
    for audioStream in selectedAudio where Int(audioStream.codec) == YLFCodecAAC {
      let size = ylf_stream_codec_config_size(validContext, audioStream.index)
      if size > 0 {
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
      } else if container == .hlsMpegTs || container == .mpegTs,
                let cookie = ylAACLCConfiguration(
                  sampleRate: Int(audioStream.sample_rate),
                  channelCount: Int(audioStream.channel_count)
                ) {
        // MPEG-TS carries AAC configuration in ADTS headers rather than
        // codecpar extradata. AudioToolbox consumes the equivalent ASC cookie.
        copiedAudioCookies[audioStream.index] = cookie
      } else {
        throw NativePlayerError(
          category: "decoderUnsupported",
          code: "decoder.audio_aac_unsupported",
          message: "The AAC codec configuration is missing."
        )
      }
    }
    for audioStream in selectedAudio where Int(audioStream.codec) == YLFCodecFLAC {
      // Matroska's demuxed FLAC config is exactly one STREAMINFO payload.
      // Reject unexpected sizes before allocating or copying source bytes.
      guard ylf_stream_codec_config_size(validContext, audioStream.index) == 34 else {
        throw NativePlayerError(category: "decoderUnsupported",
          code: "decoder.audio_flac_unsupported", message: "The FLAC STREAMINFO is missing or invalid.")
      }
      var bytes = [UInt8](repeating: 0, count: 34)
      guard ylf_copy_stream_codec_config(validContext, audioStream.index, &bytes, bytes.count) == 0 else {
        throw NativePlayerError(category: "decoderUnsupported",
          code: "decoder.audio_flac_unsupported", message: "The FLAC STREAMINFO could not be read.")
      }
      copiedAudioCookies[audioStream.index] = Data(bytes)
    }
    for audioStream in selectedAudio where Int(audioStream.codec) == YLFCodecOpus {
      guard ylf_stream_opus_delay_samples(validContext, audioStream.index) >= 0,
            ylf_stream_codec_config_size(validContext, audioStream.index) == 19 else { throw ylOpusUnsupportedError() }
      var bytes = [UInt8](repeating: 0, count: 19)
      guard ylf_copy_stream_codec_config(validContext, audioStream.index, &bytes, bytes.count) == 0 else {
        throw ylOpusUnsupportedError()
      }
      copiedAudioCookies[audioStream.index] = Data(bytes)
    }
    for audioStream in selectedAudio where Int(audioStream.codec) == YLFCodecVorbis {
      let size = ylf_stream_codec_config_size(validContext, audioStream.index)
      guard ylf_stream_vorbis_preroll_us(validContext, audioStream.index) > 0,
            (3...65536).contains(size) else { throw ylVorbisUnsupportedError() }
      var bytes = [UInt8](repeating: 0, count: Int(size))
      guard ylf_copy_stream_codec_config(validContext, audioStream.index, &bytes, bytes.count) == 0 else {
        throw ylVorbisUnsupportedError()
      }
      copiedAudioCookies[audioStream.index] = Data(bytes)
    }
    // FLV AAC SoundRate/SoundType are placeholders; the sequence header's
    // AudioSpecificConfig is authoritative (FLV specification, AudioTagHeader).
    // The minimal demux bridge has not run a decoder to normalize these fields.
    audioStreams = selectedAudio.map { stream in
      guard (container == .flv || container == .hlsMpegTs || container == .mpegTs), Int(stream.codec) == YLFCodecAAC,
            let cookie = copiedAudioCookies[stream.index],
            let config = ylInspectedAACLCConfiguration(cookie: cookie) else { return stream }
      var normalized = stream
      normalized.sample_rate = config.sampleRate; normalized.channel_count = config.channelCount
      return normalized
    }
    audioCookies = copiedAudioCookies

    if requireHardwareProbe {
      if let felConfiguration {
        var probeBudget = budget
        probeBudget.bufferScope = bufferScope
        let probe = try YlFELVideoDecoder(configuration: felConfiguration,
          bufferBudget: probeBudget,
          factory: YlHardwareVTSessionFactory(policy: decoderFactoryPolicy), policy: decoderPolicy,
          onFrame: { _ in }, onError: { _ in })
        probe.dispose()
      } else {
        let probe = try YlVideoToolboxDecoder(
          formatDescription: videoFormat,
          onFrame: { _ in },
          onError: { _ in }
        )
        probe.dispose()
      }
    }
    openedMedia = opened
    self.cancellationToken = cancellationToken
    mediaNeedsClose = false
  }

  func prepareHardwareEvidence(configuration: PlayerConfiguration,
      factory: YlVTSessionFactory?, stage: YlHardwareEvidencePreparation,
      token: YlOpenCancellationToken) throws {
    guard decoderPolicy == .hardwareRequired else { return }
    let pipeline = try stage.run(token: token, work: { [self] in
      let pipeline = YlVideoPipeline(format: videoFormat,
        bufferBudget: try .make(configuration: configuration, prepared: self),
        factory: factory ?? YlHardwareVTSessionFactory(policy: decoderPolicy), policy: decoderPolicy,
        felConfiguration: felConfiguration)
      do { try pipeline.initializeDecoder() }
      catch let error as NativePlayerError {
        if error.code == "resource.video_decoder_limit" || error.code == "decoder.video_hardware_unavailable" {
          throw YlHardwareDecoderEvidence.unavailable()
        }
        throw error
      }
      return pipeline
    }, discard: { $0.discardDecoder() })
    try token.throwIfCancelled()
    preparedVideo = pipeline
  }

  func takePreparedVideo() -> YlVideoPipeline? {
    defer { preparedVideo = nil }; return preparedVideo
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

  func prepareForLoad(positionMs: Int64, autoplay: Bool) throws {
    if positionMs > 0 {
      guard isSeekable, let openedMedia else {
        throw NativePlayerError(category: "source", code: "source.not_seekable", message: "The source cannot accept a start position.")
      }
      try openedMedia.seek(toMediaTimeUs: positionMs * 1_000)
    }
    resumeState = YlFallbackResumeState(positionUs: positionMs * 1_000, selectedAudioStreamIndex: nil, shouldPlay: autoplay)
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
    if resolved.positionUs > 0 || (resumeState?.positionUs ?? 0) > 0 {
      try openedMedia.seek(toMediaTimeUs: resolved.positionUs)
    }
    resumeState = resolved
  }

  func takeCancellationToken() -> YlOpenCancellationToken? {
    defer { cancellationToken = nil }
    return cancellationToken
  }

  func discard() {
    preparedVideo?.discardDecoder(); preparedVideo = nil
    cancellationToken?.cancel()
    cancellationToken = nil
    openedMedia?.close()
    openedMedia = nil
  }

  deinit {
    discard()
  }
}

func ylAACLCConfiguration(sampleRate: Int, channelCount: Int) -> Data? {
  let sampleRates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000,
                     24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
  guard let frequencyIndex = sampleRates.firstIndex(of: sampleRate),
        (1...7).contains(channelCount) else { return nil }
  let objectType = 2 // AAC Low Complexity
  return Data([
    UInt8((objectType << 3) | (frequencyIndex >> 1)),
    UInt8(((frequencyIndex & 1) << 7) | (channelCount << 3)),
  ])
}
