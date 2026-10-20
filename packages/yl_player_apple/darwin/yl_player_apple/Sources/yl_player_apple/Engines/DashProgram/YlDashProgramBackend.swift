import yl_player_media_core
import CoreVideo
import Foundation

/// Optional scalar-only evidence. Audio observations describe native consumption,
/// not microphone/physical output; video observations accompany actual publication.
enum YlDashPlaybackObservation {
  case video(Int64, UInt64)
  case audio(YlAudioClockSample)
  /// Accepted Period index and candidate preparation/commit wait in milliseconds.
  case period(Int, Int64)
}

/// A single public programme session with private Period/command generations.
/// Preparation and demux have separate queues so a seek can prepare while an old
/// network read is pending. Only a fully prepared candidate changes selection.
final class YlDashProgramBackend: YlPlaybackBackend {
  typealias Time = YlDashProgramTime
  private let lock = NSRecursiveLock()
  private let worker = DispatchQueue(label: "dev.ylplayer.dash.demux", qos: .userInitiated)
  private let preparation = DispatchQueue(label: "dev.ylplayer.dash.prepare", qos: .userInitiated)
  private let workerKey = DispatchSpecificKey<Bool>()
  private let preparationKey = DispatchSpecificKey<Bool>()
  private var decoderLease: YlHardwareDecoderLease?
  private let prepared: YlPreparedDashProgram
  private let services: YlPlatformServices
  private let emit: (YlNativeBackendCallback) -> Void
  private let observe: ((YlDashPlaybackObservation) -> Void)?
  private let channelGeneration: UInt64
  private let loadRequestId: String?
  private var pipeline: YlDashPeriodPlayback?
  private var initialPeriod: YlDashPreparedPeriod?
  private var token: YlOpenCancellationToken
  private var pendingToken: YlOpenCancellationToken?
  private var epoch: UInt64 = 1, command: UInt64 = 0
  private var active = false, stopped = false, disposed = false, playing = false
  private var completed = false, transitioning = false
  private var outputRunning = false, pausedByCommand = false
  private var constraints: YlAppleVideoConstraints
  private var selection = YlNativeVideoSelection()
  /// Session intent survives pipeline retirement for restoration/end seeks.
  /// Failed preparation must never replace the last committed video family.
  private var acceptedVideoFamily: String?
  private var explicitAudio: String?
  private var rate: Float = 1, volume: Float = 1
  private var frozenPosition: Int64 = 0
  private var gapClock: YlMediaClock?
  private var frame: YlFrameEnvelope?
  private var failure: NativePlayerError?
  private var lastStateAt: Int64 = 0
  private var firstFrameSent = false
  private lazy var display = services.makeDisplayDriver { [weak self] in self?.tick() }
  private var displayCreated = false

  init(prepared: YlPreparedDashProgram, services: YlPlatformServices,
       generation: UInt64, loadRequestId: String?,
       observe: ((YlDashPlaybackObservation) -> Void)? = nil,
       emit: @escaping (YlNativeBackendCallback) -> Void) throws {
    self.prepared = prepared; self.services = services; self.channelGeneration = generation
    self.loadRequestId = loadRequestId; self.observe = observe; self.emit = emit
    constraints = prepared.constraints; token = prepared.cancellation; playing = prepared.autoplay
    worker.setSpecific(key: workerKey, value: true)
    preparation.setSpecific(key: preparationKey, value: true)
    initialPeriod = try prepared.takeInitial()
    frozenPosition = try prepared.position.converted(to: 1_000_000, rounding: .floor)
    completed = initialPeriod == nil
    if let initialPeriod, prepared.position < initialPeriod.window.start {
      let clock = YlMediaClock(); clock.seek(to: frozenPosition); gapClock = clock
    }
  }
  var isActive: Bool { locked { active && !disposed } }
  var videoSelection: YlNativeVideoSelection { locked { selection } }
  var playbackIntent: Bool { locked { playing } }
  var requiresAsyncActivation: Bool { locked { pipeline == nil && initialPeriod == nil && !completed && !stopped && !disposed } }
  var requiresExternalRollbackActivation: Bool { requiresAsyncActivation }
  func needsAsyncActivation(forcePlay: Bool) -> Bool {
    requiresAsyncActivation || locked { forcePlay && completed && !disposed && !stopped }
  }
  /// Restores the accepted programme on the command worker before main activation.
  func prepareActivation(positionMs: Int64?, constraints: YlAppleVideoConstraints, forcePlay: Bool = false,
                         cancellation: YlOpenCancellationToken) throws {
    let position = locked { positionMs.map { min($0, Int64.max / 1000) * 1000 } ?? (forcePlay && completed ? 0 : frozenPosition) }
    try replace(at: Time(position, 1_000_000), cancellation: cancellation, caps: constraints)
  }
  func reportRestorationFailure(_ error: NativePlayerError) { fail(error, epoch: locked { epoch }) }
  func requiresAsyncCommand(_ value: YlApplePlaybackCommand) -> Bool {
    switch value {
    case .seek, .track, .constraints, .videoTrack: return true
    case .play: return locked { completed }
    default: return false
    }
  }

