import AVFoundation
import Foundation
import YlFFmpegBridge

/// Sequential compressed live input. The returned media owns this worker; the
/// worker never owns the media, and its lifetime is independent of the load token.
enum YlAirPlayLiveRemux {
  static let startupSeconds: TimeInterval = 45

  static func prepare(source: YlAppleSourceDescriptor, configuration: PlayerConfiguration,
                      token: YlOpenCancellationToken,
                      rtmpSourceFactory: ((YlRtmpRequestRecipe) -> YlRtmpByteSource)? = nil) throws -> YlAirPlayPreparedMedia {
    try token.throwIfCancelled()
    guard source.kind == .network, source.drm == nil, let url = source.url else {
      throw YlAirPlayRemux.failure("unsupported_source", "Live AirPlay requires an unprotected network FLV or RTMP source.")
    }
    let scope = try source.bufferScope ?? YlManagedBufferLedger().makeScope(maxBytes: nil)
    let recipe: YlFallbackSourceRecipe
    if ["rtmp", "rtmps"].contains(url.scheme?.lowercased() ?? "") {
      recipe = .rtmp(request: YlRtmpRequestRecipe(address: try YlRtmpAddress.validate(source),
        recovery: source.rtmpRecovery, bufferScope: scope))
    } else {
      guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            source.intent != .onDemand,
            source.formatHint == .flv || url.pathExtension.lowercased() == "flv" else {
        throw YlAirPlayRemux.failure("unsupported_source", "Live AirPlay accepts HTTP-FLV, RTMP and RTMPS only.")
      }
      let network = source.networkConfiguration.map(YlNetworkConfiguration.init(options:)) ?? configuration.network
      // The producer owns the complete three-attempt recovery budget. A byte
      // source cannot resume a partially read live stream or spend extra retries.
      let boundedNetwork = YlNetworkConfiguration(map: [
        "connectTimeoutMs": min(max(network.connectTimeoutMs, 1_000), 15_000),
        "readTimeoutMs": min(max(network.readTimeoutMs, 1_000), 15_000),
        "maxRetries": 0, "maxRedirects": network.maxRedirects])
      recipe = .network(request: YlNetworkRequestRecipe(url: url, headers: source.headers,
        credentials: source.credentials, credentialContext: source.credentialContext,
        configuration: boundedNetwork, mode: .sequentialLive,
        managedIntent: source.networkPolicy == .managed ? source.managedRequestIntent : nil,
        bufferScope: scope), container: .flv)
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yl-airplay-live-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    var started = false
    do {
      let store = try YlAirPlayLiveStore(directory: directory)
      let server = try YlAirPlayHTTPServer(host: YlAirPlayHTTPServer.lanIPv4Address(), resolver: store.resolve)
      let worker = YlAirPlayLiveWorker(recipe: recipe, store: store, server: server, directory: directory,
        rtmpSourceFactory: rtmpSourceFactory)
      token.onCancel { [weak worker] in worker?.cancelPreparation() }
      worker.start(); started = true
      do { try worker.waitUntilReady(token: token) }
      catch { worker.stop(); throw error }
      return YlAirPlayPreparedMedia(url: server.url, cleanup: { worker.stop() },
        observeFailure: { callback in worker.observeFailure(callback) })
    } catch {
      // A started worker retires its own directory after all writes finish.
      // Removing here is safe only when construction failed before it started.
      if !started {
        try? FileManager.default.removeItem(at: directory)
      }
      throw error
    }
  }
}

private final class YlAirPlayLiveWorker {
  private let rtmpSourceFactory: ((YlRtmpRequestRecipe) -> YlRtmpByteSource)?
  private let recipe: YlFallbackSourceRecipe
  private let store: YlAirPlayLiveStore
  private let server: YlAirPlayHTTPServer
  private let directory: URL
  private let queue = DispatchQueue(label: "dev.yl.airplay.live", qos: .userInitiated)
  private let lock = NSLock()
  private let lifetime = YlOpenCancellationToken()
  private let wake = DispatchSemaphore(value: 0)
  private var preparing = true
  private var stopped = false
  private var terminal: NativePlayerError?
  private var observer: ((NativePlayerError) -> Void)?

