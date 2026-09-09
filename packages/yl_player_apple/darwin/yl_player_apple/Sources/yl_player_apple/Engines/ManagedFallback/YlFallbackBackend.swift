import CoreMedia
import CoreVideo
import Foundation

/// Compatibility adapter for the host-owned prepared/commit transaction (R7/R8).
/// This backend owns one prepared managed session; activate delegates its commit
/// phase. The host/slot remains the sole owner of public callback/texture authority.
final class YlFallbackBackend: NSObject, YlPlaybackBackend {
  private let session: YlManagedPlaybackSession
  var playerId: Int64 { session.playerId }
  var textureId: Int64 { session.textureId }
  var isActive: Bool { session.isActive }
  var playbackIntent: Bool { session.playbackIntent }
  var requiresAsyncActivation: Bool { session.requiresAsyncActivation }
  var channelGeneration: UInt64 { session.channelGeneration }

  init(playerId: Int64, services: YlPlatformServices, configuration: PlayerConfiguration,
       prepared: YlPreparedFallback,
       qualityConstraint: YlFallbackQualityConstraint = .unconstrained,
       generation: UInt64,
       videoSessionFactory: YlVTSessionFactory = YlHardwareVTSessionFactory(),
       mediaClock: YlMediaClock? = nil, loadRequestId: String? = nil,
       channelIdentity: UInt64? = nil,
       audioRendererFactory: any YlAudioRendererMaking = YlPlatformAudioRendererFactory(),
       presentationScheduler: any YlPresentationScheduling = YlFrameScheduler(),
       demuxControl: any YlDemuxControlling = YlOpenedMediaControl(),
       emit: @escaping (YlNativeBackendCallback) -> Void) throws {
    session = try YlManagedPlaybackSession(playerId: playerId, services: services,
      configuration: configuration, prepared: prepared, qualityConstraint: qualityConstraint,
      generation: generation, videoSessionFactory: videoSessionFactory, mediaClock: mediaClock,
      audioRendererFactory: audioRendererFactory, presentationScheduler: presentationScheduler,
      demuxControl: demuxControl, loadRequestId: loadRequestId, channelIdentity: channelIdentity, emit: emit)
    super.init()
  }

  func activate() throws { try session.activate() }
  func deactivate() { session.deactivate() }
  func stop() { session.stop() }
  func dispose() { session.dispose() }
  func quiesceForReplacement() { session.quiesceForReplacement() }
  func reactivationState(forcePlay: Bool) -> YlFallbackResumeState { session.reactivationState(forcePlay: forcePlay) }
  func reportRestorationFailure(_ error: NativePlayerError) { session.reportRestorationFailure(error) }
  func handleMemoryWarning() { session.handleMemoryWarning() }
  func interruptControlOperation() { session.interruptControlOperation() }
  func resumeControlOperation() { session.resumeControlOperation() }
  func validateQualityConstraint(_ constraint: YlFallbackQualityConstraint) throws {
    try session.validateQualityConstraint(constraint)
  }
  func emitState() { session.emitState() }
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? { session.copyPixelBuffer() }
  func requiresAsyncCommand(_ name: String) -> Bool {
    YlFallbackCommandPolicy.requiresBackgroundExecution(isNetwork: session.isNetworkSource,
      isActive: session.isActive, name: name)
  }

  func command(name: String, arguments: [String: Any?]) throws {
    try command(name: name, arguments: arguments, cancellationToken: nil)
  }

  func command(
    name: String,
    arguments: [String: Any?],
    cancellationToken: YlOpenCancellationToken?
  ) throws {
    if session.isStopped,
       !["setVolume", "setPlaybackSpeed", "stop"].contains(name) { return }
    switch name {
    case "stop":
      session.stop()
    case "open":
      session.emitState()
    case "play":
      try session.play()
    case "pause":
      try session.pause()
    case "seekTo":
      try session.seek(toMs: int64(arguments["positionMs"]) ?? 0, cancellationToken: cancellationToken)
    case "seekToLiveEdge":
      try session.seekToLiveEdge()
    case "setPlaybackSpeed":
      try session.setPlaybackSpeed(float(arguments["speed"]) ?? 1)
    case "setVolume":
      session.setVolume(float(arguments["volume"]) ?? 1)
    case "selectAudioTrack":
      try session.selectAudioTrack(arguments["trackId"] as? String, cancellationToken: cancellationToken)
    case "setQualityConstraint":
      let constraint = try YlFallbackQualityConstraint(validating: stringMap(arguments["constraint"]))
      try session.setQualityConstraint(constraint)
    default:
      throw NativePlayerError(
        category: "internal",
        code: "\(YlApplePlatform.current.rawValue).command_unknown",
        message: "Unknown player command: \(name)"
      )
    }
  }

}
