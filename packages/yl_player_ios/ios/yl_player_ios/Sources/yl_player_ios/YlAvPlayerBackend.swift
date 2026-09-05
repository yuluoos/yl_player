import AVFoundation
import CoreVideo
import Flutter
import QuartzCore
import UIKit

final class YlAvPlayerStallWatchdog {
  typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

  private enum Phase: String {
    case firstFrame
    case rebuffer
  }

  private let schedule: Scheduler
  private var generation: UInt64 = 0
  private var armedPhase: Phase?

  init(_ schedule: @escaping Scheduler = { delay, action in
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
  }) {
    self.schedule = schedule
  }

  func update(
    active: Bool,
    wantsToPlay: Bool,
    hasCurrentItem: Bool,
    isWaiting: Bool,
    firstFrameSent: Bool,
    timeoutMs: Int64,
    waitingReason: String?,
    onTimeout: @escaping (NativePlayerError) -> Void
  ) {
    guard active, wantsToPlay, hasCurrentItem else {
      cancel()
      return
    }

    let phase: Phase
    let code: String
    let message: String
    if !firstFrameSent {
      phase = .firstFrame
      code = "avplayer.first_frame_timeout"
      message = "AVPlayer did not render the first frame before the read timeout."
    } else if isWaiting {
      phase = .rebuffer
      code = "avplayer.stall_timeout"
      message = "AVPlayer remained stalled beyond the read timeout."
    } else {
      cancel()
      return
    }
    guard armedPhase != phase else { return }

    generation &+= 1
    let scheduledGeneration = generation
    armedPhase = phase

    let timeout = max(0, timeoutMs)
    let reason = waitingReason?.isEmpty == false ? waitingReason ?? "none" : "none"
    let error = NativePlayerError(
      category: "network",
      code: code,
      message: message,
      diagnostic: "AVPlayer(phase=\(phase.rawValue), timeoutMs=\(timeout), waitingReason=\(reason))"
    )
    schedule(TimeInterval(timeout) / 1_000) { [weak self] in
      guard let self, self.generation == scheduledGeneration else { return }
      self.armedPhase = nil
      onTimeout(error)
    }
  }

  func cancel() {
    generation &+= 1
    armedPhase = nil
  }
}

final class YlAvPlayerBackend: NSObject, FlutterTexture, YlPlaybackBackend {
  private struct StagedHls {
    let source: [String: Any?]
    let prepared: YlPreparedHlsAsset
    let resume: Bool
  }

  let playerId: Int64
  var textureId: Int64 = -1
  var isActive: Bool { active }

  private let textures: FlutterTextureRegistry
  private let configuration: PlayerConfiguration
  private let emit: ([String: Any?]) -> Void
  private let errorLogCollector = YlAvPlayerErrorLogCollector()
  private let player = AVPlayer()
  private let videoOutput = AVPlayerItemVideoOutput(
    pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
  )
  private var displayLink: CADisplayLink?
  private var periodicObserver: Any?
  private var itemStatusObservation: NSKeyValueObservation?
  private var timeControlObservation: NSKeyValueObservation?
  private var endObserver: NSObjectProtocol?
  private var failedObserver: NSObjectProtocol?
  private var audioOptions: [String: AVMediaSelectionOption] = [:]
  private var audioTracks: [[String: Any?]] = []
  private var videoTracks: [[String: Any?]] = []
  private var sourceIsLive = false
  private var status = "idle"
  private var disposed = false
  private var firstFrameSent = false
  private var playRequested = false
  private var desiredRate: Float = 1
  private var openStartedAt: CFTimeInterval?
  private var openDurationMs: Int64?
  private var firstFrameDurationMs: Int64?
  private var rebufferCount = 0
  private var bufferingStartedAt: CFTimeInterval?
  private var rebufferDurationMs: Int64 = 0
  private var hasBeenReady = false
  private var currentError: [String: Any?]?
  private var active = false
  private var lastSource: [String: Any?]?
  private var savedPositionMs: Int64 = 0
  private var itemGeneration: UInt64 = 0
  private var channelGeneration = YlIosChannelGeneration.next()
  private var qualityConstraint: [String: Any?] = [:]
  private var selectedAudioTrackId: String?
  private var resumeAtLiveEdge = false
  private var hlsResourceLoader: YlHlsResourceLoader?
  private var stagedHls: StagedHls?
  private var liveReconnectController: YlLiveReconnectController
  private var pendingLiveReconnect: DispatchWorkItem?
  private let failureGate = YlAvPlayerFailureGate()
  private let stallWatchdog = YlAvPlayerStallWatchdog()

