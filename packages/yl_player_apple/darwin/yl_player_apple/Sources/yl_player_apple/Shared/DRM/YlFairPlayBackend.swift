import yl_player_media_core
import AVFoundation
import CoreVideo
import Foundation

/// Protected media has no AVPlayerItemVideoOutput and cannot supply pixel buffers.
/// Every asset/key-session/player lifetime is main-thread owned.
final class YlFairPlayBackend: YlPlaybackBackend {
  let source: YlAppleSourceDescriptor
  let record: YlFairPlayViewRecord
  let events: YlAppleCommitEmitter
  private let bridge: YlFairPlayBridge
  private var player: AVPlayer?
  private var item: AVPlayerItem?
  private var keys: YlFairPlayKeySession?
  private var observations: [NSKeyValueObservation] = []
  private var timer: Any?
  private var endObserver: NSObjectProtocol?
  private var deadline: DispatchWorkItem?
  private let preparation = YlFairPlayPreparation()
  private var epoch: UInt64 = 0
  private var protectedAsset = false
  private var prepared = false
  private var disposed = false
  private var failure: NativePlayerError?
  private var desiredPosition: Int64
  private var speed: Float = 1
  private var volume: Float = 1
  private var ended = false
  private var pausedByCommand = false
  private(set) var isActive = false
  private(set) var playbackIntent: Bool
  var beforeAudioOutput: () throws -> Void = {}

  init(source: YlAppleSourceDescriptor, record: YlFairPlayViewRecord,
       bridge: YlFairPlayBridge, events: YlAppleCommitEmitter) {
    self.source = source; self.record = record; self.bridge = bridge; self.events = events
    desiredPosition = source.loadOptions?.startPositionMs ?? 0
    playbackIntent = source.loadOptions?.autoplay ?? false
    record.onFrame = { [weak self] frame in
      guard let self, self.isActive, self.keys?.isUsable == true else { return }
      self.bridge.frame(frame)
      self.events.accept(.init(generation: self.epoch,
        event: .firstFrame(width: nil, height: nil)))
    }
  }

  /// The open coordinator runs on its worker; wait there, never on Flutter's thread.
  static func prepare(source: YlAppleSourceDescriptor, identity: YlAppleSessionIdentity,
      bridge: YlFairPlayBridge, token: YlOpenCancellationToken,
      emit: @escaping (YlAppleSessionIdentity, YlNativeBackendCallback) -> Void) throws -> YlFairPlayBackend {
    let signal = DispatchSemaphore(value: 0)
    var result: Result<YlFairPlayBackend, NativePlayerError>?
    DispatchQueue.main.async {
      do {
        try token.throwIfCancelled()
        let id = try bridge.views.allocate(playerId: bridge.playerId, sessionId: identity.sessionId)
        let backend = YlFairPlayBackend(source: source, record: bridge.views.register(id), bridge: bridge,
          events: .init(identity: identity, emit: emit))
        token.onCancel { [weak backend] in
          DispatchQueue.main.async { backend?.dispose() }
        }
        backend.prepare { outcome in
          switch outcome {
          case .success: result = .success(backend)
          case .failure(let error): backend.dispose(); result = .failure(error)
          }
          signal.signal()
        }
      } catch let error as NativePlayerError { result = .failure(error); signal.signal() }
      catch { result = .failure(YlFairPlayFailure.error("drm.session_failed")); signal.signal() }
    }
    signal.wait()
    return try result!.get()
  }

