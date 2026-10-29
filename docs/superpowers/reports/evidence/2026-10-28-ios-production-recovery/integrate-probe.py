from pathlib import Path
import sys
root=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple')
p=root/'Engines/AvPlayer/YlDashAutoRecoveryController.swift';s=p.read_text().replace('  private(set) var policy', '  var onDecision: (([String: Any]) -> Void)?\n  private(set) var policy');s=s.replace('commit: @escaping YlOpenCoordinator.Commit)', 'commit: @escaping (YlPreparedOpen) throws -> [String: Any])');s=s.replace('    let ticket = policy.observe(sample)', '    let ticket = policy.observe(sample)\n    onDecision?(policy.decision)');s=s.replace('      try commit(candidate)','      let details = try commit(candidate)\n      for key in ["itemChanged", "credentialCommitAccepted"] { event[key] = details[key] }');p.write_text(s)
p=root/'Engines/AvPlayer/YlAvPlayerBackend.swift';s=p.read_text().replace('  func dashRecoverySample(', '  var dashRecoveryItemGeneration: UInt64 { itemGeneration }\n  func dashRecoverySample(').replace('let allowed = foreground && active', 'let allowed = current != nil && foreground && active');p.write_text(s)
p=root/'Shared/Session/YlAppleSessionCoordinator.swift';s=p.read_text().replace('  var dashRecoveryDecision:', '''  var onDashRecoveryDecision: (([String: Any]) -> Void)? {
    get { dashRecovery.onDecision }
    set { dashRecovery.onDecision = newValue }
  }
  var dashRecoveryDecision:''');s=s.replace('      let accepted = try credentials.withUnchangedRevision(credentialRevision) {','      let generation = self.avBackend.dashRecoveryItemGeneration\n      let accepted = try credentials.withUnchangedRevision(credentialRevision) {');s=s.replace('      guard accepted else { throw YlOpenCancellationToken.cancellationError() }\n    })','      guard accepted else { throw YlOpenCancellationToken.cancellationError() }\n      return ["itemChanged": generation != self.avBackend.dashRecoveryItemGeneration, "credentialCommitAccepted": accepted]\n    })');p.write_text(s)
p=root/'Shared/Session/YlApplePlayerHost.swift';s=p.read_text().replace('  var dashRecoveryDecision:', '''  var onDashRecoveryDecision: (([String: Any]) -> Void)? {
    get { coordinator.onDashRecoveryDecision }
    set { coordinator.onDashRecoveryDecision = newValue }
  }
  var dashRecoveryDecision:''');p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text().replace('commit: { _ in committed.fulfill() })','commit: { _ in committed.fulfill(); return [:] })').replace('commit: { _ in installs += 1 })','commit: { _ in installs += 1; return [:] })')
i=s.index('    // Preserve the historical managed probe')
s=s[:i]+'''    let productionRecovery = env["YL_ABR_PROBE_PRODUCTION_RECOVERY"] == "1"
    guard !productionRecovery || (captureDeviceKind == "physical" && !direct && !publicPolicyCycle && !publicPolicyRace
      && programmeSeconds == 120 && recoveryAction == "auto-reload" && candidatePreparation == "manifest-only"
      && autoScenario == "normal" && startupDelayMs == 0) else { XCTFail("Invalid production recovery capture"); return }
    let productionEpoch = ProcessInfo.processInfo.systemUptime
    var productionPolicyFile: FileHandle?
    var productionPolicyWriteFailed = false
    if productionRecovery {
      let path = directory.appendingPathComponent("policy-decisions.jsonl")
      _ = FileManager.default.createFile(atPath: path.path, contents: nil)
      productionPolicyFile = try FileHandle(forWritingTo: path)
    }
    defer { try? productionPolicyFile?.close() }
    func productionEvent(_ input: [String: Any]) -> [String: Any] {
      var result = input
      for key in ["elapsed", "elapsedAfter", "due", "preparationDeadline"] {
        if let value = result[key] as? Double { result[key] = value - productionEpoch }
      }
      return result
    }
'''+s[i:]
s=s.replace('if direct || publicPolicyCycle || publicPolicyRace {','if direct || publicPolicyCycle || publicPolicyRace || productionRecovery {')
s=s.replace('if publicPolicyCycle || publicPolicyRace {','if publicPolicyCycle || publicPolicyRace || productionRecovery {')
s=s.replace('callbacks: publicCallbacks, avPlayer: player,','callbacks: publicCallbacks, avPlayer: player, automaticDashRecoveryEnabled: productionRecovery,')
s=s.replace('      publicHost = host\n      try host.attach()', '''      publicHost = host
      if productionRecovery {
        host.onDashRecoveryDecision = { decision in
          var row = decision
          for key in ["elapsed", "pendingDue"] {
            if let value = row[key] as? Double { row[key] = value - productionEpoch }
          }
          do { try productionPolicyFile?.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])) }
          catch { productionPolicyWriteFailed = true }
        }
      }
      try host.attach()''')
