from pathlib import Path
import shutil

original = Path('/Users/yy2021_8689/Desktop/Flutter/yl_player')
root = Path('/private/tmp/yl-av1-20261103/source')
archive = original/'docs/superpowers/reports/evidence/2026-11-02-macos-av1-display/final-source'
native = root/'packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple'

def edit(path, before, after):
    text = path.read_text()
    assert text.count(before) == 1, (path, before)
    path.write_text(text.replace(before, after))

example = root/'packages/yl_player/example'
shutil.copy2(archive/'qual_av1.dart', example/'lib/qual_av1.dart')
shutil.copy2(archive/'MainFlutterWindow.swift', example/'macos/Runner/MainFlutterWindow.swift')
# Build only this isolated qualification application with the readback probe.
edit(example/'macos/Runner.xcodeproj/project.pbxproj',
     'SWIFT_OPTIMIZATION_LEVEL = "-O";',
     'SWIFT_OPTIMIZATION_LEVEL = "-O";') if False else None
project = example/'macos/Runner.xcodeproj/project.pbxproj'
project.write_text(project.read_text().replace('SWIFT_OPTIMIZATION_LEVEL = "-O";',
    'SWIFT_OPTIMIZATION_LEVEL = "-O";\n\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = YL_VIDEO_PERFORMANCE_PROBE;'))

# Qualification-only admission: exact fixture configuration, real identity and budgets.
services = native/'Shared/VideoToolbox/YlSoftwareDecodeServices.swift'
edit(services, 'var threads = 2', 'var threads = 1')
edit(services, 'guard !admission.entries.isEmpty, let configuration, let identity = identity() else {',
     'guard let configuration, let identity = identity() else {')
edit(services, 'guard let limits = admission.limits(for: key) else { throw YlHardwareDecoderEvidence.unavailable() }', '''
    guard key.codec == YLFCodecAV1, key.profile == 0, key.bitDepth == 8,
      key.chroma == 420, key.width == 320, key.height == 180,
      key.fpsNumerator == 24, key.fpsDenominator == 1 else {
      throw YlHardwareDecoderEvidence.unavailable()
    }
    let frozen = ProcessInfo.processInfo.environment["YL_TRIAL_LIMITS"]
    let limits = try frozen.map { try JSONDecoder().decode(YlSoftwareDecodeLimits.self, from: Data($0.utf8)) }
      ?? YlSoftwareDecodeLimits(maxOwnedBytes: 33554432, maxFrames: 64, maxPacketBytes: 1048576,
        windowNs: 1000000000, maxCpuNs: 1000000000, maxDecodeWallNs: 100000000)
    let admission = YlSoftwareDecodeAdmission(entries: [key: limits])
    print("QUAL_ID \\(identity.model) \\(identity.osBuild) \\(identity.decoderBuild) \\(frozen != nil)")
''')

decoder = native/'Shared/VideoToolbox/YlSoftwareVideoDecoder.swift'
edit(decoder, 'private var failed = false', 'private var failed = false\n  private var frameTotal = 0')
edit(decoder, 'frames.append(.init(pixelBuffer:', 'frameTotal += 1\n      frames.append(.init(pixelBuffer:')
edit(decoder, 'let start = DispatchTime.now().uptimeNanoseconds\n    let result = ylf_software_video_create',
     'print("QUAL_NATIVE_THREADS \\(native.threads)")\n    let start = DispatchTime.now().uptimeNanoseconds\n    let result = ylf_software_video_create')
edit(decoder, 'if let handle { ylf_software_video_free(handle); self.handle = nil }\n    pendingTiming',
     'if let handle { print("QUAL_DECODED \\(frameTotal)"); ylf_software_video_free(handle); self.handle = nil }\n    pendingTiming')