  func activate() throws {
    let activation = locked { () -> (Bool, Bool) in
      guard !disposed, !stopped, !active else { return (false, false) }
      active = true; return (true, pipeline == nil && initialPeriod == nil && !completed)
    }
    guard activation.0 else { return }
    let restore = activation.1
    if let initial = locked({ initialPeriod }) {
      let candidate = try makePipeline(initial, epoch: locked { epoch })
      locked {
        pipeline = candidate; initialPeriod = nil
        if !candidate.video.usesHardwareDecoder { decoderLease = nil }
        acceptedVideoFamily = candidate.prepared.qualityFamily
      }
      candidate.setRate(locked { rate }); candidate.setVolume(locked { volume })
    }
    displayCreated = true; display.isPaused = false
    if restore {
      let position = locked { frozenPosition }
      preparation.async { [weak self] in self?.restore(at: position) }
    } else {
      if locked({ playing }) { try startOutput() }
      schedulePump()
    }
    publish(.engineActivated(.managedFallback)); emitState()
  }
  func play() throws { try play(cancellationToken: nil) }
  func play(cancellationToken: YlOpenCancellationToken?) throws {
    try cancellationToken?.throwIfCancelled()
    guard locked({ !disposed && !stopped }) else { return }
    try services.beforeAudioOutput(); try services.activateAudioSession()
    locked { playing = true; pausedByCommand = false }
    if !isActive { try activate(); return }
    if locked({ completed }) { try seek(toMs: 0, cancellationToken: cancellationToken); return }
    try startOutput(); emitState()
  }
  func pause() throws {
    let current = locked { () -> YlDashPeriodPlayback? in playing = false; pausedByCommand = true; outputRunning = false; gapClock?.pause(atHostTimeUs: now); return pipeline }
    current?.pause(); emitState()
  }
  func seek(toMs: Int64, cancellationToken: YlOpenCancellationToken?) throws {
    guard toMs >= 0 else { throw Self.invalidCommand() }
    let position = min(toMs, try prepared.program.timeline.duration.converted(to: 1000, rounding: .ceil))
    try replace(at: Time(position, 1000), cancellation: cancellationToken)
  }
  func seekToLiveEdge() throws { throw Self.invalidCommand() }
  func selectAudioTrack(_ trackId: String, cancellationToken: YlOpenCancellationToken?) throws {
    let position = locked { positionLocked() }
    try replace(at: Time(position, 1_000_000), cancellation: cancellationToken, audio: trackId)
  }
  func setVideoConstraints(_ value: YlAppleVideoConstraints) throws {
    try updateVideoConstraints(value, cancellationToken: nil)
  }
  func updateVideoConstraints(_ value: YlAppleVideoConstraints, cancellationToken: YlOpenCancellationToken?) throws {
    _ = try YlFallbackQualityConstraint(validating: value)
    if locked({ constraints == value }) { return }
    let position = locked { positionLocked() }
    try replace(at: Time(position, 1_000_000), cancellation: cancellationToken, caps: value)
  }
  func selectVideoTrack(_ id: String?, cancellationToken: YlOpenCancellationToken?) throws {
    let position = try locked { () throws -> Int64 in
      if let id {
        guard let current = pipeline,
              prepared.program.periods[current.prepared.index].tracks.contains(where: { $0.kind == .video && $0.id == id }) else { throw YlNativeVideoSelection.unsupported }
      }
      return positionLocked()
    }
    try replace(at: Time(position, 1_000_000), cancellation: cancellationToken,
      video: .init(fixedTrackId: id, reason: "user"))
  }
  func setPlaybackSpeed(_ value: Float) throws {
    guard value.isFinite, (0.25...4).contains(value) else { throw Self.invalidCommand() }
    let current = locked { () -> YlDashPeriodPlayback? in rate = value; gapClock?.setRate(Double(value), atHostTimeUs: now); return pipeline }
    current?.setRate(value); emitState()
  }
  func setVolume(_ value: Float) throws {
    guard value.isFinite, (0...1).contains(value) else { throw Self.invalidCommand() }
    let current = locked { () -> YlDashPeriodPlayback? in volume = value; return pipeline }
    current?.setVolume(value)
  }

