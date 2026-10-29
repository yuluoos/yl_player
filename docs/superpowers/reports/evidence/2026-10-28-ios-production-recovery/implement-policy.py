from pathlib import Path
p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/AvPlayer/YlDashAutoRecoveryPolicy.swift');stub=p.read_text();Path('/private/tmp/yl-production-recovery/policy-red-source.swift').write_text(stub)
source=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift').read_text();s=source[source.index('  private(set) var attempts = 0'):source.index('\nprivate final class AbrHeldMetadataLoader')]
s=s.replace('private var generation: Int?', 'private var generation: UInt64?')
s=s.replace('  private var sawHigh = false','  private var sawHigh = false\n  private var catalog: [Variant] = []\n  private var target: Variant?')
s=s.replace('s.allowed && s.time.isFinite', '''s.allowed && s.catalog.count >= 2 && Set(s.catalog.map(\\.id)).count == s.catalog.count &&
      s.catalog.allSatisfy { $0.width > 0 && $0.height > 0 && $0.bandwidth.isFinite && $0.bandwidth > 0 } &&
      s.current.map { s.catalog.contains($0) } == true && s.time.isFinite''')
s=s.replace('"width": s.width','"width": s.current?.width ?? 0')
s=s.replace('if generation != s.generation {','if generation != s.generation || catalog != s.catalog {\n      catalog = s.catalog\n      target = catalog.max { $0.bandwidth < $1.bandwidth }')
s=s.replace('if s.width == 640 {', 'if s.current == target {')
s=s.replace('guard sawHigh, s.width == 320, s.overdue > 0 else { reason = !sawHigh ? "highNotObserved" : (s.width != 320 ? "notLowOutput" : "noOverdue");', 'guard sawHigh, let target, let current = s.current, current.bandwidth < target.bandwidth, s.overdue > 0 else { reason = !sawHigh ? "highNotObserved" : (s.overdue == 0 ? "noOverdue" : "notLowOutput");')
s=s.replace('bitrate >= 764_000 * 1.25', 'bitrate >= target.bandwidth * 1.25')
s=s.replace('credentialRevision: s.credentialRevision)', 'credentialRevision: s.credentialRevision, catalog: s.catalog)')
s=s.replace('eligible(s) && s.width == 320 && s.generation', 'eligible(s) && s.catalog == ticket.catalog && s.current.map { $0.bandwidth < (target?.bandwidth ?? 0) } == true && s.generation')
header=stub[:stub.index('  private(set) var attempts')]
p.write_text(header+s+'\n')
