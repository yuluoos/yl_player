import yl_player_media_core
import AVFoundation
import CoreMedia
import Foundation

/// One decoder configuration epoch. Demux/conversion runs on its owner's worker;
/// VT callbacks and display use their own bounded scheduler/locks. Public session
/// identity is owned by the outer backend, never by an asynchronous codec callback.
final class YlDashPeriodPlayback {
  typealias Time = YlDashProgramTime
  let prepared: YlDashPreparedPeriod
  let generation: UInt64
  let scheduler = YlFrameScheduler(maxFrames: 8)
  let clock = YlMediaClock()
  let audio: YlAudioRenderer?
  let audioConverter: YlDashAudioTimeline?
  private(set) var video: (any YlVideoDecoderResource)!
  private let scope: YlManagedBufferScope
  private let outputWindow: YlDashProgramTimeline.Window
  private var nextVideo: YlDashTrackCursor.Item?
  private var nextAudio: YlDashTrackCursor.Item?
  private var videoEnded = false, audioEnded = false
  private let timingLock = NSLock()
  private struct DisplayTime { let start: Int64; let duration: Int64 }
  private var pendingTimes: [Int64: DisplayTime?] = [:]
  private var drainedVideo = false, drainedAudio = false
  private var decodedVideoEnd: Int64 = 0
  private var disposed = false
  private let onError: (NativePlayerError) -> Void

  init(prepared: YlDashPreparedPeriod, generation: UInt64, scope: YlManagedBufferScope,
       policy: YlDecoderPolicy, sharedLease: YlHardwareDecoderLease? = nil, videoFactory: (any YlVTSessionFactory)? = nil,
       audioOutput: (any YlAudioOutputDriving)? = nil,
       softwareServices: YlSoftwareDecodeServices = .init(),
       onError: @escaping (NativePlayerError) -> Void) throws {
    self.prepared = prepared; self.generation = generation; self.scope = scope; self.onError = onError
    outputWindow = .init(start: prepared.position, end: prepared.window.end)
    nextVideo = prepared.firstVideo; nextAudio = prepared.firstAudio
    if let first = prepared.firstAudio {
      let converter = YlDashAudioTimeline(window: outputWindow, scope: scope)
      let renderer = YlAudioRenderer(maxScheduledDurationUs: 500_000,
        maxScheduledBytes: 2 * 1024 * 1024, bufferScope: scope,
        converter: converter, output: audioOutput ?? YlSystemAudioOutput())
      let stream = first.source.stream
      let codec = YlAudioCodec(bridgeCodec: stream.codec)
      guard codec != .unsupported else { throw Self.invalid("unsupported audio codec") }
      try renderer.configure(stream: .init(codec: codec, sampleRate: Double(stream.sample_rate),
        channelCount: Int(stream.channel_count), magicCookie: first.source.codecConfiguration,
        generation: generation, channelMask: stream.channel_layout_mask))
      renderer.onOutputFailure = onError
      audio = renderer; audioConverter = converter
      clock.enableIsolatedAudioClock(read: { [weak self, weak renderer] generation in
        guard let self, let renderer else { return .invalid }
        let observation = renderer.clockObservation(expectedGeneration: generation)
        self.timingLock.lock(); let exhausted = self.drainedAudio; self.timingLock.unlock()
        // A seek can clip every decoded PCM frame. The renderer then has no
        // consumption anchor; only confirmed input EOF permits a silent tail.
        if exhausted, observation == .waiting, renderer.scheduledBytes == 0 {
          return .ended(positionUs: (try? self.prepared.position.converted(to: 1_000_000, rounding: .floor)) ?? 0,
            hostTimeUs: Self.now)
        }
        return observation
      }, generation: generation)
    } else { audio = nil; audioConverter = nil; audioEnded = true }
    scheduler.flush(generation: generation)
    clock.seek(to: try prepared.position.converted(to: 1_000_000, rounding: .floor))
    let format = prepared.firstVideo.source.videoFormat!
    video = try YlVideoDecoderSelection.choose(policy: policy, hardware: {
      try YlVideoToolboxDecoder(formatDescription: format,
        maxInFlightBytes: 4 * 1024 * 1024, bufferScope: scope,
        factory: videoFactory ?? YlHardwareVTSessionFactory(policy: .hardwareRequired), sharedLease: sharedLease,
        onFrame: { [weak self] in self?.receive($0) }, onError: onError)
    }, software: {
      let budget = YlFallbackBufferBudget(bufferScope: scope, networkBytes: 4 * 1024 * 1024,
        scheduledAudioBytes: 2 * 1024 * 1024, inFlightPacketBytes: 4 * 1024 * 1024)
      return try softwareServices.make(configuration: prepared.firstVideo.source.softwareConfiguration,
        format: format, budget: budget, onFrame: { [weak self] in self?.receive($0) }, onError: onError)
    })
  }