  private func prepare(_ completion: @escaping (Result<Void, NativePlayerError>) -> Void) {
    guard !disposed, let config = source.drm, let url = source.url else {
      completion(.failure(YlFairPlayFailure.error("drm.config_invalid"))); return
    }
    guard preparation.begin(completion) else { return }
    epoch &+= 1
    let current = epoch
    failure = nil; protectedAsset = false; prepared = false
    let asset = AVURLAsset(url: url)
    do {
      let keys = try YlFairPlayKeySession(certificate: config.certificate, contentId: config.contentId,
        timeoutMs: config.timeoutMs,
        exchange: { [weak self] id, challenge, done in
          guard let self, !self.disposed, self.epoch == current else {
            done(.failure(YlFairPlayFailure.error("load.cancelled"))); return {}
          }
          return self.bridge.exchange(surface: self.record.identity, loadId: self.events.identity.loadRequestId,
            id: id, challenge: challenge, completion: done)
        }, onChange: { [weak self] in self?.changed(epoch: current) },
        onFailure: { [weak self] error in
          guard let self, self.epoch == current else { return }
          self.fail(error)
        })
      self.keys = keys
      // Register before metadata loading or creating the item.
      try keys.start(asset: asset)
      let player = AVPlayer()
      player.isMuted = true
      let item = AVPlayerItem(asset: asset)
      self.player = player; self.item = item
      player.replaceCurrentItem(with: item)
      observations = [item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.changed(epoch: current) }
      }, player.observe(\.isOutputObscuredDueToInsufficientExternalProtection, options: [.initial, .new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.changed(epoch: current) }
      }, player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async {
          guard let self, self.epoch == current else { return }
          self.emitState()
        }
      }]
      timer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 500, timescale: 1000), queue: .main) { [weak self] _ in
        self?.emitState()
      }
      endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
        object: item, queue: .main) { [weak self] _ in
          guard let self, self.epoch == current else { return }
          self.ended = true; self.playbackIntent = false; self.emitState()
        }
      asset.loadValuesAsynchronously(forKeys: ["hasProtectedContent", "playable"]) { [weak self, weak asset] in
        DispatchQueue.main.async {
          guard let self, let asset, self.epoch == current, !self.disposed else { return }
          guard asset.statusOfValue(forKey: "hasProtectedContent", error: nil) == .loaded,
                asset.statusOfValue(forKey: "playable", error: nil) == .loaded,
                asset.isPlayable, asset.hasProtectedContent else {
            self.fail(YlFairPlayFailure.error("drm.unsupported")); return
          }
          self.protectedAsset = true
          self.changed(epoch: current)
        }
      }
      let deadline = DispatchWorkItem { [weak self] in
        guard let self, self.epoch == current, !self.prepared else { return }
        self.fail(YlFairPlayFailure.error("drm.license_timeout"))
      }
      self.deadline = deadline
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(config.timeoutMs)), execute: deadline)
    } catch let error as NativePlayerError { fail(error) }
    catch { fail(YlFairPlayFailure.error("drm.session_failed")) }
  }

  private func changed(epoch: UInt64) {
    guard self.epoch == epoch, !disposed, failure == nil, let item else { return }
    if player?.isOutputObscuredDueToInsufficientExternalProtection == true {
      fail(YlFairPlayFailure.error("drm.protection_insufficient")); return
    }
    if item.status == .failed { fail(YlFairPlayFailure.error("drm.session_failed")); return }
    guard keys?.isUsable == true else {
      record.setPlayer(nil); player?.pause(); player?.isMuted = true
      emitState(); return
    }
    guard protectedAsset, item.status == .readyToPlay else { return }
    if !prepared {
      prepared = true
      deadline?.cancel(); deadline = nil
      if desiredPosition > 0 {
        player?.seek(to: CMTime(value: desiredPosition, timescale: 1000))
      }
      preparation.finish(.success(()))
    }
    if isActive {
      // Rebuild only on a key transition, not every playback-state observation.
      if record.layer?.player !== player { record.setPlayer(player) }
      do { try applyOutputIntent() } catch { fail(Self.safe(error)) }
    }
    emitState()
  }

  func activate() throws {
    guard !disposed, prepared, failure == nil, keys?.isUsable == true,
          player?.isOutputObscuredDueToInsufficientExternalProtection == false else {
      throw failure ?? YlFairPlayFailure.error("drm.session_failed")
    }
    if playbackIntent { try beforeAudioOutput() }
    if !isActive {
      isActive = true
      record.commit(); record.setPlayer(player)
    }
    try applyOutputIntent()
    emitState()
  }
  func restore(forcePlay: Bool, completion: @escaping (Result<Void, NativePlayerError>) -> Void) {
    if forcePlay { playbackIntent = true }
    if isActive {
      do { try applyOutputIntent(); completion(.success(())) }
      catch { completion(.failure(Self.safe(error))) }
      return
    }
    if prepared {
      do { try activate(); completion(.success(())) }
      catch { completion(.failure(Self.safe(error))) }
      return
    }
    prepare { [weak self] result in
      guard let self else { completion(.failure(YlFairPlayFailure.error("load.cancelled"))); return }
      do { try result.get(); try self.activate(); completion(.success(())) }
      catch { completion(.failure(Self.safe(error))) }
    }
  }
  private func applyOutputIntent() throws {
    guard isActive, keys?.isUsable == true else { return }
    player?.volume = volume
    if playbackIntent {
      try beforeAudioOutput()
      player?.isMuted = false; player?.playImmediately(atRate: speed)
    } else { player?.pause(); player?.isMuted = true }
  }
  func quiesceForReplacement() {
    // Keep the old key recipient available for synchronous rollback.
    isActive = false; record.setPlayer(nil); player?.isMuted = true; player?.pause()
    if preparation.isPending { releaseMedia() }
  }
  func deactivate() {
    if let value = player?.currentTime().seconds, value.isFinite { desiredPosition = max(0, Int64(value * 1000)) }
    isActive = false
    releaseMedia()
  }
  private func releaseMedia() {
    epoch &+= 1
    // Disconnect protected display and audio before expiring its recipient.
    record.setPlayer(nil)
    player?.isMuted = true; player?.pause()
    observations.removeAll()
    if let timer { player?.removeTimeObserver(timer) }; timer = nil
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }; endObserver = nil
    deadline?.cancel(); deadline = nil
    player?.replaceCurrentItem(with: nil); player = nil; item = nil
    keys?.close(); keys = nil; prepared = false
    preparation.finish(.failure(YlFairPlayFailure.error("load.cancelled")))
  }
  func stop() { playbackIntent = false; dispose() }
  func dispose() {
    guard !disposed else { return }
    disposed = true; isActive = false
    releaseMedia(); record.retire()
  }
  func fail(_ error: NativePlayerError) {
    guard !disposed, failure == nil else { return }
    failure = error
    let completion = preparation.take()
    let wasActive = isActive
    isActive = false; releaseMedia()
    completion?(.failure(error))
    if wasActive {
      emitState()
      events.accept(.init(generation: epoch, event: .failure(error)))
    }
  }
  func play() throws { pausedByCommand = false; playbackIntent = true; ended = false; try applyOutputIntent(); emitState() }
  func pause() throws { pausedByCommand = true; playbackIntent = false; try applyOutputIntent(); emitState() }
  func seek(toMs: Int64, cancellationToken: YlOpenCancellationToken?) throws {
    try cancellationToken?.throwIfCancelled()
    desiredPosition = toMs; ended = false
    player?.seek(to: CMTime(value: toMs, timescale: 1000))
  }
  func seekToLiveEdge() throws {
    guard let range = item?.seekableTimeRanges.last?.timeRangeValue else { throw YlAppleFailureMapper.unsupported }
    try seek(toMs: Int64(CMTimeRangeGetEnd(range).seconds * 1000), cancellationToken: nil)
  }
  func setPlaybackSpeed(_ speed: Float) throws { self.speed = speed; try applyOutputIntent() }
  func setVolume(_ volume: Float) throws { self.volume = volume; player?.volume = volume }
  func selectAudioTrack(_ trackId: String, cancellationToken: YlOpenCancellationToken?) throws {
    // No unverified catalog is advertised for protected variants.
    throw YlAppleFailureMapper.unsupported
  }
  func setVideoConstraints(_ constraints: YlAppleVideoConstraints) throws {
    guard constraints == .unconstrained else { throw YlAppleVideoConstraints.unsupportedOutput }
  }
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? { nil }
  var playbackStatus: String {
    return failure != nil ? "error" : ended ? "completed" : !playbackIntent ?
      (pausedByCommand ? "paused" : "ready") : !isActive ? "paused" :
      keys?.isUsable != true || player?.timeControlStatus == .waitingToPlayAtSpecifiedRate ? "buffering" : "playing"
  }
  func emitState() {
    guard prepared || failure != nil else { return }
    func ms(_ time: CMTime?) -> Int64? {
      guard let time, time.seconds.isFinite, time.seconds >= 0, time.seconds < Double(Int64.max) / 1000 else { return nil }
      return Int64(time.seconds * 1000)
    }
    let position = ms(player?.currentTime()) ?? desiredPosition
    let duration = ms(item?.duration)
    let live = source.isLive || duration == nil
    let ranges = item?.seekableTimeRanges ?? []
    let start = ranges.first.flatMap { ms($0.timeRangeValue.start) }
    let end = ranges.last.flatMap { ms(CMTimeRangeGetEnd($0.timeRangeValue)) }
    let buffered = item?.loadedTimeRanges.compactMap { ms(CMTimeRangeGetEnd($0.timeRangeValue)) }.max() ?? position
    let size = item?.presentationSize ?? .zero
    let state = YlNativeState(status: playbackStatus, positionMs: position, durationMs: duration,
      bufferedPositionMs: max(position, buffered), isLive: live, isSeekable: !ranges.isEmpty,
      isAtLiveEdge: live && end.map { $0 - position <= 3000 } == true,
      liveOffsetMs: live ? end.map { max(0, $0 - position) } : nil,
      dvrStartMs: live ? start : nil, dvrEndMs: live ? end : nil,
      videoWidth: size.width > 0 ? Int(size.width) : nil, videoHeight: size.height > 0 ? Int(size.height) : nil,
      engine: .avPlayer, isHardwareDecoding: false, decoderName: nil, audioTracks: [], videoTracks: [],
      metrics: .init(), error: failure)
    events.accept(.init(generation: epoch, event: .state(state)))
  }
  private static func safe(_ error: Error) -> NativePlayerError {
    (error as? NativePlayerError) ?? YlFairPlayFailure.error("drm.session_failed")
  }
}

/// Concurrent Play/resume commands share one native preparation. Taking the
/// callbacks before invoking them makes cleanup and reentrant requests independent.
final class YlFairPlayPreparation {
  typealias Completion = (Result<Void, NativePlayerError>) -> Void
  private var completions: [Completion] = []
  var isPending: Bool { !completions.isEmpty }
  func begin(_ completion: @escaping Completion) -> Bool {
    guard completions.count < 32 else {
      completion(.failure(YlFairPlayFailure.error("resource.exhausted"))); return false
    }
    let starts = completions.isEmpty
    completions.append(completion)
    return starts
  }
  func take() -> Completion? {
    guard !completions.isEmpty else { return nil }
    let callbacks = completions
    completions.removeAll()
    return { result in callbacks.forEach { $0(result) } }
  }
  func finish(_ result: Result<Void, NativePlayerError>) { take()?(result) }
}
