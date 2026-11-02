from pathlib import Path
r=Path('/private/tmp/yl-av1-single');root=r/'lab/packages/yl_player_apple'
p=next(root.rglob('YlPresentationCoordinator.swift'));s=p.read_text();s=s.replace('  func dropProbe() -> String {','''  private let probeLock = NSLock()
  private var probeSamples: [String] = []
  private var probeTimer: DispatchSourceTimer?
  var dropProbeHistory: [String] { probeLock.withLock { probeSamples } }
  func dropProbe() -> String {''',1)
s=s.replace('    YlTimedDropProbe.coordinator = self','''    YlTimedDropProbe.coordinator = self
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.ylplayer.queue-probe"))
    timer.setEventHandler { [weak self] in
      guard let self, self.isolatedAudioClockStatistics != nil else { return }
      let sample = "uptime=\\(ProcessInfo.processInfo.systemUptime) \\(self.dropProbe())"
      self.probeLock.withLock {
        self.probeSamples.append(sample)
        if self.probeSamples.count > 40 { self.probeSamples.removeFirst() }
      }
    }
    timer.schedule(deadline: .now(), repeating: .milliseconds(50))
    probeTimer = timer
    timer.resume()''',1)
s=s.replace('  func disposeFrames() {','  func disposeFrames() { probeTimer?.cancel();',1);p.write_text(s)
p=next(root.rglob('YlFrameScheduler.swift'));s=p.read_text().replace('    print("QUAL_DROP_PROBE",','    print("QUAL_DROP_HISTORY", YlTimedDropProbe.coordinator?.dropProbeHistory as Any)\n    print("QUAL_DROP_PROBE",',1);p.write_text(s)
p=next(root.rglob('YlTimedVideoPump.swift'));s=p.read_text().replace('struct YlTimedVideoStatistics {','struct YlTimedVideoStatistics {\n  var activePhase = "idle"\n  var phaseBegan = 0.0',1)
s=s.replace('  private func tick() {','''  private func markPhase(_ phase: String) {
    stateLock.withLock { observed.activePhase = phase; observed.phaseBegan = ProcessInfo.processInfo.systemUptime }
  }
  private func tick() {''',1)
s=s.replace('    let snapshot = clockSnapshot()','    markPhase("clock")\n    let snapshot = clockSnapshot()',1)
s=s.replace('    endpoint.update(snapshot, generation: generation)','    markPhase("update")\n    endpoint.update(snapshot, generation: generation)',1)
s=s.replace('          held = scheduler.nextFrame','          markPhase("scheduler")\n          held = scheduler.nextFrame',1)
s=s.replace('        let accepted = endpoint.enqueue(frame)','        markPhase("enqueue")\n        let accepted = endpoint.enqueue(frame)',1)
s=s.replace('    let pending = held != nil','    markPhase("idle")\n    let pending = held != nil',1);p.write_text(s)
p=root/'darwin/yl_player_apple/Sources/yl_player_apple/Shared/Session/YlManagedPlaybackSession.swift';s=p.read_text().replace('diagnosticsEnabled: timedVideoDiagnosticsEnabled)','diagnosticsEnabled: true)',1);p.write_text(s)
p=r/'lab/packages/yl_player/example/lib/qual_av1.dart';s=p.read_text().replace('    Future<void> systemMetrics({bool finalSample = false}) async {','''    final queueDiagnostic = Platform.environment['YL_QUEUE_DIAGNOSTIC'] == '1';
    Future<void> systemMetrics({bool finalSample = false}) async {''',1)
s=s.replace("      if (m['windowOcclusions']", "      if (!queueDiagnostic && (m['windowOcclusions']",1).replace("(finalSample && (m['totalFrames'] ?? 0) <= 0)) {","(finalSample && (m['totalFrames'] ?? 0) <= 0))) {",1);p.write_text(s)
q=r/'queue-history-diagnostic';q.mkdir();(q/'optimized').symlink_to(r/'optimized',target_is_directory=True)
for name in ('measure.py','protocol.json'):(q/name).write_bytes((r/'projected-timeout-diagnostic'/name).read_bytes())
p=q/'measure.py';s=p.read_text().replace("env['YL_AV1_VISIBLE_QUALIFICATION']='1'","env['YL_AV1_VISIBLE_QUALIFICATION']='1'\nenv['YL_QUEUE_DIAGNOSTIC']='1'");p.write_text(s)
