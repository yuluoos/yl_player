from pathlib import Path
r=Path('/private/tmp/yl-av1-single');root=r/'lab/packages/yl_player_apple'
p=next(root.rglob('YlIsolatedAudioClock.swift'));s=p.read_text();s=s.replace('struct YlIsolatedAudioClockStatistics {','''enum YlAudioReadProbe {
  private static let lock = NSLock()
  private static var phase = "idle"
  private static var began = 0.0
  static func mark(_ next: String) {
    guard Thread.current.threadDictionary["yl.audio.read.probe"] as? Bool == true else { return }
    let now = ProcessInfo.processInfo.systemUptime
    lock.withLock {
      if phase != "idle", now-began > 0.04 { print("QUAL_AUDIO_READ", phase, began, now, now-began) }
      phase = next; began = now
    }
  }
  static var snapshot: String { lock.withLock { "phase=\\(phase) began=\\(began)" } }
}
struct YlIsolatedAudioClockStatistics {''',1)
s=s.replace('    let value = read(permit.0)','''    Thread.current.threadDictionary["yl.audio.read.probe"] = true
    YlAudioReadProbe.mark("read.entry")
    let value = read(permit.0)
    YlAudioReadProbe.mark("idle")
    Thread.current.threadDictionary.removeObject(forKey: "yl.audio.read.probe")''',1);p.write_text(s)
p=next(root.rglob('YlPresentationCoordinator.swift'));s=p.read_text().replace('return "clock=','return "native=\\(YlAudioReadProbe.snapshot) clock=',1);p.write_text(s)
p=next(root.rglob('YlManagedPlaybackSession.swift'));s=p.read_text().replace('        guard let self, let resource = self.audio.currentResource else { return .waiting }','''        YlAudioReadProbe.mark("resource")
        guard let self, let resource = self.audio.currentResource else { return .waiting }''',1).replace('        resource.advanceSilence(through: self.presentation.pendingFrames.last,','''        YlAudioReadProbe.mark("videoCoverage")
        let coverage = self.presentation.pendingFrames.last
        YlAudioReadProbe.mark("advanceSilence")
        resource.advanceSilence(through: coverage,''',1).replace('        return resource.clockObservation(expectedGeneration: generation)','        YlAudioReadProbe.mark("clockObservation")\n        return resource.clockObservation(expectedGeneration: generation)',1);p.write_text(s)
p=next(root.rglob('YlAudioRenderer.swift'));s=p.read_text().replace('  func clockObservation(expectedGeneration: UInt64) -> YlAudioClockObservation {\n    lock.lock()','  func clockObservation(expectedGeneration: UInt64) -> YlAudioClockObservation {\n    YlAudioReadProbe.mark("renderer.lock")\n    lock.lock()',1).replace('    let raw = renderedOutputTime // Never under renderer/session/snapshot lock.','    YlAudioReadProbe.mark("renderedOutputTime")\n    let raw = renderedOutputTime // Never under renderer/session/snapshot lock.\n    YlAudioReadProbe.mark("renderer.validate")',1)
s=s.replace('''    guard configured, !disposed, let outputTime = engine.outputNode.lastRenderTime,
          outputTime.isHostTimeValid,
          let playerTime = player.playerTime(forNodeTime: AVAudioTime(hostTime: outputTime.hostTime)),''','''    guard configured, !disposed else { return nil }
    YlAudioReadProbe.mark("engine.outputNode")
    let outputNode = engine.outputNode
    YlAudioReadProbe.mark("outputNode.lastRenderTime")
    guard let outputTime = outputNode.lastRenderTime, outputTime.isHostTimeValid else { return nil }
    YlAudioReadProbe.mark("player.playerTime")
    guard let playerTime = player.playerTime(forNodeTime: AVAudioTime(hostTime: outputTime.hostTime)),''',1)
p.write_text(s)
q=r/'queue-native-read-diagnostic';q.mkdir();(q/'optimized').symlink_to(r/'optimized',target_is_directory=True)
for name in ('measure.py','protocol.json'):(q/name).write_bytes((r/'queue-history-diagnostic'/name).read_bytes())