s=s.replace('    let started = ProcessInfo.processInfo.systemUptime\n    #if os(iOS)', '    let started = productionRecovery ? productionEpoch : ProcessInfo.processInfo.systemUptime\n    #if os(iOS)')
s=s.replace('    if recoveryAction == "auto-reload" {\n      _ = FileManager', '    if recoveryAction == "auto-reload" && !productionRecovery {\n      _ = FileManager')
s=s.replace('"automaticAttempts": automaticPolicy.attempts, "automaticEvents": automaticEvents,','"automaticAttempts": productionRecovery ? (publicHost?.dashRecoveryAttempts ?? 0) : automaticPolicy.attempts,\n        "automaticEvents": productionRecovery ? (publicHost?.dashRecoveryEvents.map(productionEvent) ?? []) : automaticEvents,\n        "productionRecovery": productionRecovery,')
s=s.replace('    XCTAssertFalse(frameWriteFailed)','    XCTAssertFalse(frameWriteFailed)\n    XCTAssertFalse(productionPolicyWriteFailed)')
p.write_text(s);sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path('packages/yl_player/example')/platform/'RunnerTests'/p.name).write_bytes(native_test_source(p))
p=Path('tool/playback_network/abr_accesslog.py');s=p.read_text();start=s.index('def production_recovery');end=s.index('def policy_trace_version')
s=s[:start]+'''def production_recovery(args):
    enabled = getattr(args, 'production_recovery', False)
    if type(enabled) is not bool: raise ValueError('invalid production recovery selection')
    if not enabled: return False
    if (not getattr(args, 'physical_device', None) or getattr(args, 'duration_seconds', None) != 120 or
        getattr(args, 'recovery_action', None) != 'auto-reload' or getattr(args, 'auto_scenario', None) != 'normal' or
        getattr(args, 'candidate_preparation', None) != 'manifest-only' or getattr(args, 'startup_delay_ms', 0) != 0 or
        any(getattr(args, key, False) for key in ('public_policy_cycle', 'public_policy_race', 'direct_hls_control'))):
        raise ValueError('production recovery requires physical normal 120s capture')
    return True


def summarize_production_recovery(rows, frames):
    def require(value):
        if not value: raise ValueError('invalid production recovery evidence')
    require(bool(rows) and bool(frames))
    session = rows[0].get('sessionId')
    require(isinstance(session, str) and bool(session))
    require(all(r.get('productionRecovery') is True and r.get('captureDeviceKind') == 'physical' and
        r.get('sessionId') == session and r.get('publicPolicyCycle') is False and
        r.get('publicPolicyRace') is False and r.get('hostFailureCount') == 0 for r in rows))
    lows = [r['elapsed'] for r in rows if r.get('width') == 320]
    require(bool(lows) and any(f.get('frames', 0) > 0 and f.get('width') == 640 and f['elapsed'] > min(lows) for f in frames))
    installed = [e for e in rows[-1]['automaticEvents'] if e['outcome'] == 'installed']
    for event in installed:
        require(event.get('itemChanged') is True and event.get('credentialCommitAccepted') is True)
        require(any(f.get('frames', 0) > 0 and f.get('width') == 640 and f['elapsed'] > event['elapsedAfter'] for f in frames))
    return dict(installed=len(installed), triggerExercised=bool(installed), publicSessionUnchanged=True,
                highFramesAfterRecovery=True, capabilityAccepted=False, physicalOutputVerified=False)


'''+s[end:]
s=s.replace('        cycle = public_policy_cycle(args)', '        production = production_recovery(args)\n        receipt[\'productionRecovery\'] = production\n        cycle = public_policy_cycle(args)')
s=s.replace("            YL_ABR_PROBE_RECOVERY_ACTION=recovery_action,", "            YL_ABR_PROBE_RECOVERY_ACTION=recovery_action,\n            YL_ABR_PROBE_PRODUCTION_RECOVERY='1' if production else '0',")
s=s.replace("        validate_candidate_preparation(rows, preparation_mode)", "        if production:\n            receipt['productionRecoveryObservation'] = summarize_production_recovery(rows, read_rows(out/'frame-samples.jsonl'))\n        elif any(r.get('productionRecovery') is True for r in rows):\n            raise ValueError('unexpected production recovery capture')\n        validate_candidate_preparation(rows, preparation_mode)")
s=s.replace("    p.add_argument('--public-policy-race'", "    p.add_argument('--production-recovery', action='store_true', help='observe automatic production public-host recovery; no diagnostic installation')\n    p.add_argument('--public-policy-race'")
p.write_text(s)