  init(
    playerId: Int64,
    textures: FlutterTextureRegistry,
    configuration: PlayerConfiguration,
    emit: @escaping ([String: Any?]) -> Void
  ) {
    self.playerId = playerId
    self.textures = textures
    self.configuration = configuration
    self.emit = emit
    self.liveReconnectController = YlLiveReconnectController(
      configuration: configuration.network
    )
    super.init()

    player.automaticallyWaitsToMinimizeStalling = configuration.bufferMode != "lowLatency"
    timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) {
      [weak self] _, _ in
      DispatchQueue.main.async { self?.handleTimeControlChange() }
    }
    periodicObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(
        milliseconds: configuration.positionEventIntervalMs,
        preferredTimescale: 1_000
      ),
      queue: .main
    ) { [weak self] _ in
      self?.emitStateDelta()
    }
    let link = CADisplayLink(target: self, selector: #selector(displayLinkTick))
    if #available(iOS 15.0, *) {
      link.preferredFrameRateRange = CAFrameRateRange(
        minimum: 15,
        maximum: 60,
        preferred: 30
      )
    } else {
      link.preferredFramesPerSecond = 30
    }
    link.add(to: .main, forMode: .common)
    link.isPaused = true
    displayLink = link
  }

  func command(name: String, arguments: [String: Any?]) throws {
    guard !disposed else {
      throw NativePlayerError(
        category: "resource",
        code: "ios.player_disposed",
        message: "The iOS player has been disposed."
      )
    }
    switch name {
    case "open":
      try open(stringMap(arguments["source"]))
    case "play":
      playRequested = true
      player.playImmediately(atRate: desiredRate)
      status = player.timeControlStatus == .playing ? "playing" : "buffering"
      emitState()
      refreshStallWatchdog()
    case "pause":
      playRequested = false
      stallWatchdog.cancel()
      player.pause()
    case "seekTo":
      let milliseconds = int64(arguments["positionMs"]) ?? 0
      resumeAtLiveEdge = false
      if active {
        player.seek(
          to: CMTime(milliseconds: milliseconds, preferredTimescale: 1_000),
          toleranceBefore: .zero,
          toleranceAfter: .zero
        )
      } else {
        savedPositionMs = max(0, milliseconds)
        emitState()
      }
    case "seekToLiveEdge":
      try seekToLiveEdge()
    case "setPlaybackSpeed":
      let speed = float(arguments["speed"]) ?? 1
      guard speed >= 0.25, speed <= 4 else {
        throw NativePlayerError(
          category: "source",
          code: "playback.speed_invalid",
          message: "Playback speed must be between 0.25 and 4.0."
        )
      }
      desiredRate = speed
      if player.rate != 0 { player.rate = speed }
    case "setVolume":
      player.volume = min(max(float(arguments["volume"]) ?? 1, 0), 1)
    case "selectAudioTrack":
      try selectAudioTrack(arguments["trackId"] as? String ?? "")
    case "setQualityConstraint":
      setQualityConstraint(stringMap(arguments["constraint"]))
    default:
      throw NativePlayerError(
        category: "internal",
        code: "ios.command_unknown",
        message: "Unknown player command: \(name)"
      )
    }
  }

  func validateOpen(_ source: [String: Any?]) throws {
    let headers = stringMap(source["headers"]).compactMapValues { $0 as? String }
    let descriptor = YlIosSourceDescriptor(
      uri: source["uri"] as? String ?? "",
      kind: source["kind"] as? String ?? "",
      formatHint: source["formatHint"] as? String ?? "automatic",
      isLive: source["isLive"] as? Bool ?? false,
      hasHeaders: !headers.isEmpty
    )
    switch YlSourceRouter.route(descriptor) {
    case .avPlayer:
      return
    case .localMatroska, .networkMatroska, .networkFlv, .headeredHls:
      throw NativePlayerError(
        category: "container",
        code: "container.native_fallback_required",
        message: "This source requires a compatible iOS native fallback."
      )
    case let .reject(category, code, message):
      throw NativePlayerError(
        category: category,
        code: code,
        message: message
      )
    }
  }

  func stagePreparedHls(
    source: [String: Any?],
    prepared: YlPreparedHlsAsset,
    resume: Bool
  ) throws {
    guard !disposed else {
      throw NativePlayerError(
        category: "resource",
        code: "ios.player_disposed",
        message: "The iOS player has been disposed."
      )
    }
    stagedHls?.prepared.discard()
    stagedHls = StagedHls(source: source, prepared: prepared, resume: resume)
  }

  func commitStagedHlsIfActive() throws {
    guard active else { return }
    try installStagedHls()
  }

  func activate() throws {
    guard !disposed, !active else { return }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback)
      try session.setActive(true)
    } catch {
      throw NativePlayerError(
        category: "resource",
        code: "ios.audio_session_failed",
        message: "The playback audio session could not be activated.",
        diagnostic: String(describing: error)
      )
    }
    active = true
    liveReconnectController = YlLiveReconnectController(
      configuration: configuration.network
    )
    if stagedHls != nil {
      try installStagedHls()
      return
    }
    guard let source = lastSource else {
      emitState()
      return
    }
    try installItem(source, positionMs: savedPositionMs)
    status = "opening"
    emitState()
  }

  func deactivate() {
    guard !disposed, active else { return }
    cancelLiveReconnect()
    savedPositionMs = milliseconds(player.currentTime()) ?? savedPositionMs
    if let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue,
       let position = milliseconds(player.currentTime()),
       let end = milliseconds(CMTimeRangeGetEnd(range)),
       end - position <= 2_000 {
      resumeAtLiveEdge = true
    }
    finishBuffering()
    active = false
    playRequested = false
    player.pause()
    removeCurrentItem()
    if status != "error" && status != "completed" && status != "idle" {
      status = "paused"
    }
    emitState()
  }

  private func open(_ source: [String: Any?]) throws {
    try validateOpen(source)
    channelGeneration = YlIosChannelGeneration.next()
    resetOpenState(source, resume: false)
    try installItem(source, positionMs: 0)
    emitState()
  }

  private func resetOpenState(_ source: [String: Any?], resume: Bool) {
    cancelLiveReconnect()
    liveReconnectController = YlLiveReconnectController(
      configuration: configuration.network
    )
    removeCurrentItem()
    lastSource = source
    if !resume {
      savedPositionMs = 0
      resumeAtLiveEdge = false
      selectedAudioTrackId = nil
    }
    active = true
    sourceIsLive = source["isLive"] as? Bool ?? false
    status = "opening"
    playRequested = false
    firstFrameSent = false
    hasBeenReady = false
    openStartedAt = CACurrentMediaTime()
    openDurationMs = nil
    firstFrameDurationMs = nil
    rebufferCount = 0
    rebufferDurationMs = 0
    bufferingStartedAt = nil
    currentError = nil
  }

  private func installStagedHls() throws {
    guard let stagedHls else {
      throw NativePlayerError(
        category: "internal",
        code: "internal.fallback_invariant",
        message: "No prepared HLS asset is staged."
      )
    }
    self.stagedHls = nil
    if !stagedHls.resume {
      channelGeneration = YlIosChannelGeneration.next()
    }
    let positionMs = stagedHls.resume ? savedPositionMs : 0
    resetOpenState(stagedHls.source, resume: stagedHls.resume)
    let loader = try stagedHls.prepared.takeLoader()
    hlsResourceLoader = loader
    installItem(asset: stagedHls.prepared.asset, positionMs: positionMs)
    emitState()
  }

  private func installItem(_ source: [String: Any?], positionMs: Int64) throws {
    guard let uri = source["uri"] as? String, let url = URL(string: uri) else {
      throw NativePlayerError(
        category: "source",
        code: "source.invalid_uri",
        message: "A valid media URI is required."
      )
    }
    installItem(asset: AVURLAsset(url: url), positionMs: positionMs)
  }

  private func installItem(asset: AVURLAsset, positionMs: Int64) {
    itemGeneration &+= 1
    let generation = itemGeneration
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = configuration.preferredForwardBufferDuration
    applyQualityConstraint(qualityConstraint, to: item)
    item.add(videoOutput)
    player.replaceCurrentItem(with: item)
    displayLink?.isPaused = false
    observe(item, generation: generation)
    if positionMs > 0 && !resumeAtLiveEdge {
      player.seek(
        to: CMTime(milliseconds: positionMs, preferredTimescale: 1_000),
        toleranceBefore: .zero,
        toleranceAfter: .zero
      )
    }
  }

  private func observe(_ item: AVPlayerItem, generation: UInt64) {
    itemStatusObservation = item.observe(\.status, options: [.initial, .new]) {
      [weak self] item, _ in
      DispatchQueue.main.async { self?.handleItemStatus(item, generation: generation) }
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      guard self?.isCurrent(item, generation: generation) == true else { return }
      self?.stallWatchdog.cancel()
      self?.status = "completed"
      self?.emitState()
    }
    failedObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] notification in
      guard self?.isCurrent(item, generation: generation) == true else { return }
      let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
      self?.handleFailure(error, item: item, generation: generation)
    }
  }

  private func handleItemStatus(_ item: AVPlayerItem, generation: UInt64) {
    guard isCurrent(item, generation: generation) else { return }
    switch item.status {
    case .readyToPlay:
      if !hasBeenReady {
        hasBeenReady = true
        openDurationMs = elapsedMilliseconds(since: openStartedAt)
      }
      switch player.timeControlStatus {
      case .playing:
        status = "playing"
      case .waitingToPlayAtSpecifiedRate:
        status = "buffering"
      case .paused:
        status = playRequested ? "buffering" : "ready"
      @unknown default:
        status = playRequested ? "buffering" : "ready"
      }
      if resumeAtLiveEdge {
        try? seekToLiveEdge()
      }
      rebuildTracks(item)
      emitState()
      refreshStallWatchdog()
    case .failed:
      handleFailure(item.error, item: item, generation: generation)
    default:
      break
    }
  }

  private func handleTimeControlChange() {
    guard player.currentItem != nil else { return }
    switch player.timeControlStatus {
    case .waitingToPlayAtSpecifiedRate:
      if hasBeenReady && bufferingStartedAt == nil {
        rebufferCount += 1
        bufferingStartedAt = CACurrentMediaTime()
      }
      status = "buffering"
    case .playing:
      finishBuffering()
      status = "playing"
    case .paused:
      finishBuffering()
      if status != "opening" && status != "completed" && status != "error" {
        status = playRequested ? "buffering" : (hasBeenReady ? "paused" : status)
      }
    @unknown default:
      break
    }
    emitState()
    refreshStallWatchdog()
  }

  private func finishBuffering() {
    if let started = bufferingStartedAt {
      rebufferDurationMs += Int64((CACurrentMediaTime() - started) * 1_000)
      bufferingStartedAt = nil
    }
  }

  private func handleFailure(
    _ error: Error?,
    item: AVPlayerItem? = nil,
    generation: UInt64? = nil
  ) {
    let failureGeneration = generation ?? itemGeneration
    guard failureGate.begin(generation: failureGeneration) else { return }
    stallWatchdog.cancel()
    let nsError = error as NSError?
    if let source = lastSource,
       YlAvPlayerRecoveryPolicy.shouldReconnect(
         source: source,
         usesResourceLoader: hlsResourceLoader != nil,
         hasBeenReady: hasBeenReady,
         playRequested: playRequested,
         error: nsError,
         errorLogDomain: nil,
         errorLogStatusCode: nil
       ), liveReconnectController.canRetry {
      finishFailure(nsError, log: nil, generation: failureGeneration)
      return
    }
    guard let item else {
      finishFailure(nsError, log: nil, generation: failureGeneration)
      return
    }

    errorLogCollector.collect(timeoutMs: 500, read: { [item] in
      let event = item.errorLog()?.events.last
      return YlAvPlayerErrorLogSnapshot(
        domain: event?.errorDomain,
        statusCode: event?.errorStatusCode,
        uri: event?.uri
      )
    }) { [weak self] snapshot in
      self?.finishFailure(nsError, log: snapshot, generation: failureGeneration)
    }
  }

  private func finishFailure(
    _ error: NSError?,
    log: YlAvPlayerErrorLogSnapshot?,
    generation: UInt64
  ) {
    guard failureGate.finish(
      generation: generation,
      currentGeneration: itemGeneration
    ), !disposed, active else {
      return
    }
    if let source = lastSource,
       YlAvPlayerRecoveryPolicy.shouldReconnect(
         source: source,
         usesResourceLoader: hlsResourceLoader != nil,
         hasBeenReady: hasBeenReady,
         playRequested: playRequested,
         error: error,
         errorLogDomain: log?.domain,
         errorLogStatusCode: log?.statusCode
       ), scheduleLiveReconnect(source: source) {
      return
    }

    failureGate.markTerminal(generation: generation)
    status = "error"
    let category = errorCategory(error)
    let diagnostic = YlAvPlayerRecoveryPolicy.diagnostic(
      error: error,
      errorDomain: log?.domain,
      statusCode: log?.statusCode,
      uri: log?.uri
    )
    let details = errorMap(
      category: category,
      code: error.map { "avplayer.\($0.code)" } ?? "avplayer.failed",
      message: "AVPlayer playback failed.",
      diagnostic: diagnostic
    )
    currentError = details
    emit(["playerId": playerId, "type": "error", "error": details])
    emitState(error: details)
  }

  @objc private func displayLinkTick() {
    guard !disposed, textureId >= 0, player.currentItem != nil else { return }
    let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
    guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime) else { return }
    liveReconnectController.markFirstFrame()
    textures.textureFrameAvailable(textureId)
    if !firstFrameSent {
      firstFrameSent = true
      firstFrameDurationMs = elapsedMilliseconds(since: openStartedAt)
      let size = player.currentItem?.presentationSize ?? .zero
      emit([
        "playerId": playerId,
        "type": "firstFrame",
        "width": size.width > 0 ? Int(size.width) : nil,
        "height": size.height > 0 ? Int(size.height) : nil,
      ])
      emitState()
      refreshStallWatchdog()
    }
  }

  private func refreshStallWatchdog() {
    let generation = itemGeneration
    stallWatchdog.update(
      active: active,
      wantsToPlay: playRequested,
      hasCurrentItem: player.currentItem != nil,
      isWaiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
      firstFrameSent: firstFrameSent,
      timeoutMs: configuration.network.readTimeoutMs,
      waitingReason: player.reasonForWaitingToPlay?.rawValue
    ) { [weak self] error in
      self?.handleStallTimeout(error, generation: generation)
    }
  }

  private func handleStallTimeout(
    _ error: NativePlayerError,
    generation: UInt64
  ) {
    guard failureGate.begin(generation: generation),
          failureGate.finish(
            generation: generation,
            currentGeneration: itemGeneration
          ), !disposed, active else {
      return
    }
    failureGate.markTerminal(generation: generation)
    stallWatchdog.cancel()
    playRequested = false
    player.pause()
    status = "error"
    let details = errorMap(
      category: error.category,
      code: error.code,
      message: error.message,
      diagnostic: error.diagnostic
    )
    currentError = details
    emit(["playerId": playerId, "type": "error", "error": details])
    emitState(error: details)
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
    guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
          let buffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
    else {
      return nil
    }
    return Unmanaged.passRetained(buffer)
  }

  private func seekToLiveEdge() throws {
    guard sourceIsLive || isIndefinite(player.currentItem?.duration) else {
      throw NativePlayerError(
        category: "source",
        code: "source.not_live",
        message: "The current source is not live."
      )
    }
    if !active {
      resumeAtLiveEdge = true
      emitState()
      return
    }
    guard let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else {
      resumeAtLiveEdge = true
      player.seek(to: .positiveInfinity)
      return
    }
    player.seek(to: CMTimeRangeGetEnd(range), toleranceBefore: .zero, toleranceAfter: .zero)
    resumeAtLiveEdge = false
  }

  private func selectAudioTrack(_ trackId: String) throws {
    guard let option = audioOptions[trackId] else {
      throw NativePlayerError(
        category: "source",
        code: "track.not_found",
        message: "The requested audio track is unavailable."
      )
    }
    selectedAudioTrackId = trackId
    guard let item = player.currentItem,
          let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible)
    else {
      emitState()
      return
    }
    item.select(option, in: group)
    rebuildTracks(item)
    emitState()
  }

  private func setQualityConstraint(_ constraint: [String: Any?]) {
    qualityConstraint = constraint
    guard let item = player.currentItem else { return }
    applyQualityConstraint(constraint, to: item)
  }

  private func applyQualityConstraint(_ constraint: [String: Any?], to item: AVPlayerItem) {
    item.preferredPeakBitRate = double(constraint["maxBitrate"]) ?? 0
    let width = double(constraint["maxWidth"])
    let height = double(constraint["maxHeight"])
    guard width != nil || height != nil else {
      item.preferredMaximumResolution = .zero
      return
    }
    let resolvedWidth = CGFloat(width ?? 100_000)
    let resolvedHeight = CGFloat(height ?? 100_000)
    item.preferredMaximumResolution = CGSize(width: resolvedWidth, height: resolvedHeight)
  }

  private func rebuildTracks(_ item: AVPlayerItem) {
    audioOptions.removeAll()
    if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
      group.options.enumerated().forEach { index, option in
        let id = "audio-\(index)"
        audioOptions[id] = option
      }
      if let selectedAudioTrackId, let option = audioOptions[selectedAudioTrackId] {
        item.select(option, in: group)
      }
      audioTracks = group.options.enumerated().map { index, option in
        let id = "audio-\(index)"
        return [
          "id": id,
          "kind": "audio",
          "label": option.displayName,
          "language": option.locale?.identifier,
          "isSelected": item.currentMediaSelection.selectedMediaOption(in: group) == option,
        ]
      }
    } else {
      audioTracks = []
    }

    videoTracks = item.asset.tracks(withMediaType: .video).enumerated().map { index, track in
      let size = track.naturalSize.applying(track.preferredTransform)
      return [
        "id": "video-\(index)",
        "kind": "video",
        "width": Int(abs(size.width)),
        "height": Int(abs(size.height)),
        "bitrate": Int(track.estimatedDataRate),
        "isSelected": true,
      ]
    }
    emit([
      "playerId": playerId,
      "type": "tracksChanged",
      "audioTracks": audioTracks,
      "videoTracks": videoTracks,
    ])
  }

  func emitState() {
    emitState(error: nil)
  }

  private func emitState(error: [String: Any?]?) {
    guard !disposed else { return }
    let item = player.currentItem
    let positionMs = active ? (milliseconds(player.currentTime()) ?? savedPositionMs) : savedPositionMs
    let durationMs = milliseconds(item?.duration)
    let loadedEndMs = item?.loadedTimeRanges.last
      .map { milliseconds(CMTimeRangeGetEnd($0.timeRangeValue)) ?? 0 } ?? 0
    let seekableRange = item?.seekableTimeRanges.last?.timeRangeValue
    let dvrStartMs = seekableRange.flatMap { milliseconds($0.start) }
    let dvrEndMs = seekableRange.flatMap { milliseconds(CMTimeRangeGetEnd($0)) }
    let live = sourceIsLive || isIndefinite(item?.duration)
    let liveOffsetMs = live ? dvrEndMs.map { max(0, $0 - positionMs) } : nil
    let size = item?.presentationSize ?? .zero
    emit(YlIosChannel.fullState(
      playerId: playerId,
      generation: channelGeneration,
      state: [
        "status": status,
        "positionMs": positionMs,
        "durationMs": durationMs,
        "bufferedPositionMs": loadedEndMs,
        "isLive": live,
        "isSeekable": seekableRange != nil,
        "isAtLiveEdge": liveOffsetMs.map { $0 <= 2_000 } ?? false,
        "liveOffsetMs": liveOffsetMs,
        "dvrStartMs": dvrStartMs,
        "dvrEndMs": dvrEndMs,
        "videoWidth": size.width > 0 ? Int(size.width) : nil,
        "videoHeight": size.height > 0 ? Int(size.height) : nil,
        "engine": "avPlayer",
        "isHardwareDecoding": false,
        "decoderName": nil,
        "audioTracks": audioTracks,
        "videoTracks": videoTracks,
        "capabilities": YlIosChannel.deviceCapabilities,
        "metrics": [
          "openDurationMs": openDurationMs,
          "firstFrameDurationMs": firstFrameDurationMs,
          "rebufferCount": rebufferCount,
          "rebufferDurationMs": rebufferDurationMs,
          "bufferedDurationMs": max(0, loadedEndMs - positionMs),
          "liveOffsetMs": liveOffsetMs,
        ],
        "error": error ?? currentError,
      ]
    ))
  }

  private func emitStateDelta() {
    guard !disposed else { return }
    let item = player.currentItem
    let positionMs = active ? (milliseconds(player.currentTime()) ?? savedPositionMs) : savedPositionMs
    let loadedEndMs = item?.loadedTimeRanges.last
      .map { milliseconds(CMTimeRangeGetEnd($0.timeRangeValue)) ?? 0 } ?? 0
    let seekableRange = item?.seekableTimeRanges.last?.timeRangeValue
    let live = sourceIsLive || isIndefinite(item?.duration)
    let dvrEndMs = seekableRange.flatMap { milliseconds(CMTimeRangeGetEnd($0)) }
    let liveOffsetMs = live ? dvrEndMs.map { max(0, $0 - positionMs) } : nil
    emit(YlIosChannel.stateDelta(
      playerId: playerId,
      generation: channelGeneration,
      delta: [
        "positionMs": positionMs,
        "bufferedPositionMs": loadedEndMs,
        "isAtLiveEdge": liveOffsetMs.map { $0 <= 2_000 } ?? false,
        "liveOffsetMs": liveOffsetMs,
        "metrics": [
          "openDurationMs": openDurationMs,
          "firstFrameDurationMs": firstFrameDurationMs,
          "rebufferCount": rebufferCount,
          "rebufferDurationMs": rebufferDurationMs,
          "bufferedDurationMs": max(0, loadedEndMs - positionMs),
          "liveOffsetMs": liveOffsetMs,
        ],
      ]
    ))
  }

  func dispose() {
    guard !disposed else { return }
    disposed = true
    cancelLiveReconnect()
    displayLink?.invalidate()
    displayLink = nil
    removeItemObservers()
    timeControlObservation?.invalidate()
    timeControlObservation = nil
    if let observer = periodicObserver {
      player.removeTimeObserver(observer)
      periodicObserver = nil
    }
    player.pause()
    removeCurrentItem()
    stagedHls?.prepared.discard()
    stagedHls = nil
    lastSource = nil
    if textureId >= 0 {
      textures.unregisterTexture(textureId)
      textureId = -1
    }
  }

  private func removeItemObservers() {
    itemStatusObservation?.invalidate()
    itemStatusObservation = nil
    if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
    if let observer = failedObserver { NotificationCenter.default.removeObserver(observer) }
    endObserver = nil
    failedObserver = nil
  }

  private func removeCurrentItem() {
    itemGeneration &+= 1
    stallWatchdog.cancel()
    removeItemObservers()
    displayLink?.isPaused = true
    player.currentItem?.remove(videoOutput)
    player.replaceCurrentItem(with: nil)
    hlsResourceLoader?.cancelAll()
    hlsResourceLoader = nil
  }

  private func scheduleLiveReconnect(source: [String: Any?]) -> Bool {
    guard active,
          let delayMs = liveReconnectController.nextDelayMs() else {
      return false
    }

    status = "buffering"
    currentError = nil
    removeCurrentItem()
    let expectedGeneration = itemGeneration
    let reconnect = DispatchWorkItem { [weak self] in
      guard let self, !self.disposed, self.active,
            self.itemGeneration == expectedGeneration,
            self.liveReconnectController.shouldInstall(
              reconnectGeneration: expectedGeneration,
              currentGeneration: self.itemGeneration
            ) else {
        return
      }
      self.pendingLiveReconnect = nil
      do {
        try self.installItem(source, positionMs: 0)
        if self.playRequested {
          self.player.playImmediately(atRate: self.desiredRate)
        }
        self.emitState()
        self.refreshStallWatchdog()
      } catch {
        self.handleFailure(error)
      }
    }
    pendingLiveReconnect = reconnect
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(Int(delayMs)),
      execute: reconnect
    )
    emitState()
    return true
  }

  private func cancelLiveReconnect() {
    pendingLiveReconnect?.cancel()
    pendingLiveReconnect = nil
    liveReconnectController.cancel()
    failureGate.reset()
  }

  private func isCurrent(_ item: AVPlayerItem, generation: UInt64) -> Bool {
    !disposed && active && generation == itemGeneration && item === player.currentItem
  }
}