  private func makePipeline(_ candidate: YlDashPreparedPeriod, epoch: UInt64) throws -> YlDashPeriodPlayback {
    let lease = try locked { () throws -> YlHardwareDecoderLease? in
      guard !disposed, !stopped else { throw YlOpenCancellationToken.cancellationError() }
      if decoderLease == nil && services.compatibility.limitsVideoReservations {
        do { decoderLease = try YlHardwareDecoderLeasePool.shared.acquire() }
        catch let error as NativePlayerError where error.code == "resource.video_decoder_limit" && prepared.decoderPolicy != .hardwareRequired {
          // The hardware attempt still enforces its own permit. An admitted
          // software candidate must not require an unused hardware permit.
          return nil
        }
      }
      return decoderLease
    }
    do {
      return try YlDashPeriodPlayback(prepared: candidate, generation: epoch, scope: prepared.scope,
        policy: prepared.decoderPolicy, sharedLease: lease, softwareServices: prepared.softwareServices, onError: { [weak self] error in self?.fail(error, epoch: epoch) })
    } catch let error as NativePlayerError where prepared.decoderPolicy == .hardwareRequired &&
      ["decoder.video_hardware_unavailable", "resource.video_decoder_limit"].contains(error.code) {
      throw YlHardwareDecoderEvidence.unavailable()
    }
  }
  private func replace(at position: Time, cancellation: YlOpenCancellationToken?,
                       audio: String? = nil, caps: YlAppleVideoConstraints? = nil,
                       video: YlNativeVideoSelection? = nil, expectedEpoch: UInt64? = nil) throws {
    if DispatchQueue.getSpecific(key: preparationKey) != true {
      return try preparation.sync { try replace(at: position, cancellation: cancellation,
        audio: audio, caps: caps, video: video, expectedEpoch: expectedEpoch) }
    }
    let startedAt = now
    let target = min(position, prepared.program.timeline.duration)
    let newToken = YlOpenCancellationToken()
    cancellation?.onCancel { [weak newToken] in newToken?.cancel() }
    let context = try locked { () throws -> (UInt64, UInt64, YlAppleVideoConstraints, YlNativeVideoSelection, String?, String?, String?) in
      guard !disposed, !stopped, expectedEpoch == nil || expectedEpoch == epoch else { throw YlOpenCancellationToken.cancellationError() }
      pendingToken?.cancel(); pendingToken = newToken; command &+= 1
      return (command, epoch &+ 1, caps ?? constraints, video ?? selection,
        audio ?? explicitAudio, pipeline?.prepared.audio?.track.id, acceptedVideoFamily)
    }
    defer { locked { if pendingToken === newToken { pendingToken = nil } } }
    try newToken.throwIfCancelled()
    let index = prepared.program.timeline.locate(time: target)
      ?? prepared.program.timeline.windows.firstIndex { $0.start > target }
    let candidate: YlDashPeriodPlayback?
    do {
      if let index {
        let descriptor = try YlDashPreparedPeriod(program: prepared.program, index: index, position: target,
          constraints: context.2, selection: context.3, explicitAudio: context.4, preferredAudio: context.5,
          qualityFamily: video?.fixedTrackId != nil ? nil : context.6,
          resources: prepared.resources, cancellation: newToken, scope: prepared.scope)
        candidate = try makePipeline(descriptor, epoch: context.1)
      } else { candidate = nil }
    } catch { newToken.cancel(); throw error }
    var committed = false
    defer {
      if !committed {
        newToken.cancel(); candidate?.dispose()
        locked { if pipeline?.video.usesHardwareDecoder != true { decoderLease = nil } }
      }
    }
    try newToken.throwIfCancelled()
    let old = try locked { () throws -> YlDashPeriodPlayback? in
      guard !disposed, !stopped, command == context.0 else { throw YlOpenCancellationToken.cancellationError() }
      return pipeline
    }
    old?.pause()
    defer {
      if !committed, locked({ pipeline === old && active && playing && !disposed && !stopped }) { try? old?.play() }
    }
    try locked {
      guard !disposed, !stopped, command == context.0, pipeline === old else { throw YlOpenCancellationToken.cancellationError() }
      try newToken.throwIfCancelled()
      token.cancel()
      pipeline = candidate; token = newToken; epoch = context.1
      if let candidate { acceptedVideoFamily = candidate.prepared.qualityFamily }
      constraints = context.2; selection = candidate?.prepared.selection ?? context.3; explicitAudio = context.4
      frozenPosition = try target.converted(to: 1_000_000, rounding: .floor)
      failure = nil; transitioning = false; completed = candidate == nil; outputRunning = false
      frame = nil; gapClock = nil
      if let candidate, target < candidate.prepared.window.start {
        let gap = YlMediaClock(); gap.seek(to: frozenPosition); gap.setRate(Double(rate), atHostTimeUs: now)
        if active && playing { gap.play(atHostTimeUs: now) }; gapClock = gap
      }
      committed = true
    }
    worker.sync { old?.dispose() }
    locked { if pipeline?.video.usesHardwareDecoder != true { decoderLease = nil } }
    onMain { [weak self] in
      guard let self, self.locked({ self.epoch == context.1 && !self.disposed }) else { return }
      self.services.textureOutput.clear()
      candidate?.setRate(self.locked { self.rate }); candidate?.setVolume(self.locked { self.volume })
      if self.locked({ self.active && self.playing && self.gapClock == nil }) {
        do { try self.startOutput() } catch { self.fail(Self.native(error), epoch: context.1) }
      }
      if let index { self.observe?(.period(index, max(0, self.now - startedAt) / 1000)) }
      self.emitState()
    }
    schedulePump()
  }
  private func restore(at position: Int64) {
    do { try replace(at: Time(position, 1_000_000), cancellation: nil) }
    catch { fail(Self.native(error), epoch: locked { epoch }) }
  }
  private func startOutput() throws {
    let value = locked { () -> YlDashPeriodPlayback? in
      guard active, playing, !disposed, !stopped, !completed, !outputRunning else { return nil }
      if let gapClock { gapClock.play(atHostTimeUs: now); outputRunning = true; return nil }
      guard let pipeline else { return nil }
      if pipeline.audio == nil && !pipeline.videoInputDrained && pipeline.videoCoverageEnd <= pipeline.clock.position(atHostTimeUs: now) { return nil }
      // Keep the native clock paused until the seek/preroll has produced a
      // visible frame. The first displayed sample must not be dropped simply
      // because codec startup consumed wall time before presentation began.
      guard frame != nil || pipeline.videoInputDrained || !pipeline.scheduler.pendingPTS.isEmpty || pipeline.prepared.firstVideo.pts > pipeline.prepared.position else { return nil }
      outputRunning = true
      return pipeline
    }
    do { try value?.play() }
    catch { locked { outputRunning = false }; throw error }
  }
  private func schedulePump() {
    let expected = locked { epoch }
    worker.async { [weak self] in self?.pump(epoch: expected) }
  }
  private func pump(epoch expected: UInt64) {
    let value = locked { () -> (YlDashPeriodPlayback, YlOpenCancellationToken)? in
      guard epoch == expected, active, !disposed, !stopped, failure == nil, let pipeline else { return nil }
      return (pipeline, token)
    }
    guard let (current, token) = value else { return }
    do { try current.pump(cancellation: token) }
    catch { fail(Self.native(error), epoch: expected); return }
    worker.asyncAfter(deadline: .now() + 0.01) { [weak self] in self?.pump(epoch: expected) }
  }

