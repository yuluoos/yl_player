import AVFoundation
import CoreVideo
import Flutter
import QuartzCore
import UIKit

public final class YlPlayerIosPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let textures: FlutterTextureRegistry
  private var players: [Int64: YlAvPlayer] = [:]
  private var nextPlayerId: Int64 = 1
  private var eventSink: FlutterEventSink?

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = YlPlayerIosPlugin(textures: registrar.textures())
    let methods = FlutterMethodChannel(
      name: "dev.ylplayer.yl_player_ios/methods",
      binaryMessenger: registrar.messenger()
    )
    let events = FlutterEventChannel(
      name: "dev.ylplayer.yl_player_ios/events",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: methods)
    events.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "create":
      create(call.arguments, result: result)
    case "command":
      command(call.arguments, result: result)
    case "dispose":
      dispose(call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    players.values.forEach { $0.emitState() }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func create(_ arguments: Any?, result: @escaping FlutterResult) {
    let root = stringMap(arguments)
    let configuration = PlayerConfiguration(map: stringMap(root["configuration"]))
    let playerId = nextPlayerId
    nextPlayerId += 1
    let nativePlayer = YlAvPlayer(
      playerId: playerId,
      textures: textures,
      configuration: configuration,
      emit: { [weak self] event in self?.eventSink?(event) }
    )
    let textureId = textures.register(nativePlayer)
    nativePlayer.textureId = textureId
    players[playerId] = nativePlayer
    result(["playerId": playerId, "textureId": textureId])
  }

  private func command(_ arguments: Any?, result: @escaping FlutterResult) {
    let root = stringMap(arguments)
    guard let playerId = int64(root["playerId"]), let player = players[playerId] else {
      result(flutterError(NativePlayerError(
        category: "resource",
        code: "ios.player_missing",
        message: "The requested iOS player does not exist."
      )))
      return
    }
    do {
      try player.command(
        name: root["name"] as? String ?? "",
        arguments: stringMap(root["arguments"])
      )
      result(nil)
    } catch let error as NativePlayerError {
      result(flutterError(error))
    } catch {
      result(flutterError(NativePlayerError(
        category: "internal",
        code: "ios.command_failed",
        message: "AVPlayer command failed.",
        diagnostic: String(describing: error)
      )))
    }
  }

  private func dispose(_ arguments: Any?, result: @escaping FlutterResult) {
    let root = stringMap(arguments)
    if let playerId = int64(root["playerId"]), let player = players.removeValue(forKey: playerId) {
      player.dispose()
    }
    result(nil)
  }
}

private final class YlAvPlayer: NSObject, FlutterTexture {
  let playerId: Int64
  var textureId: Int64 = -1

  private let textures: FlutterTextureRegistry
  private let configuration: PlayerConfiguration
  private let emit: ([String: Any?]) -> Void
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
  private var desiredRate: Float = 1
  private var openStartedAt: CFTimeInterval?
  private var openDurationMs: Int64?
  private var firstFrameDurationMs: Int64?
  private var rebufferCount = 0
  private var bufferingStartedAt: CFTimeInterval?
  private var rebufferDurationMs: Int64 = 0
  private var hasBeenReady = false

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
    super.init()

