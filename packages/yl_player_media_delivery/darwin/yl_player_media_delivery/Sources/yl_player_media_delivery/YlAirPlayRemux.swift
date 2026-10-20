import yl_player_media_core
import AVFoundation
import AudioToolbox
import Foundation
import YlFFmpegBridge

/// Bounded, complete-VOD compressed remux. No decoder or encoder is created.
/// Only the first H.264 video and first AAC audio track are exported.
enum YlAirPlayRemux {
  static let maximumBytes = 512 * 1024 * 1024
  static let maximumPacketBytes = 8 * 1024 * 1024
  static let maximumSeconds: TimeInterval = 120

  static func prepare(input: YlMediaDeliveryInput,
                      token: YlOpenCancellationToken) throws -> YlDeliveredMedia {
    try token.throwIfCancelled()
    guard !input.isLive else { throw failure("unsupported_source", "Finite input is required.") }
    let recipe = input.recipe
    switch recipe {
    case .local(let path, _):
      let size = try URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size > 0, size <= maximumBytes else {
        throw failure("resource_limit", "The remux input exceeds the 512 MiB VOD limit.")
      }
    case .network: break
    default: throw failure("unsupported_source", "Finite file or HTTP input is required.")
    }
    let host = try YlAirPlayHTTPServer.lanIPv4Address()
    let operation = YlOpenCancellationToken()
    token.onCancel { [weak operation] in operation?.cancel() }
    let deadline = Date().addingTimeInterval(maximumSeconds)
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.schedule(deadline: .now() + maximumSeconds)
    timer.setEventHandler { [weak operation] in operation?.cancel() }
    timer.resume()
    defer { timer.cancel() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yl-airplay-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    var succeeded = false
    defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }
    do {
      let opened = try YlOpenedMedia(recipe: recipe, networkBufferBytes: 2 * 1024 * 1024,
        onSourceCreated: { input in operation.onCancel { [weak input] in input?.cancel() } })
      defer { opened.close() }
      opened.beginControlOperation(operation)
      operation.onCancel { [weak opened] in opened?.cancelInput() }
      guard opened.info.duration_us > 0, opened.info.duration_us <= 6 * 60 * 60 * 1_000_000,
            let context = opened.context else {
        throw failure("unsupported_source", "AirPlay remux requires a finite VOD duration of at most six hours.")
      }
      let segments = try remux(opened: opened, context: context, info: opened.info, directory: directory,
        token: operation, deadline: deadline)
      try operation.throwIfCancelled()
      let server = try YlAirPlayHTTPServer(directory: directory, files: segments, host: host)
      try operation.throwIfCancelled()
      succeeded = true
      return YlDeliveredMedia(url: server.url, cleanup: {
        server.stop(); try? FileManager.default.removeItem(at: directory)
      })
    } catch {
      if token.isCancelled { throw YlOpenCancellationToken.cancellationError() }
      if Date() >= deadline { throw failure("resource_limit", "AirPlay remux exceeded its 120 second preparation limit.") }
      throw error
    }
  }

