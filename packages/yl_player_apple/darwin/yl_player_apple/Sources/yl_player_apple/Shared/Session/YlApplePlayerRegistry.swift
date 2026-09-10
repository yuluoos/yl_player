import Foundation

final class YlApplePlayerRegistry: ApplePlayerFactoryHostApi {
  private let makeServices: (ApplePlayerOptionsMessage) throws -> YlPlatformServices
  private let makeCallbacks: (String) -> ApplePlayerFlutterApiProtocol
  private let installHost: (String, ApplePlayerHostApi?) -> Void
  private let lifecycle: YlLifecycleDriving?
  private var players: [String: YlApplePlayerHost] = [:]
  private var nextPlayerId: Int64 = 0
  private var detached = false
  private var backgrounded = false
  private var audioInterrupted = false
  private var hasManagedPlayers = false
  private let registryIdentity = UUID()
  private let audioOwnership: YlAudioOwnershipCoordinator

  init(makeServices: @escaping (ApplePlayerOptionsMessage) throws -> YlPlatformServices,
       makeCallbacks: @escaping (String) -> ApplePlayerFlutterApiProtocol,
       installHost: @escaping (String, ApplePlayerHostApi?) -> Void,
       lifecycle: YlLifecycleDriving? = nil,
       audioOwnership: YlAudioOwnershipCoordinator = .shared) {
    self.audioOwnership = audioOwnership
    self.makeServices = makeServices
    self.makeCallbacks = makeCallbacks
    self.installHost = installHost
    self.lifecycle = lifecycle
    lifecycle?.onSuspend = { [weak self] in self?.suspend() }
    lifecycle?.onResume = { [weak self] in self?.resume() }
    lifecycle?.onTerminate = { [weak self] in self?.detach() }
    lifecycle?.onMemoryWarning = { [weak self] in
      self?.players.values.forEach { $0.handleMemoryWarning() }
    }
    lifecycle?.start()
  }
  func create(request: AppleCreateRequest) throws -> AppleCreateReply {
    do {
      guard !detached else { throw NativePlayerError(category: "resource", code: "player.detached", message: "Plugin detached.") }
      guard request.schemaMajor == 2 else { throw NativePlayerError(category: "protocol", code: "protocol.mismatch", message: "Protocol mismatch.") }
      guard request.options.positionUpdateIntervalMs > 0,
        request.options.positionUpdateIntervalMs <= Int64(Int32.max) else { throw YlAppleFailureMapper.invalid() }
      guard nextPlayerId < Int64.max else { throw NativePlayerError(category: "resource", code: "resource.exhausted", message: "Player identifiers exhausted.") }
      // No native allocation or registration occurs before the complete preflight.
      let services = try makeServices(request.options)
      nextPlayerId += 1
      let suffix = "p\(nextPlayerId)-" + UUID().uuidString.lowercased()
      let managed = request.options.audioPolicy == .pluginManagedMediaPlayback
      let audio = managed ? YlPlayerAudioOwnership(coordinator: audioOwnership,
        key: .init(registry: registryIdentity, player: suffix)) : nil
      if managed {
        hasManagedPlayers = true
        audioOwnership.observe(registryIdentity) { [weak self] in self?.interruption($0) }
      }
      let host = YlApplePlayerHost(playerId: nextPlayerId, suffix: suffix,
        options: request.options, services: services, callbacks: makeCallbacks(suffix), audioOwnership: audio)
      var quiesced = [YlApplePlayerHost]()
      host.willCommit = { [weak self, weak host] requiresLease in
        guard let self, let host, requiresLease, services.compatibility.limitsVideoReservations else { return }
        quiesced = self.players.values.filter { $0 !== host && $0.isActive }
        quiesced.forEach { $0.quiesce() }
      }
      host.didCommit = { [weak self, weak host] in
        guard let self, let host else { return }
        quiesced.removeAll()
        self.players.values.filter { $0 !== host }.forEach { $0.deactivateForPeer() }
      }
      host.didRollback = {
        let peers = quiesced
        quiesced.removeAll()
        peers.forEach { $0.restorePeer() }
      }
      host.didDispose = { [weak self] in
        guard let self else { return }
        self.players.removeValue(forKey: suffix)
        self.installHost(suffix, nil)
      }
      players[suffix] = host
      installHost(suffix, host)
      if backgrounded || (managed && audioInterrupted) { host.suspend() }
      return AppleCreateReply(schemaMajor: 2, spiMajor: 2, channelSuffix: suffix,
        textureId: services.textureOutput.textureId,
        platform: services.platform == .ios ? .ios : .macos,
        implementationName: "yl_player_apple", implementationVersion: "0.2.0-dev.1",
        capabilities: Self.capabilities(YlBackendStateEncoder.deviceCapabilities, platform: services.platform),
        initialState: host.initialState)
    } catch let error as PigeonError { throw error }
    catch { throw YlAppleFailureMapper.command(error) }
  }
  static func capabilities(_ native: YlNativeCapabilities, platform: YlApplePlatform) -> AppleCapabilitiesMessage {
    AppleCapabilitiesMessage(deviceProfile: "apple-" + platform.rawValue,
      availableEngines: [.avPlayer, .managedFallback], decoderEvidence: .hardwareOnly,
      maxConcurrentVideoDecoders: Int64(native.maxConcurrentVideoDecoders),
      hardwareVideoCodecs: native.hardwareVideoCodecs,
      supportedOperations: [.seek, .seekToLiveEdge, .playbackSpeed, .audioTrackSelection, .videoConstraints, .volume, .stop])
  }
  func host(for suffix: String) -> YlApplePlayerHost? { players[suffix] }
  func detach() {
    guard !detached else { return }
    detached = true
    lifecycle?.stop()
    let owned = Array(players.values)
    owned.forEach { $0.close() }
    players.removeAll()
    if hasManagedPlayers { audioOwnership.releaseRegistry(registryIdentity) }
  }
  private func interruption(_ event: YlAudioInterruption) {
    guard !detached else { return }
    switch event {
    case .began:
      audioInterrupted = true
      players.values.filter(\.managesAudio).forEach { $0.suspend() }
    case let .ended(shouldResume):
      audioInterrupted = false
      let managed = players.values.filter(\.managesAudio)
      if !shouldResume { managed.forEach { $0.cancelAutomaticResume() } }
      if !backgrounded { managed.forEach { $0.resume() } }
    }
  }
  private func suspend() {
    // macOS preserves playback when the app resigns active, as before consolidation.
    guard YlApplePlatform.current == .ios else { return }
    backgrounded = true
    players.values.forEach { $0.suspend() }
  }
  private func resume() {
    if YlApplePlatform.current == .ios {
      backgrounded = false
      players.values.filter { !audioInterrupted || !$0.managesAudio }.forEach { $0.resume() }
    } else { players.values.forEach { $0.refreshState() } }
  }
}
