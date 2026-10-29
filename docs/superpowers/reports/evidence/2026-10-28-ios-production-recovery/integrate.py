from pathlib import Path
root=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple')
p=root/'Engines/AvPlayer/YlAvPlayerBackend.swift';s=p.read_text().replace('import QuartzCore','import QuartzCore\n#if os(iOS)\nimport UIKit\n#endif');s=s.replace('  var onAutomaticFallback:', '  var onDashRecoveryInvalidated: (() -> Void)?\n  var onAutomaticFallback:')
for signature in ['  func pause() throws {','  func seek(toMs milliseconds: Int64, cancellationToken: YlOpenCancellationToken? = nil) throws {']:
 s=s.replace(signature,signature+'\n    onDashRecoveryInvalidated?()')
i=s.index('  private func emitStateDelta()')
method='''  /// One native sample owns output geometry, buffer, counters and item authority.
  /// Ambiguous geometry or a non-legacy DASH path has no recovery authority.
  func dashRecoverySample(now: Double, intentRevision: UInt64, credentialRevision: UInt64) -> YlDashAutoRecoveryPolicy.Sample? {
    guard let item = player.currentItem, let source = lastSource,
      let catalog = dashVideoCatalog, hlsResourceLoader != nil,
      !source.isLive, !source.airPlay, source.drm == nil,
      YlSourceRouter.route(source) == .dashHls else { return nil }
    let position = CMTimeGetSeconds(player.currentTime())
    let duration = CMTimeGetSeconds(item.duration)
    guard position.isFinite, position >= 0, duration.isFinite, duration > 0 else { return nil }
    let audioBandwidth = dashAudioCatalog?.compactMap(\\.bitrate).max() ?? 0
    let tracks = catalog.tracks(at: currentPositionUs())
    let variants: [YlDashAutoRecoveryPolicy.Variant] = tracks.compactMap { track in
      guard let width = track.width, let height = track.height, let bitrate = track.bitrate,
            width > 0, height > 0, bitrate > 0, audioBandwidth >= 0 else { return nil }
      return .init(id: track.id, width: width, height: height, bandwidth: Double(bitrate) + Double(audioBandwidth))
    }.sorted { $0.id < $1.id }
    let matches = variants.filter { Double($0.width) == item.presentationSize.width && Double($0.height) == item.presentationSize.height }
    let current = matches.count == 1 ? matches[0] : nil
    let logs = item.accessLog()?.events ?? []
    var bytes: Int64 = 0, requests = 0, overdue = 0
    for log in logs {
      let b = bytes.addingReportingOverflow(log.numberOfBytesTransferred)
      let r = requests.addingReportingOverflow(log.numberOfMediaRequests)
      let o = overdue.addingReportingOverflow(log.downloadOverdue)
      guard !b.overflow, !r.overflow, !o.overflow else { return nil }
      bytes = b.partialValue; requests = r.partialValue; overdue = o.partialValue
    }
    var foreground = false
    #if os(iOS)
    foreground = UIApplication.shared.applicationState == .active
    #endif
    let allowed = foreground && active && !stopped && !disposed && currentError == nil && firstFrameSent
      && playRequested && player.rate > 0 && desiredRate == 1 && item.status == .readyToPlay
      && item.isPlaybackLikelyToKeepUp && pendingUserSeek == nil && pendingRuntimeResume == nil
      && qualityConstraint == .unconstrained && videoSelection.fixedTrackId == nil
      && item.preferredPeakBitRate == 0 && item.preferredMaximumResolution == .zero
      && !player.isExternalPlaybackActive
    return .init(time: now, generation: itemGeneration, allowed: allowed,
      catalog: variants, current: current, position: position, remaining: duration - position,
      bufferAhead: YlDashAutoRecoveryPolicy.contiguousAhead(position: position, ranges: item.loadedTimeRanges.map {
        (CMTimeGetSeconds($0.timeRangeValue.start), CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRangeValue)))
      }), bytes: bytes, transfer: logs.reduce(0) { $0 + $1.transferDuration }, requests: requests, overdue: overdue,
      intentRevision: intentRevision, credentialRevision: credentialRevision)
  }

'''
s=s[:i]+method+s[i:];p.write_text(s)
p=root/'Shared/Session/YlOpenCoordinator.swift';s=p.read_text();i=s.index('  func cancelCurrent()');s=s[:i]+'  var hasCurrent: Bool { lock.withLock { current != nil } }\n\n'+s[i:];p.write_text(s)
p=root/'Shared/Session/YlAppleSessionCoordinator.swift';s=p.read_text().replace('import YlFFmpegBridge','import YlFFmpegBridge\n#if os(iOS)\nimport UIKit\n#endif');s=s.replace('  private let capsCoordinator', '''  private let dashRecovery = YlDashAutoRecoveryController()
  private var dashRecoveryTimer: Timer?
  private var dashRecoveryObserver: NSObjectProtocol?
  private var dashRecoveryRevision: UInt64 = 0
  private var dashRecoveryScope: String?
  var dashRecoveryDecision: [String: Any] { dashRecovery.policy.decision }
  var dashRecoveryEvents: [[String: Any]] { dashRecovery.events }
  var dashRecoveryAttempts: Int { dashRecovery.policy.attempts }
  private let capsCoordinator''')