  private static func remux(opened: YlOpenedMedia, context: YLFMediaContextRef, info: YLFMediaInfo, directory: URL,
                            token: YlOpenCancellationToken, deadline: Date) throws -> Set<String> {
    var video: YLFStreamInfo?
    var audio: YLFStreamInfo?
    for index in 0..<info.stream_count {
      var stream = YLFStreamInfo()
      guard ylf_copy_stream_info(context, index, &stream) == YLFResultOK else {
        throw failure("remux_failed", "The source track information could not be read.")
      }
      if stream.kind == YLFStreamVideo, video == nil { video = stream }
      if stream.kind == YLFStreamAudio, audio == nil { audio = stream }
    }
    guard let video, video.codec == YLFCodecH264,
          audio == nil || (audio?.codec ?? 0) == Int32(YLFCodecAAC) else {
      throw failure("unsupported_codec", "AirPlay remux supports H.264 video with optional AAC audio only.")
    }
    // Matroska often omits DTS, and demuxer-generated DTS can regress for
    // B-frames. A complete bounded VOD scan derives a monotonic decode clock
    // from the presentation timeline, preserving every original display time.
    let timeline = try scanVideoTimeline(context: context, stream: video.index,
      durationUs: info.duration_us, token: token, deadline: deadline)
    _ = try opened.seek(toMediaTimeUs: 0)
    var retainedVideoFormat: Unmanaged<CMVideoFormatDescription>?
    guard ylf_copy_video_format_description(context, video.index, &retainedVideoFormat) == YLFResultOK,
          let retainedVideoFormat else { throw failure("unsupported_codec", "The H.264 configuration is not suitable for AirPlay remux.") }
    let videoFormat = retainedVideoFormat.takeRetainedValue()
    let writer = AVAssetWriter(contentType: .mpeg4Movie)
    writer.outputFileTypeProfile = .mpeg4AppleHLS
    // Automatic segmentation forbids simultaneous video/audio passthrough.
    // Flush explicitly at demuxed video keyframes instead.
    writer.preferredOutputSegmentInterval = .indefinite
    writer.initialSegmentStartTime = .zero
    let collector = YlAirPlaySegmentCollector(directory: directory, maximumBytes: maximumBytes)
    writer.delegate = collector
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
    guard writer.canAdd(videoInput) else { throw failure("unsupported_codec", "AVFoundation cannot mux this H.264 track.") }
    writer.add(videoInput)
    var audioInput: AVAssetWriterInput?
    var audioFormat: CMAudioFormatDescription?
    if let audio {
      audioFormat = try makeAudioFormat(context: context, stream: audio)
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
      guard writer.canAdd(input) else { throw failure("unsupported_codec", "AVFoundation cannot mux this AAC track.") }
      writer.add(input)
      audioInput = input
    }
    guard writer.startWriting() else { throw failure("remux_failed", "The HLS writer could not start.", diagnostic: writer.error.map { String(describing: $0) }) }
    defer { if writer.status == .writing { writer.cancelWriting() } }
    writer.startSession(atSourceTime: .zero)
    var consumedBytes = 0
    var segmentBytes = 0
    var segmentStart: Int64 = 0
    var videoCount = 0
    var audioCount = 0
    var lastDTS: [Int32: Int64] = [:]
    while true {
      try token.throwIfCancelled()
      if Date() >= deadline { throw failure("resource_limit", "AirPlay remux preparation timed out.") }
      try collector.checkError()
      var packet: YLFPacketRef?
      let result = ylf_read_packet(context, &packet)
      if result == YLFResultEOF { break }
      guard result == YLFResultOK, let current = packet else { throw failure("remux_failed", "The source could not be fully read for AirPlay.") }
      defer { ylf_packet_release(&packet) }
      let size = ylf_packet_size(current)
      guard size > 0, size <= maximumPacketBytes, consumedBytes <= maximumBytes - size else {
        throw failure("resource_limit", "The AirPlay remux packet or total input exceeds its resource limit.")
      }
      consumedBytes += size
      let index = ylf_packet_stream_index(current)
      guard index == video.index || index == audio?.index else { continue }
      let pts = ylf_packet_pts_us(current)
      let dts = ylf_packet_dts_us(current)
      guard pts != Int64.min, pts >= -1_000_000, pts <= info.duration_us + 10_000_000 else {
        throw failure("unsupported_timeline", "The source has an unsupported AirPlay presentation timeline.")
      }
      let orderingTime: Int64
      if index == video.index {
        guard videoCount < timeline.presentation.count, pts == timeline.presentation[videoCount] else {
          throw failure("unsupported_timeline", "The source changed while preparing the AirPlay presentation.")
        }
        orderingTime = timeline.decode[videoCount]
      } else { orderingTime = dts == Int64.min ? pts : dts }
      if let previous = lastDTS[index], orderingTime <= previous {
        throw failure("unsupported_timeline", "The source has duplicate or non-monotonic audio timestamps.")
      }
      lastDTS[index] = orderingTime
      if index == video.index, videoCount > 0, ylf_packet_is_keyframe(current), pts - segmentStart >= 2_000_000 {
        writer.flushSegment()
        segmentStart = pts
        segmentBytes = 0
      }
      segmentBytes += size
      guard segmentBytes <= 32 * 1024 * 1024 else {
        throw failure("resource_limit", "A video keyframe interval exceeds the 32 MiB HLS segment limit.")
      }
      let input: AVAssetWriterInput
      let sample: CMSampleBuffer
      if index == video.index {
        guard videoCount != 0 || ylf_packet_is_keyframe(current) else {
          throw failure("unsupported_timeline", "AirPlay remux requires a video keyframe at the beginning.")
        }
        var buffer: Unmanaged<CMSampleBuffer>?
        guard ylf_create_video_sample_buffer(&packet, videoFormat, &buffer) == YLFResultOK, let buffer else {
          throw failure("remux_failed", "The H.264 compressed packet could not be packaged.")
        }
        input = videoInput
        let original = buffer.takeRetainedValue()
        do {
          var timing = CMSampleTimingInfo(duration: CMTime(value: timeline.durations[videoCount], timescale: 1_000_000),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(original),
            decodeTimeStamp: CMTime(value: orderingTime, timescale: 1_000_000))
          var adjusted: CMSampleBuffer?
          guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
            sampleBuffer: original, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleBufferOut: &adjusted) == noErr, let adjusted else {
            throw failure("remux_failed", "The initial decode timestamp could not be normalized.")
          }
          sample = adjusted
        }
        videoCount += 1
      } else {
        guard let audioFormat, let audioInput else { continue }
        input = audioInput
        sample = try makeAudioSample(packet: current, format: audioFormat)
        audioCount += 1
      }
      while !input.isReadyForMoreMediaData {
        try token.throwIfCancelled()
        try collector.checkError()
        guard writer.status == .writing, Date() < deadline else {
          throw failure("remux_failed", "The HLS writer stalled or rejected the compressed source.")
        }
        Thread.sleep(forTimeInterval: 0.002)
      }
      guard input.append(sample) else {
        throw failure("remux_failed", "AVFoundation rejected a compressed sample (stream \(index), PTS \(pts), DTS \(dts)).", diagnostic: writer.error.map { String(describing: $0) })
      }
    }
    guard videoCount > 0, audio == nil || audioCount > 0 else { throw failure("remux_failed", "The source contains an empty media track.") }
    videoInput.markAsFinished()
    audioInput?.markAsFinished()
    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting { finished.signal() }
    while finished.wait(timeout: .now() + 0.05) != .success {
      try token.throwIfCancelled()
      guard Date() < deadline else { throw failure("resource_limit", "The HLS writer exceeded its preparation deadline.") }
    }
    try collector.checkError()
    guard writer.status == .completed else {
      throw failure("remux_failed", "The HLS writer could not finalize the source.", diagnostic: writer.error.map { String(describing: $0) })
    }
    return try collector.finish()
  }

  private static func scanVideoTimeline(context: YLFMediaContextRef, stream: Int32,
      durationUs: Int64, token: YlOpenCancellationToken, deadline: Date) throws
      -> (presentation: [Int64], decode: [Int64], durations: [Int64]) {
    var presentation: [Int64] = []
    var bytes = 0
    var lastDuration: Int64 = 0
    while true {
      try token.throwIfCancelled()
      guard Date() < deadline else { throw failure("resource_limit", "AirPlay timeline inspection timed out.") }
      var packet: YLFPacketRef?
      let result = ylf_read_packet(context, &packet)
      if result == YLFResultEOF { break }
      guard result == YLFResultOK, let current = packet else {
        throw failure("remux_failed", "The complete source timeline could not be inspected.")
      }
      defer { ylf_packet_release(&packet) }
      let size = ylf_packet_size(current)
      guard size <= maximumPacketBytes, bytes <= maximumBytes - size else {
        throw failure("resource_limit", "AirPlay timeline inspection exceeded its input limit.")
      }
      bytes += size
      if ylf_packet_stream_index(current) == stream {
        let pts = ylf_packet_pts_us(current)
        guard pts >= 0, pts <= durationUs + 10_000_000, presentation.count < 500_000 else {
          throw failure("unsupported_timeline", "AirPlay requires a finite video timeline with at most 500,000 frames.")
        }
        presentation.append(pts)
        lastDuration = ylf_packet_duration_us(current)
      }
    }
    guard !presentation.isEmpty else { throw failure("remux_failed", "The source has no video packets.") }
    let sorted = presentation.sorted()
    var durations: [Int64] = []
    var delay: Int64 = 0
    for index in sorted.indices {
      delay = max(delay, sorted[index] - presentation[index])
      let duration = index + 1 < sorted.count ? sorted[index + 1] - sorted[index] : lastDuration
      guard duration > 0, duration <= 10_000_000 else {
        throw failure("unsupported_timeline", "The source has duplicate or invalid video presentation timestamps.")
      }
      durations.append(duration)
    }
    guard delay <= 10_000_000 else { throw failure("unsupported_timeline", "The video reorder delay exceeds the AirPlay remux limit.") }
    return (presentation, sorted.map { $0 - delay }, durations)
  }

  static func makeAudioFormat(context: YLFMediaContextRef, stream: YLFStreamInfo) throws -> CMAudioFormatDescription {
    let size = ylf_stream_codec_config_size(context, stream.index)
    guard size >= 2, size <= 4096 else {
      throw failure("unsupported_codec", "AirPlay remux requires mono or stereo AAC-LC with a valid AudioSpecificConfig.")
    }
    var cookie = [UInt8](repeating: 0, count: size)
    guard ylf_copy_stream_codec_config(context, stream.index, &cookie, size) == YLFResultOK,
          cookie[0] >> 3 == 2 else { throw failure("unsupported_codec", "Only AAC-LC audio can be remuxed for AirPlay.") }
    var bitOffset = 5
    func readBits(_ count: Int) -> Int? {
      guard bitOffset + count <= cookie.count * 8 else { return nil }
      var result = 0
      for _ in 0..<count {
        result = (result << 1) | Int((cookie[bitOffset / 8] >> (7 - bitOffset % 8)) & 1)
        bitOffset += 1
      }
      return result
    }
    let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
    let frequencyIndex = readBits(4) ?? -1
    let frequency = frequencyIndex == 15 ? readBits(24) : (rates.indices.contains(frequencyIndex) ? rates[frequencyIndex] : nil)
    let channels = readBits(4)
    let flags = readBits(3)
    guard let frequency, frequency > 0, frequency <= 96_000, let channels, (1...2).contains(channels), flags == 0 else {
      throw failure("unsupported_codec", "AirPlay AAC remux requires a standard 1024-frame AAC-LC configuration.", diagnostic: "frequency=\(String(describing: frequency))/\(stream.sample_rate) channels=\(String(describing: channels))/\(stream.channel_count) flags=\(String(describing: flags))")
    }
    if cookie.count * 8 - bitOffset >= 16, readBits(11) == 0x2b7 {
      guard readBits(5) == 5, readBits(1) == 0 else {
        throw failure("unsupported_codec", "HE-AAC extensions cannot be remuxed by this AirPlay path.")
      }
    }
    // Demux stream metadata may still contain container defaults (for example
    // 44.1 kHz stereo); the codec configuration defines the compressed audio.
    func descriptor(_ tag: UInt8, _ payload: [UInt8]) -> [UInt8] {
      [tag, UInt8((payload.count >> 21) & 0x7f) | 0x80,
       UInt8((payload.count >> 14) & 0x7f) | 0x80,
       UInt8((payload.count >> 7) & 0x7f) | 0x80, UInt8(payload.count & 0x7f)] + payload
    }
    let decoder = descriptor(0x04, [0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + descriptor(0x05, cookie))
    let magicCookie = descriptor(0x03, [0, 0, 0] + decoder + descriptor(0x06, [2]))
    var description = AudioStreamBasicDescription(mSampleRate: Double(frequency),
      mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 2, mBytesPerPacket: 0,
      mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
    var format: CMAudioFormatDescription?
    let status = magicCookie.withUnsafeBytes { bytes in
      CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
        layoutSize: 0, layout: nil, magicCookieSize: magicCookie.count, magicCookie: bytes.baseAddress,
        extensions: nil, formatDescriptionOut: &format)
    }
    guard status == noErr, let format else { throw failure("unsupported_codec", "AAC format description creation failed.") }
    return format
  }

  static func makeAudioSample(packet: YLFPacketRef, format: CMAudioFormatDescription) throws -> CMSampleBuffer {
    let size = ylf_packet_size(packet)
    guard let bytes = ylf_packet_data(packet) else { throw failure("remux_failed", "Empty AAC packet.") }
    // ADTS packets need a bitstream filter; reject rather than mux transport headers as AAC.
    guard size < 2 || !(bytes[0] == 0xff && bytes[1] & 0xf6 == 0xf0) else {
      throw failure("unsupported_codec", "ADTS AAC is not supported by the AirPlay remux path.")
    }
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
      blockLength: size, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
      offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &block) == noErr, let block,
      CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: size) == noErr else {
      throw failure("remux_failed", "AAC packet allocation failed.")
    }
    let sampleRate = Int32(CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee.mSampleRate)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1024, timescale: sampleRate),
      presentationTimeStamp: CMTime(value: ylf_packet_pts_us(packet), timescale: 1_000_000), decodeTimeStamp: .invalid)
    var sampleSize = size
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
      formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr, let sample else {
      throw failure("remux_failed", "AAC sample creation failed.")
    }
    return sample
  }

  static func failure(_ code: String, _ message: String, diagnostic: String? = nil) -> NativePlayerError {
    NativePlayerError(category: "unsupported", code: "airplay.\(code)", message: message, diagnostic: diagnostic)
  }
}