struct PlayerConfiguration {
  let bufferMode: String
  let decoderPolicy: String
  let maxBufferBytes: Int?
  let network: YlNetworkConfiguration
  let positionEventIntervalMs: Int64
  let preferredForwardBufferDuration: TimeInterval

  init(map: [String: Any?]) {
    bufferMode = map["bufferMode"] as? String ?? "automatic"
    decoderPolicy = map["decoderPolicy"] as? String ?? "hardwareOnly"
    maxBufferBytes = int64(map["maxBufferBytes"]).map { Int(clamping: max(0, $0)) }
    network = YlNetworkConfiguration(map: stringMap(map["network"]))
    positionEventIntervalMs = min(
      max(int64(map["positionEventIntervalMs"]) ?? 250, 100),
      2_000
    )
    preferredForwardBufferDuration = switch bufferMode {
    case "lowLatency": 2
    case "stable": 30
    default: 10
    }
  }
}

struct YlNetworkConfiguration: Equatable {
  let connectTimeoutMs: Int64
  let readTimeoutMs: Int64
  let maxRetries: Int
  let baseRetryDelayMs: Int64
  let maxRetryDelayMs: Int64
  let maxRedirects: Int

  init(map: [String: Any?]) {
    connectTimeoutMs = Self.clampedMilliseconds(
      int64(map["connectTimeoutMs"]) ?? 10_000
    )
    readTimeoutMs = Self.clampedMilliseconds(
      int64(map["readTimeoutMs"]) ?? 15_000
    )
    maxRetries = Self.clampedCount(int64(map["maxRetries"]) ?? 3)
    baseRetryDelayMs = Self.clampedMilliseconds(
      int64(map["baseRetryDelayMs"]) ?? 500
    )
    maxRetryDelayMs = Self.clampedMilliseconds(
      int64(map["maxRetryDelayMs"]) ?? 8_000
    )
    maxRedirects = Self.clampedCount(int64(map["maxRedirects"]) ?? 5)
  }

