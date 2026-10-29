from pathlib import Path
import sys
base=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Session')
for name in ['YlApplePlayerHost.swift','YlAppleSessionCoordinator.swift']:
 p=base/name;s=p.read_text();needle='       beforeFallbackConstruction: ((YlPlaybackBackend) throws -> Void)? = nil,'
 s=s.replace(needle,'       makeAvPlayerVideoOutput: @escaping ([String: Any]) -> AVPlayerItemVideoOutput = { AVPlayerItemVideoOutput(pixelBufferAttributes: $0) },\n'+needle,1)
 if name=='YlApplePlayerHost.swift':s=s.replace('      beforeFallbackConstruction: beforeFallbackConstruction,','      makeAvPlayerVideoOutput: makeAvPlayerVideoOutput, beforeFallbackConstruction: beforeFallbackConstruction,',1)
 else:s=s.replace('configuration: configuration, player: avPlayer, emit:', 'configuration: configuration, player: avPlayer, makeVideoOutput: makeAvPlayerVideoOutput, emit:',1)
 p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text().replace('    let output = AppleTestTexture()\n    var tick:', '    let output = AppleTestTexture()\n    let presentationTimes = AbrPublishedFrameTimes()\n    var tick:',1).replace('callbacks: publicCallbacks, avPlayer: player)','callbacks: publicCallbacks, avPlayer: player,\n        makeAvPlayerVideoOutput: { AbrTimestampVideoOutput(attributes: $0, times: presentationTimes) })',1)
s=s.replace('        output.frames.removeAll(keepingCapacity: true)\n        if let pixels', '''        let framePresentationTimes: [Any] = output.frames.map {
          presentationTimes.take($0).map { $0 as Any } ?? NSNull()
        }
        output.frames.removeAll(keepingCapacity: true)
        if let pixels''',1).replace('"generation": frameGeneration, "frames": count, "width": width, "textureClears": output.clears,','"generation": frameGeneration, "frames": count, "width": width, "textureClears": output.clears,\n          "framePresentationTimes": framePresentationTimes,',1).replace('"due": ticket.due, "generation": ticket.generation, "positionBefore": before.position,','"due": ticket.due, "generation": ticket.generation, "ticketIntentRevision": ticket.intentRevision, "positionBefore": before.position,',1)
s+='''
// Test-only timestamps from AVPlayerItemVideoOutput, bound to buffers actually
// published by the backend. Player.currentTime() is not frame presentation time.
private final class AbrPublishedFrameTimes: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [ObjectIdentifier: (CVPixelBuffer, Double)] = [:]
  func record(_ buffer: CVPixelBuffer, time: CMTime) {
    lock.lock(); defer { lock.unlock() }
    if values.count >= 64 { values.removeAll(keepingCapacity: true) }
    let key = ObjectIdentifier(buffer)
    let seconds = CMTimeGetSeconds(time)
    values.removeValue(forKey: key)
    if time.isValid && seconds.isFinite && seconds >= 0 { values[key] = (buffer, seconds) }
  }
  func take(_ buffer: CVPixelBuffer) -> Double? {
    lock.lock(); defer { lock.unlock() }
    return values.removeValue(forKey: ObjectIdentifier(buffer))?.1
  }
}

private final class AbrTimestampVideoOutput: AVPlayerItemVideoOutput, @unchecked Sendable {
  private let times: AbrPublishedFrameTimes
  init(attributes: [String: Any], times: AbrPublishedFrameTimes) {
    self.times = times
    super.init(pixelBufferAttributes: attributes)
  }
  override func copyPixelBuffer(forItemTime itemTime: CMTime,
    itemTimeForDisplay outItemTimeForDisplay: UnsafeMutablePointer<CMTime>?) -> CVPixelBuffer? {
    var displayTime = CMTime.invalid
    let buffer = super.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime)
    outItemTimeForDisplay?.pointee = displayTime
    if let buffer { times.record(buffer, time: displayTime) }
    return buffer
  }
}
'''
p.write_text(s)
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path(f'packages/yl_player/example/{platform}/RunnerTests')/p.name).write_bytes(native_test_source(p))
p=Path('tool/playback_network/abr_accesslog.py');s=p.read_text().replace('    rates = []; anchor = None; qualified = 0\n', '''    rates = []; anchor = None; qualified = 0
    has_revision = any(isinstance(r,dict) and 'intentRevision' in r for r in rows)
    revision = None; intent_samples = []; ticket_authorities = []
''',1).replace("        reason = row['reason']; elapsed = row.get('elapsed')",'''        if has_revision:
            value = row.get('intentRevision')
            require(type(value) is int and 0 <= value < 2**64 and (revision is None or value >= revision))
            if revision is not None and value != revision:
                anchor = None; qualified = 0; pending = None
            revision = value
            intent_samples.append(dict(elapsed=row.get('elapsed'), intentRevision=revision))
        reason = row['reason']; elapsed = row.get('elapsed')''',1).replace("            pending = (budget, row['generation'], due); reservations += 1","            pending = (budget, row['generation'], due, revision); reservations += 1",1).replace("pending[1] == row['generation'] and elapsed >= pending[2])","pending[1] == row['generation'] and elapsed >= pending[2] and pending[3] == revision)",1).replace('                pending = None; tickets += 1','                pending = None; tickets += 1\n                if has_revision: ticket_authorities.append(dict(attempt=budget,elapsed=elapsed,intentRevision=revision))',1).replace('reservations=reservations, tickets=tickets, triggerExercised=tickets > 0,','reservations=reservations, tickets=tickets, triggerExercised=tickets > 0,\n        intentSamples=intent_samples, ticketAuthorities=ticket_authorities,',1)
s=s.replace("    previous=0\n    for r in rows:","""    require(type(e.get('ticketIntentRevision')) is int and e['ticketIntentRevision']==before)
    authorities=policy.get('ticketAuthorities');samples=policy.get('intentSamples')
    require(isinstance(authorities,list) and len(authorities)==len(events) and isinstance(samples,list) and samples)
    for event,authority in zip(events,authorities):
        require(authority.get('attempt')==event.get('attempt') and
                authority.get('intentRevision')==event.get('ticketIntentRevision') and
                finite(authority.get('elapsed')) and abs(authority['elapsed']-event['elapsed'])<=.05)
    def validate_revisions(trace,key):
        previous_revision=None
        require(any(r['elapsed']<=e['publicCommandStartedElapsed'] for r in trace) and
                any(r['elapsed']>=e['publicCommandCompletedElapsed'] for r in trace))
        for r in trace:
            revision=r.get(key)
            require(type(revision) is int and 0<=revision<2**64 and
                    (previous_revision is None or revision>=previous_revision))
            require(revision in (before,after))
            if r['elapsed']<=e['publicCommandStartedElapsed']:require(revision==before)
            if r['elapsed']>=e['publicCommandCompletedElapsed']:require(revision==after)
            previous_revision=revision
    validate_revisions(rows,'publicIntentRevision')
    validate_revisions(samples,'intentRevision')
    previous=0
    for r in rows:""",1)
s=s.replace("    if scenario=='seek-during-preparation':require(all(f['position']>=target/1000-.05 for f in published))", """    if scenario=='seek-during-preparation':
        for f in published:
            pts=f.get('framePresentationTimes')
            require(isinstance(pts,list) and len(pts)==f['frames'] and
                    all(finite(t) and t>=target/1000-.05 for t in pts))
        require(all(f['position']>=target/1000-.05 for f in published))""",1)
p.write_text(s)