  /// A bounded pump quantum; only its owning worker calls this method.
  func pump(cancellation: YlOpenCancellationToken) throws {
    for _ in 0..<32 {
      try cancellation.throwIfCancelled()
      var progress = false
      let position = clock.position(atHostTimeUs: Self.now)
      if let audio, let audioConverter {
        if let submission = try audioConverter.nextSubmission() {
          switch try audio.enqueue(packet: submission) {
          case .scheduled, .buffered: progress = true
          case .staleGeneration: throw YlOpenCancellationToken.cancellationError()
          case .wouldExceedBytes, .wouldExceedDuration: break
          }
        } else if !audioEnded, let item = nextAudio,
          // Decode one future packet when the queue is empty to establish a
          // known gap. PCM silence then advances it in bounded output quanta.
          (try !audio.hasPendingPlayback || item.pts >= outputWindow.end || item.pts <= Time(position, 1_000_000).adding(Time(1, 2))) {
          guard let original = prepared.firstAudio,
                item.source.stream.codec == original.source.stream.codec,
                item.source.stream.sample_rate == original.source.stream.sample_rate,
                item.source.stream.channel_count == original.source.stream.channel_count,
                item.source.codecConfiguration == original.source.codecConfiguration else { throw Self.invalid("audio configuration") }
          let bytes = try item.packet.audioBytes()
          let reservation = try scope.require(category: .compressedPackets, bytes: bytes.count)
          let packet = try YlCompressedAudioPacket(reservation: reservation, data: bytes,
            ptsUs: item.pts.converted(to: 1_000_000, rounding: .floor),
            durationUs: item.packet.duration.converted(to: 1_000_000, rounding: .ceil), generation: generation)
          try audioConverter.decode(packet, pts: item.pts)
          nextAudio = try prepared.audio?.next(); progress = true
          if nextAudio == nil { audioEnded = true }
        }
        timingLock.lock(); let alreadyDrained = drainedAudio; timingLock.unlock()
        if audioEnded && !audioConverter.hasPendingOutput && !alreadyDrained {
          audio.finishInput()
          timingLock.lock(); drainedAudio = true; timingLock.unlock()
        }
      }
      timingLock.lock(); let pendingCount = pendingTimes.count; timingLock.unlock()
      if !videoEnded, let item = nextVideo, scheduler.pendingPTS.count < 4, pendingCount < 4,
         (try scheduler.pendingPTS.isEmpty && pendingCount == 0 ||
           (item.dts ?? item.pts) <= Time(position, 1_000_000).adding(Time(1, 4))) {
        guard let format = item.source.videoFormat,
              CMFormatDescriptionEqual(format, otherFormatDescription: prepared.firstVideo.source.videoFormat!) else { throw Self.invalid("video configuration") }
        let interval = try YlDashSampleWindow.intersection(pts: item.pts, duration: item.packet.duration, window: outputWindow)
        let pts = try Self.cmTime(item.pts)
        let key = CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value
        let display: DisplayTime?
        if let interval {
          let start = try interval.start.converted(to: 1_000_000, rounding: .ceil)
          let end = try interval.end.converted(to: 1_000_000, rounding: .floor)
          display = .init(start: start, duration: max(0, end - start))
        } else { display = nil }
        timingLock.lock()
        if pendingTimes.keys.contains(key) { timingLock.unlock(); throw Self.invalid("duplicate presentation time") }
        pendingTimes[key] = .some(display); timingLock.unlock()
        let sample = try item.packet.videoSample(format: format, pts: pts,
          dts: item.dts.map(Self.cmTime) ?? .invalid, duration: Self.cmTime(item.packet.duration))
        guard let reservation = try video.reserve(byteCount: item.packet.byteCount,
          shouldCancel: { cancellation.isCancelled }) else { throw YlOpenCancellationToken.cancellationError() }
        video.decode(sample: sample, generation: generation, reservation: reservation)
        nextVideo = try prepared.video.next(); progress = true
        if nextVideo == nil {
          videoEnded = true; video.drain()
          timingLock.lock(); drainedVideo = true; timingLock.unlock()
        }
      }
      if !progress { return }
    }
  }