  private static func clampedMilliseconds(_ value: Int64) -> Int64 {
    min(max(value, 0), 60_000)
  }

  private static func clampedCount(_ value: Int64) -> Int {
    Int(min(max(value, 0), 20))
  }
}

struct NativePlayerError: Error {
  let category: String
  let code: String
  let message: String
  var diagnostic: String?

  init(category: String, code: String, message: String, diagnostic: String? = nil) {
    self.category = category
    self.code = code
    self.message = message
    self.diagnostic = diagnostic
  }
}

func flutterError(_ error: NativePlayerError) -> FlutterError {
  FlutterError(
    code: error.code,
    message: error.message,
    details: errorMap(
      category: error.category,
      code: error.code,
      message: error.message,
      diagnostic: error.diagnostic
    )
  )
}

func errorMap(
  category: String,
  code: String,
  message: String,
  diagnostic: String? = nil
) -> [String: Any?] {
  [
    "category": category,
    "code": code,
    "message": message,
    "platformDiagnostic": diagnostic,
  ]
}

private func errorCategory(_ error: NSError?) -> String {
  guard let error else { return "source" }
  if error.domain == NSURLErrorDomain {
    return "network"
  }
  if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
     underlying.domain == NSURLErrorDomain {
    return "network"
  }
  guard error.domain == AVFoundationErrorDomain else { return "source" }
  switch AVError.Code(rawValue: error.code) {
  case .decoderNotFound, .decoderTemporarilyUnavailable:
    return "decoderUnsupported"
  case .decodeFailed:
    return "decoderFailure"
  case .fileFormatNotRecognized, .invalidSourceMedia, .operationNotSupportedForAsset:
    return "container"
  default:
    return "source"
  }
}