private final class YlAirPlaySegmentCollector: NSObject, AVAssetWriterDelegate {
  private let directory: URL
  private let maximumBytes: Int
  private let lock = NSLock()
  private var bytes = 0
  private var segments: [(String, Double)] = []
  private var files: Set<String> = []
  private var error: Error?

  init(directory: URL, maximumBytes: Int) { self.directory = directory; self.maximumBytes = maximumBytes }

  func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data,
                   segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
    lock.lock()
    defer { lock.unlock() }
    guard error == nil else { return }
    do {
      guard data.count <= maximumBytes - bytes else { throw YlAirPlayRemux.failure("resource_limit", "HLS output exceeds 512 MiB.") }
      let name: String
      if segmentType == .initialization { name = "init.mp4" }
      else {
        guard let report = segmentReport?.trackReports.first(where: { $0.mediaType == .video }),
              report.duration.seconds.isFinite, report.duration.seconds > 0,
              report.firstVideoSampleInformation?.isSyncSample == true else {
          throw YlAirPlayRemux.failure("unsupported_timeline", "HLS segment has no independent video timeline.")
        }
        name = "segment-\(segments.count).m4s"
        segments.append((name, report.duration.seconds))
      }
      try data.write(to: directory.appendingPathComponent(name), options: .atomic)
      bytes += data.count
      files.insert(name)
    } catch { self.error = error }
  }

  func checkError() throws { lock.lock(); defer { lock.unlock() }; if let error { throw error } }

  func finish() throws -> Set<String> {
    lock.lock()
    defer { lock.unlock() }
    if let error { throw error }
    guard files.contains("init.mp4"), !segments.isEmpty else { throw YlAirPlayRemux.failure("remux_failed", "The writer produced no HLS media.") }
    let target = Int(ceil(segments.map { $0.1 }.max()!))
    var playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"init.mp4\"\n"
    for (name, duration) in segments {
      playlist += String(format: "#EXTINF:%.6f,\n%@\n", locale: Locale(identifier: "en_US_POSIX"), duration, name)
    }
    playlist += "#EXT-X-ENDLIST\n"
    guard playlist.utf8.count <= maximumBytes - bytes else {
      throw YlAirPlayRemux.failure("resource_limit", "The HLS playlist exceeds the output disk budget.")
    }
    try Data(playlist.utf8).write(to: directory.appendingPathComponent("index.m3u8"), options: .atomic)
    files.insert("index.m3u8")
    return files
  }
}
