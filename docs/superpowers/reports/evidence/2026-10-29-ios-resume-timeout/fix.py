from pathlib import Path
p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/AvPlayer/YlAvPlayerBackend.swift');s=p.read_text()
s=s.replace('  private var pendingRuntimeResume: (id: UUID, positionUs: Int64)?','  private var pendingRuntimeResume: (id: UUID, positionUs: Int64)?\n  private let scheduleRuntimeResumeTimeout: YlAvPlayerStallWatchdog.Scheduler')
a='''    makeVideoOutput: @escaping ([String: Any]) -> AVPlayerItemVideoOutput = { AVPlayerItemVideoOutput(pixelBufferAttributes: $0) },
    emit:''';b='''    makeVideoOutput: @escaping ([String: Any]) -> AVPlayerItemVideoOutput = { AVPlayerItemVideoOutput(pixelBufferAttributes: $0) },
    scheduleRuntimeResumeTimeout: @escaping YlAvPlayerStallWatchdog.Scheduler = { delay, action in
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    },
    emit:''';assert s.count(a)==1;s=s.replace(a,b)
s=s.replace('    self.makeVideoOutput = makeVideoOutput','    self.makeVideoOutput = makeVideoOutput\n    self.scheduleRuntimeResumeTimeout = scheduleRuntimeResumeTimeout')
s=s.replace('      if let resumeId { pendingRuntimeResume = (resumeId, targetUs) }','''      if let resumeId {
        pendingRuntimeResume = (resumeId, targetUs)
        armRuntimeResumeTimeout()
      }''')
a='''              self.pendingRuntimeResume = nil
              self.refreshFramePolicy()
''';b='''              self.pendingRuntimeResume = nil
              self.refreshFramePolicy()
              self.refreshStallWatchdog()
''';assert s.count(a)==1;s=s.replace(a,b)
s=s.replace('''      if let pending = pendingRuntimeResume {
        player.seek''','''      if let pending = pendingRuntimeResume {
        armRuntimeResumeTimeout()
        player.seek''')
a='''            self.refreshFramePolicy()
            if finished || self.videoSelection.fixedTrackId == nil { self.emitState() }''';b='''            self.refreshFramePolicy()
            self.refreshStallWatchdog()
            if finished || self.videoSelection.fixedTrackId == nil { self.emitState() }''';assert s.count(a)==1;s=s.replace(a,b)
s=s.replace('''  private func failRuntimeResume() {''','''  private func armRuntimeResumeTimeout() {
    guard let pending = pendingRuntimeResume, let item = player.currentItem else { return }
    let generation = itemGeneration, binding = callbackBinding
    let timeoutMs = configuration.network.readTimeoutMs
    // Position restoration remains an operation while paused. Only its current
    // item and seek own this deadline; transport pauses do not restart it.
    stallWatchdog.cancel()
    scheduleRuntimeResumeTimeout(TimeInterval(timeoutMs) / 1_000) { [weak self, weak item] in
      guard let self, let item, self.isCurrent(item, generation: generation),
        self.callbackBinding === binding, self.active, !self.stopped,
        self.pendingRuntimeResume?.id == pending.id else { return }
      self.recordPlaybackDiagnostic(event: "resumeSeekTimeout")
      self.failRuntimeResume(timeoutMs: timeoutMs)
    }
  }

  private func failRuntimeResume(timeoutMs: Int64? = nil) {''')
a='''    reportRestorationFailure(NativePlayerError(category: "source", code: "source.seek_failed",
      message: "The playback position could not be restored."))''';b='''    reportRestorationFailure(NativePlayerError(category: "source", code: "source.seek_failed",
      message: "The playback position could not be restored.",
      diagnostic: timeoutMs.map { "AVPlayer(phase=resumeSeek, timeoutMs=\\($0))" }))''';assert s.count(a)==1;s=s.replace(a,b)
s=s.replace('''    stallWatchdog.update(
      active: active,''','''    stallWatchdog.update(
      active: active && pendingRuntimeResume == nil,''')
s=s.replace('''    guard failureGate.begin(generation: generation),
          failureGate.finish(''','''    guard pendingRuntimeResume == nil, failureGate.begin(generation: generation),
          failureGate.finish(''')
p.write_text(s)