  init(recipe: YlFallbackSourceRecipe, store: YlAirPlayLiveStore,
       server: YlAirPlayHTTPServer, directory: URL,
       rtmpSourceFactory: ((YlRtmpRequestRecipe) -> YlRtmpByteSource)?) {
    self.rtmpSourceFactory = rtmpSourceFactory
    self.recipe = recipe; self.store = store; self.server = server; self.directory = directory
  }

  func start() { queue.async { self.run() } }

  func cancelPreparation() {
    stop(onlyPreparation: true)
  }

  func waitUntilReady(token: YlOpenCancellationToken) throws {
    let deadline = Date().addingTimeInterval(YlAirPlayLiveRemux.startupSeconds)
    while true {
      try token.throwIfCancelled()
      lock.lock()
      let failure = terminal
      let cancelled = stopped
      if failure == nil, !cancelled, store.isReady, !token.isCancelled {
        preparing = false
        lock.unlock()
        return
      }
      lock.unlock()
      if let failure { throw failure }
      if cancelled { throw YlOpenCancellationToken.cancellationError() }
      guard Date() < deadline else {
        throw YlAirPlayRemux.failure("resource_limit", "Live AirPlay did not produce its initial 18 second window within 45 seconds.")
      }
      _ = wake.wait(timeout: .now() + 0.05)
    }
  }

  func observeFailure(_ callback: @escaping (NativePlayerError) -> Void) {
    lock.lock(); observer = callback; let error = stopped ? nil : terminal; lock.unlock()
    if let error { callback(error) }
  }

  func stop(onlyPreparation: Bool = false) {
    lock.lock()
    guard !stopped, !onlyPreparation || preparing else { lock.unlock(); return }
    stopped = true; observer = nil
    lock.unlock()
    lifetime.cancel(); wake.signal(); server.stop()
    // Serial retirement follows the read/mux loop. Collector deactivation also
    // fences AVAssetWriter delegate callbacks before the directory is removed.
    queue.async { try? FileManager.default.removeItem(at: self.directory) }
  }

  private func run() {
    do {
      var retries = 0
      while true {
        try lifetime.throwIfCancelled()
        do {
          try producePeriod()
        } catch let error as NativePlayerError {
          try lifetime.throwIfCancelled()
          guard Self.isTransient(error) else { throw error }
          guard retries < 3 else {
            throw NativePlayerError(category: "network", code: "network.retry_exhausted",
              message: "Live AirPlay could not reconnect after three attempts.", diagnostic: error.code)
          }
          let delay = [0.5, 1.0, 2.0][retries]; retries += 1
          _ = wake.wait(timeout: .now() + delay)
        }
      }
    } catch {
      if lifetime.isCancelled { return }
      let failure = error as? NativePlayerError ?? YlAirPlayRemux.failure("remux_failed", "Live AirPlay output failed.", diagnostic: String(describing: type(of: error)))
      lock.lock(); terminal = failure; let callback = stopped ? nil : observer; lock.unlock()
      wake.signal()
      callback?(failure)
    }
  }

  private static func isTransient(_ error: NativePlayerError) -> Bool {
    if error.code == "network.http_status", let diagnostic = error.diagnostic {
      if ["transport.-1001", "transport.-1004", "transport.-1005", "transport.-1009"].contains(diagnostic) { return true }
      if diagnostic.hasPrefix("HTTP "), let status = Int(diagnostic.dropFirst(5)) {
        return YlNetworkRequestPolicy.isRetryableStatus(status)
      }
    }
    return ["airplay.live_eof", "network.rtmp_handshake_failed", "network.rtmp_disconnected",
     "network.connect_timeout", "network.read_timeout", "network.connection_lost",
     "network.connection_failed", "network.dns_failed"].contains(error.code)
  }