    player.automaticallyWaitsToMinimizeStalling = configuration.bufferMode != "lowLatency"
    timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) {
      [weak self] _, _ in self?.handleTimeControlChange()
    }
    periodicObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(
        milliseconds: configuration.positionEventIntervalMs,
        preferredTimescale: 1_000
      ),
      queue: .main
    ) { [weak self] _ in
      self?.emitState()
    }
    let link = CADisplayLink(target: self, selector: #selector(displayLinkTick))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 30)
    link.add(to: .main, forMode: .common)
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
      player.playImmediately(atRate: desiredRate)
    case "pause":
      player.pause()
    case "seekTo":
      let milliseconds = int64(arguments["positionMs"]) ?? 0
      player.seek(
        to: CMTime(milliseconds: milliseconds, preferredTimescale: 1_000),
        toleranceBefore: .zero,
        toleranceAfter: .zero
      )
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

  private func open(_ source: [String: Any?]) throws {
    let formatHint = source["formatHint"] as? String ?? "automatic"
    if formatHint == "httpFlv" || formatHint == "flv" {
      throw NativePlayerError(
        category: "container",
        code: "container.http_flv_requires_fallback",
        message: "HTTP-FLV requires the iOS native fallback, which is not bundled yet."
      )
    }
    guard let uri = source["uri"] as? String, let url = URL(string: uri) else {
      throw NativePlayerError(
        category: "source",
        code: "source.invalid_uri",
        message: "A valid media URI is required."
      )
    }

    removeItemObservers()
    player.pause()
    player.currentItem?.remove(videoOutput)
    let headers = stringMap(source["headers"]).compactMapValues { $0 as? String }
    let asset = AVURLAsset(
      url: url,
      options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
    )
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = configuration.preferredForwardBufferDuration
    item.add(videoOutput)
    sourceIsLive = source["isLive"] as? Bool ?? false
    status = "opening"
    firstFrameSent = false
    hasBeenReady = false
    openStartedAt = CACurrentMediaTime()
    openDurationMs = nil
    firstFrameDurationMs = nil
    rebufferCount = 0
    rebufferDurationMs = 0
    player.replaceCurrentItem(with: item)
    observe(item)
    emitState()
  }

  private func observe(_ item: AVPlayerItem) {
    itemStatusObservation = item.observe(\.status, options: [.initial, .new]) {
      [weak self] item, _ in self?.handleItemStatus(item)
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      self?.status = "completed"
      self?.emitState()
    }
    failedObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] notification in
      let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
      self?.handleFailure(error)
    }
  }

  private func handleItemStatus(_ item: AVPlayerItem) {
    switch item.status {
    case .readyToPlay:
      if !hasBeenReady {
        hasBeenReady = true
        openDurationMs = elapsedMilliseconds(since: openStartedAt)
      }
      status = player.rate == 0 ? "ready" : "playing"
      rebuildTracks(item)
      emitState()
    case .failed:
      handleFailure(item.error)
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
        status = hasBeenReady ? "paused" : status
      }
    @unknown default:
      break
    }
    emitState()
  }

  private func finishBuffering() {
    if let started = bufferingStartedAt {
      rebufferDurationMs += Int64((CACurrentMediaTime() - started) * 1_000)
      bufferingStartedAt = nil
    }
  }

  private func handleFailure(_ error: Error?) {
    status = "error"
    let nsError = error as NSError?
    let category = nsError?.domain == NSURLErrorDomain ? "network" : "source"
    let details = errorMap(
      category: category,
      code: nsError.map { "avplayer.\($0.code)" } ?? "avplayer.failed",
      message: nsError?.localizedDescription ?? "AVPlayer playback failed.",
      diagnostic: nsError.map(String.init(describing:))
    )
    emit(["playerId": playerId, "type": "error", "error": details])
    emitState(error: details)
  }

  @objc private func displayLinkTick() {
    guard !disposed, textureId >= 0, player.currentItem != nil else { return }
    let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
    guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime) else { return }
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
    }
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
    guard let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else {
      player.seek(to: .positiveInfinity)
      return
    }
    player.seek(to: CMTimeRangeGetEnd(range), toleranceBefore: .zero, toleranceAfter: .zero)
  }

  private func selectAudioTrack(_ trackId: String) throws {
    guard let item = player.currentItem,
          let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible),
          let option = audioOptions[trackId]
    else {
      throw NativePlayerError(
        category: "source",
        code: "track.not_found",
        message: "The requested audio track is unavailable."
      )
    }
    item.select(option, in: group)
    rebuildTracks(item)
    emitState()
  }

  private func setQualityConstraint(_ constraint: [String: Any?]) {
    guard let item = player.currentItem else { return }
    item.preferredPeakBitRate = double(constraint["maxBitrate"]) ?? 0
    let width = double(constraint["maxWidth"]) ?? 0
    let height = double(constraint["maxHeight"]) ?? 0
    item.preferredMaximumResolution = width > 0 && height > 0
      ? CGSize(width: width, height: height)
      : .zero
  }

  private func rebuildTracks(_ item: AVPlayerItem) {
    audioOptions.removeAll()
    if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
      audioTracks = group.options.enumerated().map { index, option in
        let id = "audio-\(index)"
        audioOptions[id] = option
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

  func emitState(error: [String: Any?]? = nil) {
    guard !disposed else { return }
    let item = player.currentItem
    let positionMs = milliseconds(player.currentTime()) ?? 0
    let durationMs = milliseconds(item?.duration)
    let loadedEndMs = item?.loadedTimeRanges.last
      .map { milliseconds(CMTimeRangeGetEnd($0.timeRangeValue)) ?? 0 } ?? 0
    let seekableRange = item?.seekableTimeRanges.last?.timeRangeValue
    let dvrStartMs = seekableRange.flatMap { milliseconds($0.start) }
    let dvrEndMs = seekableRange.flatMap { milliseconds(CMTimeRangeGetEnd($0)) }
    let live = sourceIsLive || isIndefinite(item?.duration)
    let liveOffsetMs = live ? dvrEndMs.map { max(0, $0 - positionMs) } : nil
    let size = item?.presentationSize ?? .zero
    emit([
      "playerId": playerId,
      "type": "state",
      "state": [
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
        "capabilities": [
          "hardwareVideoCodecs": [],
          "supportedFormats": ["automatic", "hls", "mp4", "mov"],
          "maxConcurrentVideoDecoders": 1,
        ],
        "metrics": [
          "openDurationMs": openDurationMs,
          "firstFrameDurationMs": firstFrameDurationMs,
          "rebufferCount": rebufferCount,
          "rebufferDurationMs": rebufferDurationMs,
          "bufferedDurationMs": max(0, loadedEndMs - positionMs),
          "liveOffsetMs": liveOffsetMs,
        ],
        "error": error,
      ],
    ])
  }

  func dispose() {
    guard !disposed else { return }
    disposed = true
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
    player.currentItem?.remove(videoOutput)
    player.replaceCurrentItem(with: nil)
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
}

private struct PlayerConfiguration {
  let bufferMode: String
  let positionEventIntervalMs: Int64
  let preferredForwardBufferDuration: TimeInterval

  init(map: [String: Any?]) {
    bufferMode = map["bufferMode"] as? String ?? "automatic"
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

private struct NativePlayerError: Error {
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

private func flutterError(_ error: NativePlayerError) -> FlutterError {
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

private func errorMap(
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

private func stringMap(_ value: Any?) -> [String: Any?] {
  guard let source = value as? [AnyHashable: Any?] else { return [:] }
  return Dictionary(uniqueKeysWithValues: source.map { (String(describing: $0.key), $0.value) })
}

private func int64(_ value: Any?) -> Int64? {
  if let value = value as? NSNumber { return value.int64Value }
  return value as? Int64
}

private func float(_ value: Any?) -> Float? {
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