  /// Display callback runs on the platform's presentation thread (main).
  private func tick() {
    let snapshot = locked { () -> (YlDashPeriodPlayback?, Int64, UInt64, Bool)? in
      guard active, !disposed, !stopped, failure == nil, !completed else { return nil }
      let position = positionLocked()
      if let gapClock, let pipeline,
         position >= (try? pipeline.prepared.window.start.converted(to: 1_000_000, rounding: .floor)) ?? .max {
        gapClock.pause(atHostTimeUs: now); self.gapClock = nil
        outputRunning = false
      }
      return (pipeline, positionLocked(), epoch, gapClock != nil)
    }
    guard let (current, position, expected, inGap) = snapshot else { return }
    if let current, !inGap {
      if current.audio == nil && !current.videoInputDrained && current.clock.position(atHostTimeUs: now) >= current.videoCoverageEnd {
        current.pause(); current.clock.seek(to: current.videoCoverageEnd)
        locked { if epoch == expected { outputRunning = false } }
      }
      let expired = locked { () -> Bool in
        guard epoch == expected, let frame, position >= frame.ptsUs + frame.durationUs else { return false }
        self.frame = nil; return true
      }
      if expired { services.textureOutput.clear() }
      if position >= (try? current.prepared.window.end.converted(to: 1_000_000, rounding: .floor)) ?? .max {
        finishPeriod(current, epoch: expected); return
      }
      if let next = current.scheduler.frame(at: position, generation: expected), position < next.ptsUs + next.durationUs {
        let buffer = next.payload as! CVPixelBuffer
        let publishFrame = locked { () -> Bool in
          guard epoch == expected, active, !disposed else { return false }
          frame = next; return true
        }
        if publishFrame {
          services.textureOutput.resize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
          ylPublishVideoFrame(buffer, retaining: next.reservation, to: services.textureOutput)
          observe?(.video(next.ptsUs, expected))
          if !firstFrameSent {
            firstFrameSent = true
            publish(.firstFrame(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
          }
        }
      }
      if let audio = current.audio, case .running(let sample) = audio.clockObservation(expectedGeneration: expected) { observe?(.audio(sample)) }
    }
    do { try startOutput() } catch { fail(Self.native(error), epoch: expected); return }
    if now - lastStateAt >= 100_000 { lastStateAt = now; emitState() }
  }
  private func finishPeriod(_ current: YlDashPeriodPlayback, epoch expected: UInt64) {
    let target: Time? = locked {
      guard epoch == expected, !transitioning, !completed else { return nil }
      outputRunning = false; frame = nil; frozenPosition = (try? current.prepared.window.end.converted(to: 1_000_000, rounding: .floor)) ?? frozenPosition
      if current.prepared.index + 1 == prepared.program.periods.count { completed = true; return nil }
      transitioning = true; return current.prepared.window.end
    }
    current.pause(); services.textureOutput.clear(); emitState()
    if let target {
      preparation.async { [weak self] in
        guard let self else { return }
        do { try self.replace(at: target, cancellation: nil, expectedEpoch: expected) }
        catch { self.fail(Self.native(error), epoch: expected) }
      }
    }
  }
  func emitState() {
    let value = locked { () -> YlNativeState in
      let current = pipeline?.prepared
      let position = positionLocked()
      let tracks = current.map { prepared.program.periods[$0.index].tracks } ?? []
      let videoTrack = current?.video.track
      let geometry = stopped || gapClock != nil ? nil : current?.firstVideo.source.videoFormat.flatMap {
        YlVideoGeometryResolver.managed(format: $0)
      }
      let videoTracks = tracks.filter { $0.kind == .video }.map {
        YlNativeTrack(id: $0.id, kind: .video, codec: $0.codec, bitrate: Int($0.bandwidth),
          width: Int($0.width), height: Int($0.height), isSelected: $0.id == videoTrack?.id)
      }
      let audioTracks = tracks.filter { $0.kind == .audio }.map {
        YlNativeTrack(id: $0.id, kind: .audio, label: $0.roles.isEmpty ? nil : $0.roles.joined(separator: ","), language: $0.language,
          codec: $0.codec, isSelected: $0.id == current?.audio?.track.id)
      }
      let status = stopped ? "idle" : failure != nil ? "error" : completed ? "completed" : (transitioning || (playing && !outputRunning)) ? "buffering" : playing ? "playing" : pausedByCommand ? "paused" : "ready"
      return YlNativeState(status: status, positionMs: position / 1000,
        durationMs: try? prepared.program.timeline.duration.converted(to: 1000, rounding: .ceil),
        bufferedPositionMs: (pipeline?.scheduler.pendingPTS.last ?? position) / 1000,
        isLive: false, isSeekable: !stopped, isAtLiveEdge: false, liveOffsetMs: nil, dvrStartMs: nil, dvrEndMs: nil,
        videoWidth: videoTrack.map { Int($0.width) }, videoHeight: videoTrack.map { Int($0.height) },
        engine: .managedFallback, isHardwareDecoding: pipeline?.video.usesHardwareDecoder ?? false,
        decoderName: stopped ? nil : pipeline?.video.hardwareEvidence.decoderName, audioTracks: stopped ? [] : audioTracks, videoTracks: stopped ? [] : videoTracks,
        metrics: .init(networkBytesReceived: prepared.scope.networkBytesReceived, bufferedDurationMs: (pipeline?.scheduler.bufferedDurationUs ?? 0) / 1000,
          bufferedBytes: prepared.scope.ledger.snapshot.currentBytes,
          droppedVideoFrames: pipeline?.scheduler.lateFrameDropCount, audioUnderruns: pipeline?.audio?.underrunCount),
        error: failure, decoderEvidence: pipeline?.video.hardwareEvidence, geometry: geometry, videoSelection: selection)
    }
    publish(.state(value))
  }
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    locked { guard active, !disposed, !stopped, let frame else { return nil }; return .passRetained(frame.payload as! CVPixelBuffer) }
  }
  func deactivate() { retire(stop: false, dispose: false) }
  func stop() { retire(stop: true, dispose: false); emitState() }
  func dispose() { retire(stop: true, dispose: true) }
  private func retire(stop: Bool, dispose: Bool) {
    let old = locked { () -> YlDashPeriodPlayback? in
      guard !disposed else { return nil }
      frozenPosition = stop ? 0 : positionLocked(); active = false; outputRunning = false; stopped = stopped || stop; disposed = dispose
      pendingToken?.cancel(); pendingToken = nil; token.cancel(); command &+= 1; epoch &+= 1
      let old = pipeline; pipeline = nil; initialPeriod = nil; gapClock?.stopIsolatedAudioClock(); gapClock = nil; frame = nil
      return old
    }
    if DispatchQueue.getSpecific(key: workerKey) == true { old?.dispose() }
    else { worker.sync { old?.dispose() } }
    locked { decoderLease = nil }
    onMain { [weak self] in
      guard let self else { return }
      if self.displayCreated { self.display.isPaused = true; if dispose { self.display.invalidate() } }
      self.services.textureOutput.clear()
    }
  }
  private func fail(_ error: NativePlayerError, epoch expected: UInt64) {
    let accepted = locked { () -> Bool in
      guard epoch == expected, !disposed, !stopped, failure == nil else { return false }
      failure = error; return true
    }
    if accepted {
      let current = locked { pipeline }; current?.pause()
      publish(.failure(error)); emitState()
    }
  }
  private func positionLocked() -> Int64 {
    if transitioning || completed || pipeline == nil { return frozenPosition }
    if let gapClock { return gapClock.position(atHostTimeUs: now) }
    let current = pipeline!, value = current.clock.position(atHostTimeUs: now)
    return current.audio == nil && !current.videoInputDrained ? min(value, current.videoCoverageEnd) : value
  }
  private var now: Int64 { YlDashPeriodPlayback.now }
  private func locked<T>(_ operation: () throws -> T) rethrows -> T {
    lock.lock(); defer { lock.unlock() }; return try operation()
  }
  private func publish(_ event: YlNativeBackendEvent) {
    let expected = locked { epoch }
    onMain { [weak self] in
      guard let self, self.locked({ self.epoch == expected && !self.disposed }) else { return }
      self.emit(.init(generation: self.channelGeneration, loadRequestId: self.loadRequestId, event: event))
    }
  }
  private func onMain(_ operation: @escaping () -> Void) {
    if Thread.isMainThread { operation() } else { DispatchQueue.main.async(execute: operation) }
  }
  private static func native(_ error: Error) -> NativePlayerError {
    (error as? NativePlayerError) ?? NativePlayerError(category: "decoder", code: "decoder.dash_failed", message: "The DASH programme could not prepare its next playback window.")
  }
  private static func invalidCommand() -> NativePlayerError {
    NativePlayerError(category: "source", code: "source.not_seekable", message: "The DASH programme does not support this command value.")
  }
}