  private func producePeriod() throws {
    let opened = try YlOpenedMedia(recipe: recipe, networkBufferBytes: 2 * 1024 * 1024,
      onSourceCreated: { [lifetime] input in lifetime.onCancel { [weak input] in input?.cancel() } },
      byteSourceTransform: { YlAirPlayFLVValidator(source: $0) }, rtmpSourceFactory: rtmpSourceFactory)
    defer { opened.close() }
    opened.beginControlOperation(lifetime)
    guard let context = opened.context else { throw YlAirPlayRemux.failure("remux_failed", "Live input did not open.") }
    var video: YLFStreamInfo?
    var audio: YLFStreamInfo?
    for index in 0..<opened.info.stream_count {
      var stream = YLFStreamInfo()
      guard ylf_copy_stream_info(context, index, &stream) == YLFResultOK else { throw YlAirPlayRemux.failure("remux_failed", "Live track inspection failed.") }
      if stream.kind == YLFStreamVideo, video == nil { video = stream }
      if stream.kind == YLFStreamAudio, audio == nil { audio = stream }
    }
    guard let video, video.codec == YLFCodecH264,
          audio == nil || audio?.codec == Int32(YLFCodecAAC) else {
      throw YlAirPlayRemux.failure("unsupported_codec", "Live AirPlay requires H.264 with optional AAC-LC audio.")
    }
    var retainedFormat: Unmanaged<CMVideoFormatDescription>?
    guard ylf_copy_video_format_description(context, video.index, &retainedFormat) == YLFResultOK,
          let retainedFormat else { throw YlAirPlayRemux.failure("unsupported_codec", "Invalid live H.264 configuration.") }
    let videoFormat = retainedFormat.takeRetainedValue()
    let videoConfig = try Self.codecConfig(context, stream: video.index)
    let audioConfig = try audio.map { try Self.codecConfig(context, stream: $0.index) }
    let writer = AVAssetWriter(contentType: .mpeg4Movie)
    writer.outputFileTypeProfile = .mpeg4AppleHLS
    writer.preferredOutputSegmentInterval = .indefinite
    writer.initialSegmentStartTime = .zero
    let collector = YlAirPlayLiveCollector(store: store)
    writer.delegate = collector
    defer { collector.deactivate(); if writer.status == .writing { writer.cancelWriting() } }
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
    videoInput.expectsMediaDataInRealTime = true
    guard writer.canAdd(videoInput) else { throw YlAirPlayRemux.failure("unsupported_codec", "The live H.264 track cannot be muxed.") }
    writer.add(videoInput)
    var audioInput: AVAssetWriterInput?
    var audioFormat: CMAudioFormatDescription?
    if let audio {
      audioFormat = try YlAirPlayRemux.makeAudioFormat(context: context, stream: audio)
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
      input.expectsMediaDataInRealTime = true
      guard writer.canAdd(input) else { throw YlAirPlayRemux.failure("unsupported_codec", "The live AAC track cannot be muxed.") }
      writer.add(input); audioInput = input
    }
    guard writer.startWriting() else { throw YlAirPlayRemux.failure("remux_failed", "Live HLS writer failed to start.") }
    writer.startSession(atSourceTime: .zero)
    var origin: Int64?
    var segmentStart: Int64 = 0
    var segmentBytes = 0
    var skippedBytes = 0
    let keyframeDeadline = Date().addingTimeInterval(10)
    var lastDTS: [Int32: Int64] = [:]
    while true {
      try lifetime.throwIfCancelled()
      try collector.checkError()
      var packet: YLFPacketRef?
      let result = ylf_read_packet(context, &packet)
      defer { ylf_packet_release(&packet) }
      guard result == YLFResultOK, let current = packet else {
        if let error = opened.lastInputError { throw error }
        if result == YLFResultEOF {
          throw NativePlayerError(category: "network", code: "airplay.live_eof", message: "The live input disconnected.")
        }
        throw YlAirPlayRemux.failure("remux_failed", "Live FLV input could not be read.", diagnostic: "bridge=\(result)")
      }
      let size = ylf_packet_size(current)
      guard size > 0, size <= 8 * 1024 * 1024 else { throw YlAirPlayRemux.failure("resource_limit", "A live packet exceeds 8 MiB.") }
      let index = ylf_packet_stream_index(current)
      guard index == video.index || index == audio?.index else { continue }
      guard try Self.codecConfig(context, stream: index) == (index == video.index ? videoConfig : audioConfig!) else {
        throw YlAirPlayRemux.failure("unsupported_codec", "The live codec configuration changed within an HLS period.")
      }
      let pts = ylf_packet_pts_us(current), dts = ylf_packet_dts_us(current)
      guard pts != Int64.min, dts != Int64.min, pts >= 0, dts >= 0,
            pts < Int64.max / 4, dts < Int64.max / 4, abs(pts - dts) <= 6_000_000 else {
        throw YlAirPlayRemux.failure("unsupported_timeline", "Live FLV requires valid bounded PTS and DTS.")
      }
      let keyframe = index == video.index && ylf_packet_is_keyframe(current)
      if origin == nil {
        if !keyframe {
          skippedBytes += size
          guard skippedBytes <= 32 * 1024 * 1024, Date() < keyframeDeadline else {
            throw YlAirPlayRemux.failure("resource_limit", "Live input did not provide an initial keyframe within its bounds.")
          }
          continue
        }
        guard Self.containsIDR(current, config: videoConfig) else { throw YlAirPlayRemux.failure("unsupported_codec", "Live H.264 must begin on an IDR frame.") }
        origin = min(pts, dts); segmentStart = dts
      }
      let base = origin!
      // Audio preceding the first retained video keyframe is intentionally omitted.
      if index != video.index, pts < base { continue }
      guard pts >= base, dts >= base else { throw YlAirPlayRemux.failure("unsupported_timeline", "Live timestamps moved before the current period.") }
      if let previous = lastDTS[index], dts <= previous || dts - previous > 6_000_000 {
        throw YlAirPlayRemux.failure("unsupported_timeline", "Live decode timestamps regressed or jumped.")
      }
      lastDTS[index] = dts
      if let audio {
        let other = index == video.index ? audio.index : video.index
        guard abs(dts - (lastDTS[other] ?? base)) <= 6_000_000 else {
          throw YlAirPlayRemux.failure("unsupported_timeline", "Live audio and video drifted more than six seconds apart.")
        }
      }
      if index == video.index {
        guard dts - segmentStart <= 6_000_000 else { throw YlAirPlayRemux.failure("resource_limit", "Live video keyframe spacing exceeds six seconds.") }
        if keyframe, dts - segmentStart >= 2_000_000 {
          guard Self.containsIDR(current, config: videoConfig) else { throw YlAirPlayRemux.failure("unsupported_codec", "HLS segment boundaries require H.264 IDR frames.") }
          // Keep at most three flushed GOPs waiting for writer callbacks, plus
          // the current bounded GOP. Backpressure prevents a fast source from
          // building an unlimited compressed queue inside AVAssetWriter.
          let flushDeadline = Date().addingTimeInterval(5)
          while collector.pendingFlushes >= 3 {
            try lifetime.throwIfCancelled(); try collector.checkError()
            guard writer.status == .writing, Date() < flushDeadline else {
              throw YlAirPlayRemux.failure("resource_limit", "Live fragment output did not drain within five seconds.")
            }
            Thread.sleep(forTimeInterval: 0.002)
          }
          collector.willFlush()
          writer.flushSegment(); segmentStart = dts; segmentBytes = 0
        }
      }
      segmentBytes += size
      guard segmentBytes <= 32 * 1024 * 1024 else { throw YlAirPlayRemux.failure("resource_limit", "A live HLS segment exceeds 32 MiB.") }
      let original: CMSampleBuffer
      let input: AVAssetWriterInput
      if index == video.index {
        var retained: Unmanaged<CMSampleBuffer>?
        guard ylf_create_video_sample_buffer(&packet, videoFormat, &retained) == YLFResultOK, let retained else {
          throw YlAirPlayRemux.failure("remux_failed", "Live H.264 sample packaging failed.")
        }
        original = retained.takeRetainedValue(); input = videoInput
      } else {
        guard let audioInput, let audioFormat else { continue }
        original = try YlAirPlayRemux.makeAudioSample(packet: current, format: audioFormat); input = audioInput
      }
      var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(original),
        presentationTimeStamp: CMTime(value: pts - base, timescale: 1_000_000),
        decodeTimeStamp: index == video.index ? CMTime(value: dts - base, timescale: 1_000_000) : .invalid)
      var adjusted: CMSampleBuffer?
      guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: original,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &adjusted) == noErr, let adjusted else {
        throw YlAirPlayRemux.failure("remux_failed", "Live period timestamp normalization failed.")
      }
      let writeDeadline = Date().addingTimeInterval(5)
      while !input.isReadyForMoreMediaData {
        try lifetime.throwIfCancelled(); try collector.checkError()
        guard writer.status == .writing, Date() < writeDeadline else { throw YlAirPlayRemux.failure("remux_failed", "The live HLS writer stalled.") }
        Thread.sleep(forTimeInterval: 0.002)
      }
      guard input.append(adjusted) else { throw YlAirPlayRemux.failure("remux_failed", "The live HLS writer rejected a compressed sample.", diagnostic: writer.error.map { String(describing: $0) }) }
    }
  }

  private static func codecConfig(_ context: YLFMediaContextRef, stream: Int32) throws -> [UInt8] {
    let count = ylf_stream_codec_config_size(context, stream)
    guard count > 0, count <= 64 * 1024 else { throw YlAirPlayRemux.failure("unsupported_codec", "Live codec configuration is missing or too large.") }
    var bytes = [UInt8](repeating: 0, count: count)
    guard ylf_copy_stream_codec_config(context, stream, &bytes, count) == YLFResultOK else { throw YlAirPlayRemux.failure("unsupported_codec", "Live codec configuration cannot be read.") }
    return bytes
  }

  private static func containsIDR(_ packet: YLFPacketRef, config: [UInt8]) -> Bool {
    guard config.count >= 5, config[0] == 1, let bytes = ylf_packet_data(packet) else { return false }
    let lengthBytes = Int(config[4] & 3) + 1, count = ylf_packet_size(packet)
    var offset = 0, idr = false
    while offset < count {
      guard count - offset >= lengthBytes else { return false }
      var length = 0
      for index in 0..<lengthBytes { length = (length << 8) | Int(bytes[offset + index]) }
      offset += lengthBytes
      guard length > 0, length <= count - offset else { return false }
      if bytes[offset] & 0x1f == 5 { idr = true }
      offset += length
    }
    return idr
  }
}