  /// True only after every video callback has drained; no fabricated frame is
  /// needed to start a declared blank tail after a seek beyond available media.
  var videoInputDrained: Bool {
    timingLock.lock(); defer { timingLock.unlock() }; return drainedVideo && pendingTimes.isEmpty
  }

  /// Highest admitted decoded frame end. EOF separately authorizes declared
  /// blank tails; an unfinished network read never counts as known coverage.
  var videoCoverageEnd: Int64 {
    timingLock.lock(); defer { timingLock.unlock() }
    return max(decodedVideoEnd, (try? prepared.position.converted(to: 1_000_000, rounding: .floor)) ?? 0)
  }

  private func receive(_ frame: YlVideoFrame) {
    timingLock.lock()
    let value = pendingTimes.removeValue(forKey: frame.ptsUs)
    let accepted = !disposed && frame.generation == generation
    timingLock.unlock()
    guard accepted, let wrapped = value, let display = wrapped else { return }
    let admitted = scheduler.enqueue(.init(reservation: frame.reservation, payload: frame.pixelBuffer,
      ptsUs: display.start, durationUs: display.duration, keyframe: frame.keyframe, generation: generation))
    if admitted {
      timingLock.lock(); decodedVideoEnd = max(decodedVideoEnd, display.start + display.duration); timingLock.unlock()
    }
  }
  func play() throws { try audio?.play(); clock.play(atHostTimeUs: Self.now) }
  func pause() { clock.pause(atHostTimeUs: Self.now); audio?.pause() }
  func setRate(_ rate: Float) {
    audio?.setRate(rate); clock.setRate(Double(rate), atHostTimeUs: Self.now); scheduler.setRate(Double(rate))
  }
  func setVolume(_ volume: Float) { audio?.setVolume(volume) }
  func dispose() {
    timingLock.lock(); let already = disposed; disposed = true; timingLock.unlock()
    guard !already else { return }
    scheduler.dispose(); clock.stopIsolatedAudioClock(); video?.dispose(); audio?.dispose()
    nextVideo = nil; nextAudio = nil
    timingLock.lock(); pendingTimes.removeAll(); timingLock.unlock()
  }
  deinit { dispose() }
  static var now: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1_000_000) }
  static func cmTime(_ time: Time) throws -> CMTime {
    if let scale = Int32(exactly: time.denominator) { return CMTime(value: time.numerator, timescale: scale) }
    return CMTime(value: try time.converted(to: 1_000_000_000, rounding: .floor), timescale: 1_000_000_000)
  }
  private static func invalid(_ reason: String) -> NativePlayerError {
    NativePlayerError(category: "decoder", code: "decoder.dash_reconfiguration_required",
      message: "The DASH sample changed outside a declared Period boundary (\(reason)).")
  }
}
