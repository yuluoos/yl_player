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
  func requiresAsyncCommand(_ command: YlApplePlaybackCommand) -> Bool {
    YlFallbackCommandPolicy.requiresBackgroundExecution(isNetwork: session.isNetworkSource,
      isActive: session.isActive, command: command)
  }
  func play() throws { guard !session.isStopped else { return }; try session.play() }
  func pause() throws { guard !session.isStopped else { return }; try session.pause() }
  func seek(toMs: Int64, cancellationToken: YlOpenCancellationToken? = nil) throws {
    guard !session.isStopped else { return }
    try session.seek(toMs: toMs, cancellationToken: cancellationToken)
  }
  func seekToLiveEdge() throws { guard !session.isStopped else { return }; try session.seekToLiveEdge() }
  func setPlaybackSpeed(_ speed: Float) throws { try session.setPlaybackSpeed(speed) }
  func setVolume(_ volume: Float) { session.setVolume(volume) }
  func selectAudioTrack(_ trackId: String, cancellationToken: YlOpenCancellationToken? = nil) throws {
    guard !session.isStopped else { return }
    try session.selectAudioTrack(trackId, cancellationToken: cancellationToken)
  }
  func setVideoConstraints(_ constraints: YlAppleVideoConstraints) throws {
    guard !session.isStopped else { return }
    try session.setQualityConstraint(YlFallbackQualityConstraint(validating: constraints))
  }
}