func stringMap(_ value: Any?) -> [String: Any?] {
  guard let source = value as? [AnyHashable: Any?] else { return [:] }
  return Dictionary(uniqueKeysWithValues: source.map { (String(describing: $0.key), $0.value) })
}

func int64(_ value: Any?) -> Int64? {
  if let value = value as? NSNumber { return value.int64Value }
  return value as? Int64
}

func float(_ value: Any?) -> Float? {
  if let value = value as? NSNumber { return value.floatValue }
  return value as? Float
}

private func double(_ value: Any?) -> Double? {
  if let value = value as? NSNumber { return value.doubleValue }
  return value as? Double
}

private func milliseconds(_ time: CMTime?) -> Int64? {
  guard let time, time.isNumeric, !time.isIndefinite else { return nil }
  let seconds = CMTimeGetSeconds(time)
  guard seconds.isFinite && seconds >= 0 else { return nil }
  return Int64(seconds * 1_000)
}

private func isIndefinite(_ time: CMTime?) -> Bool {
  guard let time else { return false }
  return time.isIndefinite || !time.isNumeric
}

private func elapsedMilliseconds(since start: CFTimeInterval?) -> Int64? {
  start.map { Int64((CACurrentMediaTime() - $0) * 1_000) }
}

private extension CMTime {
  init(milliseconds: Int64, preferredTimescale: CMTimeScale) {
    self.init(
      value: CMTimeValue(milliseconds) * CMTimeValue(preferredTimescale) / 1_000,
      timescale: preferredTimescale
    )
  }
}