s=s.replace('       beforeDashCapsPreparation:', '       automaticDashRecoveryEnabled: Bool = true,\n       beforeDashCapsPreparation:')
s=s.replace('    avBackend.onAutomaticFallback = { [weak self] in self?.capsCoordinator.cancelCurrent() }','''    avBackend.onAutomaticFallback = { [weak self] in self?.capsCoordinator.cancelCurrent(); self?.invalidateDashRecovery() }
    avBackend.onDashRecoveryInvalidated = { [weak self] in self?.invalidateDashRecovery() }
    #if os(iOS)
    if services.platform == .ios && automaticDashRecoveryEnabled {
      let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.pollDashRecovery() }
      RunLoop.main.add(timer, forMode: .common); dashRecoveryTimer = timer
      dashRecoveryObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
        object: nil, queue: .main) { [weak self] _ in self?.invalidateDashRecovery() }
    }
    #endif''')
s=s.replace('    startTraffic(source)\n    beginOpen', '    invalidateDashRecovery()\n    startTraffic(source)\n    beginOpen')
s=s.replace('    let policy: (YlAppleVideoConstraints, YlNativeVideoSelection)?', '    invalidateDashRecovery()\n    let policy: (YlAppleVideoConstraints, YlNativeVideoSelection)?')
for signature in ['  func stop() {','  func deactivate() {','  func handleMemoryWarning() {','  func restoreAfterHardwareDecoderRollback(forcePlay: Bool? = nil) {']:
 s=s.replace(signature,signature+'\n    invalidateDashRecovery()')
s=s.replace('    disposed = true\n    stopTraffic()', '''    disposed = true
    invalidateDashRecovery()
    dashRecoveryTimer?.invalidate(); dashRecoveryTimer = nil
    if let observer = dashRecoveryObserver { NotificationCenter.default.removeObserver(observer) }
    dashRecoveryObserver = nil
    stopTraffic()''')
s+='''
private extension YlAppleSessionCoordinator {
  func invalidateDashRecovery() {
    dashRecoveryRevision &+= 1
    dashRecovery.invalidate()
  }

  func recoverySample() -> YlDashAutoRecoveryPolicy.Sample? {
    guard !disposed, pendingLoadRequestId == nil, identity != nil,
      activeRestorationGeneration == nil, slot.current === avBackend,
      !capsCoordinator.hasCurrent, !commandCoordinator.hasCurrent,
      lastQualityConstraint == .unconstrained,
      let source = lastCommittedSource, route(for: source) == .dashHls,
      !source.isLive, !source.airPlay, source.drm == nil,
      let credentials = committedHlsCredentials, committedDashSnapshot != nil else { return nil }
    return avBackend.dashRecoverySample(now: ProcessInfo.processInfo.systemUptime,
      intentRevision: dashRecoveryRevision, credentialRevision: credentials.revision)
  }

  func pollDashRecovery() {
    guard let identity, let source = lastCommittedSource, let credentials = committedHlsCredentials,
          let snapshot = committedDashSnapshot else { dashRecovery.invalidate(); return }
    if dashRecoveryScope != identity.loadRequestId {
      dashRecovery.resetForSource(); dashRecoveryScope = identity.loadRequestId
    }
    let revision = dashRecoveryRevision
    let credentialRevision = credentials.revision
    dashRecovery.tick(recoverySample(), prepare: { [weak self] token in
      guard let self else { throw YlOpenCancellationToken.cancellationError() }
      // Reuse the committed immutable projection and its credential history.
      // A fresh loader/asset resets AVPlayer's item without refetching a new MPD.
      return .headeredHls(source: source, prepared: try self.prepareHeaderedHls(source: source,
        token: token, credentialContext: credentials, videoConstraints: .unconstrained, dashSnapshot: snapshot))
    }, currentSample: { [weak self] in self?.recoverySample() }, commit: { [weak self] candidate in
      guard let self, self.identity == identity, self.dashRecoveryRevision == revision,
        self.committedHlsCredentials === credentials, self.pendingLoadRequestId == nil,
        self.slot.current === self.avBackend, self.avBackend.isActive,
        case let .headeredHls(_, prepared) = candidate else { throw YlOpenCancellationToken.cancellationError() }
      let accepted = try credentials.withUnchangedRevision(credentialRevision) {
        try self.avBackend.replaceActiveDash(source: source, prepared: prepared)
      }
      guard accepted else { throw YlOpenCancellationToken.cancellationError() }
    })
  }
}
''';p.write_text(s)
p=root/'Shared/Session/YlApplePlayerHost.swift';s=p.read_text();s=s.replace('       makeAvPlayerVideoOutput:', '       automaticDashRecoveryEnabled: Bool = true,\n       makeAvPlayerVideoOutput:',1);s=s.replace('textureOwner: textureOwner, avPlayer: avPlayer, commandCoordinator: commandCoordinator,','textureOwner: textureOwner, avPlayer: avPlayer, commandCoordinator: commandCoordinator,\n      automaticDashRecoveryEnabled: automaticDashRecoveryEnabled,');i=s.index('  var acknowledgedTransportRevision');s=s[:i]+'''  var dashRecoveryDecision: [String: Any] { coordinator.dashRecoveryDecision }
  var dashRecoveryEvents: [[String: Any]] { coordinator.dashRecoveryEvents }
  var dashRecoveryAttempts: Int { coordinator.dashRecoveryAttempts }
'''+s[i:];p.write_text(s)