private final class YlAirPlayLiveCollector: NSObject, AVAssetWriterDelegate {
  private let store: YlAirPlayLiveStore
  private let lock = NSLock()
  private var period: Int?
  private var error: Error?
  private var active = true
  private var flushed = 0
  init(store: YlAirPlayLiveStore) { self.store = store }

  var pendingFlushes: Int { lock.lock(); defer { lock.unlock() }; return flushed }
  func willFlush() { lock.lock(); flushed += 1; lock.unlock() }
  func deactivate() { lock.lock(); active = false; lock.unlock() }
  func checkError() throws {
    lock.lock(); let failure = error; lock.unlock()
    if let failure { throw failure }
    try store.checkError()
  }
  func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data,
                   segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
    lock.lock(); defer { lock.unlock() }
    guard active, error == nil else { return }
    do {
      if segmentType == .initialization {
        guard period == nil else { throw YlAirPlayRemux.failure("remux_failed", "Duplicate initialization in a live HLS period.") }
        period = try store.beginPeriod(initialization: data)
      } else {
        guard let period,
              let video = segmentReport?.trackReports.first(where: { $0.mediaType == .video }),
              video.firstVideoSampleInformation?.isSyncSample == true else {
          throw YlAirPlayRemux.failure("unsupported_timeline", "Live HLS fragment is not independently decodable.")
        }
        try store.append(data: data, duration: video.duration.seconds, period: period)
        flushed = max(0, flushed - 1)
      }
    } catch { self.error = error }
  }
}

