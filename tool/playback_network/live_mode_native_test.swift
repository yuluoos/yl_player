import Foundation
import CoreVideo

@main
struct LiveModeNativeTest {
  static func main() throws {
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ name: String) {
      precondition(value(), name); checks += 1
    }
    func catchUp(low: Bool = true, playing: Bool = true, active: Bool = true,
                 edge: Bool = true, rate: Float = 1, offset: Int64? = 4_000,
                 window: Bool = true, maySeek: Bool = true) -> YlLiveCatchUpAction {
      YlLiveCatchUpPolicy.action(lowLatency: low, playing: playing, active: active,
        automaticEdgeAllowed: edge, requestedRate: rate, offsetMs: offset,
        targetMs: 2_000, hasSeekableWindow: window, maySeek: maySeek)
    }
    check(catchUp() == .rate(1.03), "bounded catch-up rate")
    check(catchUp(offset: 1_000) == .rate(1), "return to normal rate")
    check(catchUp(offset: 9_000) == .edge, "seek excessive backlog in valid window")
    check(catchUp(offset: 9_000, maySeek: false) == .rate(1.03), "seek cooldown")
    check(catchUp(low: false) == .none, "smooth mode does not catch up")
    check(catchUp(playing: false) == .none, "paused intent")
    check(catchUp(active: false) == .none, "inactive owner")
    check(catchUp(edge: false) == .none, "absolute seek intent")
    check(catchUp(rate: 1.5) == .none, "explicit user rate")
    check(catchUp(offset: nil) == .none, "unknown offset")
    check(catchUp(window: false) == .none, "no seekable window")
    var installedRate: Float = 1.03
    let allowCatchUp = YlLiveCatchUpPolicy.endAutomaticCatchUp(requestedRate: 1, playing: true) { installedRate = $0 }
    check(installedRate == 1 && !allowCatchUp, "absolute seek restores installed automatic rate")
    installedRate = 0
    _ = YlLiveCatchUpPolicy.endAutomaticCatchUp(requestedRate: 1.5, playing: false) { installedRate = $0 }
    check(installedRate == 0, "seek cannot resume paused output")
    let oldBackend = LiveModeFakeBackend(), newBackend = LiveModeFakeBackend()
    var backend: YlPlaybackBackend = oldBackend
    var current = true
    let resolve: () throws -> YlPlaybackBackend = { if !current { throw YlOpenCancellationToken.cancellationError() }; return backend }
    let caps = YlQueuedPlaybackCommand(command: .constraints(.unconstrained), resolve: resolve)
    let audio = YlQueuedPlaybackCommand(command: .track("audio-2"), resolve: resolve)
    backend = newBackend // mode candidate commits while both commands wait
    try caps.run(YlOpenCancellationToken()); try audio.run(YlOpenCancellationToken())
    check(oldBackend.commands.isEmpty && newBackend.commands == ["caps", "audio-2"], "queued controls resolve installed backend")
    current = false
    do { try audio.run(YlOpenCancellationToken()); preconditionFailure("stale queued command acknowledged") }
    catch { checks += 1 }
    let config = PlayerConfiguration(positionEventIntervalMs: 250)
    var source = YlAppleSourceDescriptor(uri: "https://fixture.invalid/live.m3u8", kind: .network,
      formatHint: .hls, intent: .live, loadOptions: .init())
    check(config.forLoad(source).bufferMode == "stable", "confirmed live defaults smooth")
    source.intent = .automatic; source.formatHint = .automatic
    source.uri = "https://fixture.invalid/auto.flv"
    check(config.forLoad(source).bufferMode == "stable", "inferred FLV defaults smooth")
    source.intent = .onDemand
    check(config.forLoad(source).bufferMode == "automatic", "VOD default unchanged")
    source.loadOptions?.bufferStrategy = .lowLatency
    check(config.forLoad(source).preferredForwardBufferDuration == 2, "explicit low mode")
    source.intent = .live; source.loadOptions?.bufferStrategy = .bounded
    check(config.forLoad(source).bufferMode == "automatic", "bounded is not relabeled")
    let intent = YlManagedRequestIntent()
    check(intent.nextRetry(maximum: 3) == 1, "initial retry")
    let candidate = intent.candidate()
    check(candidate.nextRetry(maximum: 3) == 2, "candidate shares retry counter")
    check(candidate.followRedirect(maximum: 1), "candidate redirect charged")
    check(!intent.followRedirect(maximum: 1), "original cannot replenish redirects")
    candidate.fail(NativePlayerError(category: "network", code: "network.http_status", message: "Rejected"))
    check(intent.terminalFailure == nil, "failed candidate does not poison surviving original")
    check(candidate.terminalFailure != nil, "failed candidate stays failed")
    intent.completed(); candidate.completed()
    check(intent.nextRetry(maximum: 3) == 3, "original retains consumed candidate budget")
    check(intent.candidate().nextRetry(maximum: 3) == nil, "another mode request cannot reset budget")
    let recovery = YlLiveReconnectController(configuration: .init(map: ["maxRetries": 3]))
    recovery.retainAttempts(2); recovery.markFirstFrame()
    check(recovery.attempt == 2, "replacement first frame cannot replenish recovery attempts")
    let callbackIdentity = YlAppleSessionIdentity(sessionId: "mode", loadRequestId: "load", startedAtMs: 0)
    let emitter = YlAppleCommitEmitter(identity: callbackIdentity, emit: { _,_ in preconditionFailure("stale candidate snapshot replayed") })
    let reducer = YlAppleStateReducer(playerId: 1, clock: { 100 })
    let identity = reducer.makeIdentity(loadRequestId: "load-1")
    reducer.commit(identity)
    let snapshot = YlNativeState(status: "paused", positionMs: 100, durationMs: nil,
      bufferedPositionMs: 100, isLive: true, isSeekable: false, isAtLiveEdge: false,
      liveOffsetMs: nil, dvrStartMs: nil, dvrEndMs: nil, videoWidth: nil, videoHeight: nil,
      engine: .managedFallback, isHardwareDecoding: false, decoderName: nil,
      audioTracks: [], videoTracks: [], metrics: .init(), error: nil)
    reducer.accept(.init(generation: 1, event: .state(snapshot)), identity: identity)
    emitter.accept(.init(generation: 1, event: .state(snapshot)))
    check(emitter.takeInitialSnapshot()?.status == "paused", "commit takes actual candidate state")
    check(emitter.takeInitialSnapshot() == nil, "candidate snapshot taken once")
    emitter.commit()
    let before = reducer.revision
    let revision = try reducer.commitLivePlayback(.init(mode: .lowLatency,
      switchableModes: [.smoothPlayback, .lowLatency], committedRequestId: 1))
    check(revision == before + 1, "single exact commit revision")
    check(reducer.state.snapshot?.status == "paused", "commit preserves pause")
    check(reducer.state.snapshot?.livePlayback?.committedRequestId == 1, "snapshot carries commit identity")
    reducer.stop()
    check(reducer.state.snapshot == nil, "stop clears live state")
    do { _ = try reducer.commitLivePlayback(.init(mode: .lowLatency, switchableModes: [], committedRequestId: 2)); preconditionFailure("stale commit accepted") }
    catch { checks += 1 }
    print("P04_NATIVE_POLICY_CHECKS=\(checks)")
  }
}

private final class LiveModeFakeBackend: YlPlaybackBackend {
  var isActive = true
  var commands = [String]()
  func activate() throws {}
  func stop() {}
  func deactivate() {}
  func play() throws {}
  func pause() throws {}
  func seek(toMs: Int64, cancellationToken: YlOpenCancellationToken?) throws {}
  func seekToLiveEdge() throws {}
  func setPlaybackSpeed(_ speed: Float) throws {}
  func setVolume(_ volume: Float) throws {}
  func selectAudioTrack(_ trackId: String, cancellationToken: YlOpenCancellationToken?) throws { commands.append(trackId) }
  func setVideoConstraints(_ constraints: YlAppleVideoConstraints) throws { commands.append("caps") }
  func emitState() {}
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? { nil }
  func dispose() {}
}