budget = native/'Shared/VideoToolbox/YlSoftwareDecodeBudget.swift'
edit(budget, 'private var ownedFrames = 0', '''private var ownedFrames = 0
  private var peakBytes = 0, peakFrames = 0, peakPacket = 0
  private var peakCpu: UInt64 = 0, peakWall: UInt64 = 0, lastReport: UInt64 = 0
  private func report(_ prefix: String, now: UInt64? = nil) {
    if let now { print("\\(prefix) \\(id) \\(now) \\(peakBytes) \\(peakFrames) \\(peakPacket) \\(peakCpu) \\(peakWall)") }
    else { print("\\(prefix) \\(id) \\(peakBytes) \\(peakFrames) \\(peakPacket) \\(peakCpu) \\(peakWall)") }
  }''')
edit(budget, 'pool.bytes = total.partialValue; pool.frames = frameTotal.partialValue',
     'pool.bytes = total.partialValue; pool.frames = frameTotal.partialValue\n    peakBytes = max(peakBytes, pool.bytes); peakFrames = max(peakFrames, pool.frames)\n    if frames == 0 { peakPacket = max(peakPacket, bytes) }')
edit(budget, 'guard !closed, observation.thermalNominal == true,', '''
    peakWall = max(peakWall, observation.decodeWallNs)
    if observation.thermalNominal != true || ProcessInfo.processInfo.isLowPowerModeEnabled {
      print("QUAL_BAD thermal-or-power")
    }
    guard !closed, observation.thermalNominal == true,''')
edit(budget, 'if let first = first {\n        guard',
     'if let first = first {\n        peakCpu = max(peakCpu, observation.cumulativeCpuNs - first.cumulativeCpuNs)\n        guard')
edit(budget, 'pool.history.append(observation)', '''pool.history.append(observation)
    if observation.monotonicNs - lastReport >= 2000000000 {
      lastReport = observation.monotonicNs; report("QUAL_SAMPLE", now: lastReport)
    }''')
edit(budget, 'closed = true; removeEmptyRetiredLease()\n  }',
     'report("QUAL_END"); closed = true; removeEmptyRetiredLease()\n  }')

session = native/'Shared/Session/YlManagedPlaybackSession.swift'
edit(session, 'diagnosticsEnabled: timedVideoDiagnosticsEnabled)', 'diagnosticsEnabled: true)')
scheduler = native/'Shared/Clock/YlFrameScheduler.swift'
edit(scheduler, 'droppedFrames += count', '''
    print("QUAL_DROP_DETAIL \\(reason) at=\\(ProcessInfo.processInfo.systemUptime) pts=\\(first.ptsUs) pending=\\(frames.map(\\.ptsUs))")
    print("QUAL_DROP \\(reason) \\(count)")
    droppedFrames += count''')
edit(scheduler, 'let selectedFrame = frames.removeFirst()',
     'let selectedFrame = frames.removeFirst()\n    print("QUAL_LEGACY_DEQUEUE \\(selectedFrame.ptsUs)")')

# Log only slow/invalid observations, before any application cleanup.
clock = native/'Shared/Clock/YlIsolatedAudioClock.swift'
edit(clock, 'let now = hostTimeUs()\n    lock.withLock {', '''let now = hostTimeUs()
    if duration >= 0.04 { print("QUAL_CLOCK_READ at=\\(now) seconds=\\(duration) value=\\(value)") }
    lock.withLock {''')
edit(clock, 'if !valid, expired, !stale { observed.staleEvents += 1; stale = true }', '''if !valid, expired, !stale {
          print("QUAL_CLOCK_STALE at=\\(now) frozen=\\(frozenPosition) slot=\\(String(describing: slot)) last=\\(String(describing: observed.lastObservation))")
          observed.staleEvents += 1; stale = true
        }
        if valid, stale { print("QUAL_CLOCK_RECOVERED at=\\(now) position=\\(frozenPosition)") }''')
pump = native/'Shared/Clock/YlTimedVideoPump.swift'
edit(pump, 'phases["uptime"] = started',
     'print("QUAL_PUMP_SLOW at=\\(started) phases=\\(phases) snapshot=\\(snapshot)")\n          phases["uptime"] = started')

print(root)