/// The bridge intentionally exposes stream configuration, not AVPacket side
/// data. FLV can put changed sequence headers only in packet side data, leaving
/// that stream configuration unchanged. Observe the original byte stream so a
/// mid-period change is rejected before FFmpeg or AVFoundation consumes it.
/// Media payload is never copied here; retained parser/config bytes stay <192 KiB.
final class YlAirPlayFLVValidator: YlByteSource {
  private let source: YlByteSource
  private enum Phase { case header, extraHeader, previousSize, tagHeader, payload }
  private var phase = Phase.header
  private var small: [UInt8] = []
  private var remaining = 9
  private var previousSize = 0
  private var tagType = 0
  private var prefixLength = 0
  private var prefix: [UInt8] = []
  private var configuration: [UInt8]?
  private var videoConfiguration: [UInt8]?
  private var audioConfiguration: [UInt8]?

  init(source: YlByteSource) { self.source = source }
  var length: Int64? { source.length }
  var supportsRandomAccess: Bool { false }
  var currentOffset: Int64 { source.currentOffset }
  func seek(to offset: Int64) throws -> Int64 {
    guard offset == currentOffset else {
      throw YlByteSourceError.failed(NativePlayerError(category: "source", code: "source.not_seekable",
        message: "Live FLV validation requires sequential input."))
    }
    return offset
  }
  func cancel() { source.cancel() }
  func interruptRead() { source.interruptRead() }
  func resumeReads() { source.resumeReads() }
  func handleMemoryWarning() { source.handleMemoryWarning() }

  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    let count = try source.read(into: buffer)
    guard count > 0 else { return count }
    do { try consume(UnsafeRawBufferPointer(rebasing: buffer[..<count])) }
    catch let error as NativePlayerError { throw YlByteSourceError.failed(error) }
    return count
  }

  private func consume(_ bytes: UnsafeRawBufferPointer) throws {
    var offset = 0
    while offset < bytes.count {
      if phase == .payload {
        if prefix.count < prefixLength {
          let count = min(prefixLength - prefix.count, bytes.count - offset)
          prefix.append(contentsOf: bytes[offset..<(offset + count)])
          offset += count; remaining -= count
          if prefix.count == prefixLength {
            if tagType == 9 {
              guard prefix[0] & 0x0f == 7, prefix[1] <= 2 else { throw unsupported("Live FLV changed to an unsupported video codec.") }
            } else if tagType == 8 {
              guard prefix[0] >> 4 == 10, prefix[1] <= 1 else { throw unsupported("Live FLV changed to an unsupported audio codec.") }
            }
            if prefix[1] == 0 {
              guard remaining > 0, remaining <= 64 * 1024 else { throw unsupported("Live FLV sequence header exceeds 64 KiB or is empty.") }
              configuration = []
            }
          }
        } else {
          let count = min(remaining, bytes.count - offset)
          if configuration != nil { configuration!.append(contentsOf: bytes[offset..<(offset + count)]) }
          offset += count; remaining -= count
        }
        if remaining == 0 {
          if let configuration {
            if tagType == 9 {
              if let videoConfiguration, videoConfiguration != configuration { throw unsupported("Live H.264 configuration changed within the connection.") }
              videoConfiguration = configuration
            } else {
              if let audioConfiguration, audioConfiguration != configuration { throw unsupported("Live AAC configuration changed within the connection.") }
              audioConfiguration = configuration
            }
          }
          phase = .previousSize; remaining = 4; small.removeAll(keepingCapacity: true)
        }
      } else if phase == .extraHeader {
        let count = min(remaining, bytes.count - offset)
        offset += count; remaining -= count
        if remaining == 0 { phase = .previousSize; remaining = 4 }
      } else {
        let count = min(remaining, bytes.count - offset)
        small.append(contentsOf: bytes[offset..<(offset + count)])
        offset += count; remaining -= count
        if remaining > 0 { continue }
        switch phase {
        case .header:
          guard Array(small[0..<3]) == [0x46, 0x4c, 0x56], small[3] == 1, small[4] & ~5 == 0 else { throw malformed() }
          let size = integer(small[5..<9])
          guard (9...4096).contains(size) else { throw malformed() }
          phase = size == 9 ? .previousSize : .extraHeader
          remaining = size == 9 ? 4 : size - 9
        case .previousSize:
          guard integer(small[0..<4]) == previousSize else { throw malformed() }
          phase = .tagHeader; remaining = 11
        case .tagHeader:
          tagType = Int(small[0])
          let size = integer(small[1..<4])
          guard [8, 9, 18].contains(tagType), small[8...10].allSatisfy({ $0 == 0 }) else { throw malformed() }
          guard size <= 8 * 1024 * 1024 else { throw YlAirPlayRemux.failure("resource_limit", "A live FLV tag exceeds 8 MiB.") }
          prefixLength = tagType == 9 ? 5 : tagType == 8 ? 2 : 0
          guard size >= max(1, prefixLength) else { throw malformed() }
          previousSize = 11 + size; remaining = size; phase = .payload
          prefix.removeAll(keepingCapacity: true); configuration = nil
        default: break
        }
        small.removeAll(keepingCapacity: true)
      }
    }
  }

  private func integer(_ bytes: ArraySlice<UInt8>) -> Int { bytes.reduce(0) { ($0 << 8) | Int($1) } }
  private func unsupported(_ message: String) -> NativePlayerError { YlAirPlayRemux.failure("unsupported_codec", message) }
  private func malformed() -> NativePlayerError { YlAirPlayRemux.failure("unsupported_source", "The live input is not a structurally valid FLV stream.") }
}
