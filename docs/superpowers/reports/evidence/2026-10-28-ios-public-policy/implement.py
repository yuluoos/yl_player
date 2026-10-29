from pathlib import Path
p=Path('tool/playback_network/abr_accesslog.py');s=p.read_text();start=s.index('def summarize_public_policy');end=s.index('\ndef summarize_frames',start)
s=s[:start]+'''def summarize_public_policy(rows, frames, events):
    """Require real typed-host policy commits and frame evidence for every phase."""
    phases = ['initial-auto', 'caps', 'clear-caps', 'fixed', 'restore-auto']
    def require(value):
        if not value: raise ValueError('incomplete public host policy evidence')
    def finite(value):
        return type(value) in (int, float) and math.isfinite(value) and value >= 0
    require(isinstance(rows, list) and bool(rows) and isinstance(frames, list))
    require(isinstance(events, list) and len(events) == 4)
    session = rows[0].get('sessionId')
    require(isinstance(session, str) and bool(session))
    previous = -1
    for phase, event in zip(phases[1:], events):
        require(isinstance(event, dict) and event.get('phase') == phase and
                event.get('applied') is True and event.get('itemChanged') is True and
                event.get('sessionId') == session and finite(event.get('elapsed')) and
                finite(event.get('elapsedAfter')) and previous < event['elapsed'] <= event['elapsedAfter'])
        previous = event['elapsedAfter']
    require(all(isinstance(row, dict) and row.get('publicPolicyCycle') is True and
                row.get('sessionId') == session and row.get('hostFailureCount') == 0 and
                row.get('hostStatus') not in (None, 'error') and finite(row.get('elapsed'))
                for row in rows))
    require(all(a['elapsed'] < b['elapsed'] for a, b in zip(rows, rows[1:])))
    require(all(isinstance(frame, dict) and finite(frame.get('elapsed')) and
                type(frame.get('frames')) is int and frame['frames'] >= 0 and
                type(frame.get('width')) is int and 0 <= frame['width'] <= 16384 for frame in frames))
    require(all(a['elapsed'] < b['elapsed'] for a, b in zip(frames, frames[1:])))
    observed = []
    for row in rows:
        phase = row.get('policyPhase')
        require(phase in phases)
        if not observed or observed[-1] != phase: observed.append(phase)
    require(observed == phases)
    summaries = []
    for i, phase in enumerate(phases):
        start = events[i-1]['elapsedAfter'] if i else rows[0]['elapsed']
        end = events[i]['elapsed'] if i < 4 else rows[-1]['elapsed'] + 1
        selected = [row for row in rows if row['policyPhase'] == phase]
        require(len(selected) >= 3 and all(start <= row['elapsed'] <= end for row in selected))
        expected_id = 'dash-video-w320-h180-b350000' if phase == 'fixed' else None
        require(all(row.get('fixedTrackId') == expected_id and
                    'fixedTrackId' in row and 'acceptedMaximumWidth' in row and
                    row.get('acceptedMaximumWidth') == (320 if phase == 'caps' else None) and
                    'acceptedMaximumHeight' in row and row['acceptedMaximumHeight'] is None and
                    'acceptedMaximumBitrate' in row and row['acceptedMaximumBitrate'] is None and
                    row.get('peak') == 0 and row.get('maximumWidth') == (320 if phase == 'caps' else 0) and
                    row.get('maximumHeight') == (100000 if phase == 'caps' else 0)
                    for row in selected))
        published = [frame for frame in frames if start <= frame['elapsed'] < end and frame['frames'] > 0]
        require(len(published) >= 3)
        widths = sorted(set(frame['width'] for frame in published))
        if phase in ('caps', 'fixed'): require(widths == [320])
        else: require(640 in widths)
        summaries.append(dict(phase=phase, rows=len(selected), publishedFrames=sum(f['frames'] for f in published), widths=widths))
    return dict(phasesVerified=phases, phases=summaries, sameSession=True,
                capabilityAccepted=False, physicalOutputVerified=False, continuityAccepted=False)


def public_policy_cycle(args):
    enabled = getattr(args, 'public_policy_cycle', False)
    if type(enabled) is not bool or (enabled and (
            getattr(args, 'duration_seconds', 40) != 120 or
            getattr(args, 'direct_hls_control', False) or
            getattr(args, 'recovery_action', 'none') != 'none' or
            getattr(args, 'auto_scenario', 'normal') != 'normal' or
            getattr(args, 'candidate_preparation', 'manifest-only') != 'manifest-only' or
            getattr(args, 'startup_delay_ms', 0) != 0)):
        raise ValueError('public policy cycle requires managed 120s with no recovery intervention')
    return enabled

''' + s[end:]
s=s.replace("        host = getattr(args, 'owned_host', None)","        cycle = public_policy_cycle(args)\n        receipt['publicPolicyCycle'] = cycle\n        host = getattr(args, 'owned_host', None)")
s=s.replace('YL_ABR_PROBE_RECOVERY_ACTION=recovery_action,','YL_ABR_PROBE_RECOVERY_ACTION=recovery_action,\n            YL_ABR_PROBE_PUBLIC_POLICY_CYCLE=\'1\' if cycle else \'0\',')
s=s.replace("        validate_candidate_preparation(rows, preparation_mode)","        if cycle:\n            receipt['publicPolicyObservation'] = summarize_public_policy(rows,\n                read_rows(out/'frame-samples.jsonl'), json.loads((out/'public-policy-events.json').read_text()))\n        elif any(row.get('publicPolicyCycle') is True for row in rows):\n            raise ValueError('unexpected public host policy capture')\n        validate_candidate_preparation(rows, preparation_mode)")
s=s.replace("    p.add_argument('--direct-hls-control'", "    p.add_argument('--public-policy-cycle', action='store_true',\n                   help='typed public host auto/caps/clear/fixed/auto media matrix; no recovery intervention')\n    p.add_argument('--direct-hls-control'")
p.write_text(s)
p=Path('tool/playback_network/abr_device.py');s=p.read_text().replace("'automatic-events.json', 'recovery-attempt.json', 'policy-decisions.jsonl')","'automatic-events.json', 'recovery-attempt.json', 'policy-decisions.jsonl', 'public-policy-events.json')");p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text()
s=s.replace('    // Preserve the historical managed probe', '''    let publicPolicyCycle = env["YL_ABR_PROBE_PUBLIC_POLICY_CYCLE"] == "1"
    guard !publicPolicyCycle || (!direct && programmeSeconds == 120 && recoveryAction == "none"
      && autoScenario == "normal" && candidatePreparation == "manifest-only" && startupDelayMs == 0) else {
      XCTFail("Public policy cycle requires managed 120s without diagnostic recovery"); return
    }
    // Preserve the historical managed probe''')
s=s.replace('    if direct {\n      prepared = nil','    if direct || publicPolicyCycle {\n      prepared = nil',1)
s=s.replace('    var backend: YlAvPlayerBackend?','''    var backend: YlAvPlayerBackend?
    var publicHost: YlApplePlayerHost?
    let publicCallbacks = AppleRecordingCallbacks()
    var publicSessionId: String?
    var policyPhase = "initial-auto"
    var publicPolicyEvents: [[String: Any]] = []''',1)
s=s.replace('    if direct {\n      // System-only control:', '''    if publicPolicyCycle {
      let host = YlApplePlayerHost(playerId: 991, suffix: "abr-public-policy",
        options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 100),
        services: .init(platform: .current, textureOutput: output,
          makeDisplayDriver: { tick = $0; return AppleTestDisplay() }), callbacks: publicCallbacks, avPlayer: player)
      publicHost = host
      try host.attach()
      let loaded = try await host.load(request: AppleHostFixture.request("public-policy-cycle",
        url: url.absoluteString, format: .dash, autoplay: true))
      publicSessionId = loaded.sessionId
    } else if direct {
      // System-only control:''',1)
s=s.replace('    defer { endTask?.cancel(); backend?.dispose();','    defer { endTask?.cancel(); publicHost?.close(); backend?.dispose();',1)
s=s.replace('      let row: [String: Any] = ["elapsed":', '''      let publicState = publicHost?.initialState
      let fixedTrackId = publicState?.videoSelection.fixedTrackId ?? backend?.videoSelection.fixedTrackId
      let reachedEnd = publicState.map { $0.status == .completed } ?? (direct ? directCompleted : states.last?.status == "completed")
      let row: [String: Any] = ["elapsed":''',1)
s=s.replace('"fixedTrackId": backend?.videoSelection.fixedTrackId as Any? ?? NSNull(),','"fixedTrackId": fixedTrackId as Any? ?? NSNull(),',1)
s=s.replace('fixedTrackId: backend?.videoSelection.fixedTrackId),','fixedTrackId: fixedTrackId),',1)
s=s.replace('        "candidatePreparation": candidatePreparation,','''        "publicPolicyCycle": publicPolicyCycle, "policyPhase": policyPhase,
        "sessionId": publicHost?.sessionId as Any? ?? NSNull(),
        "acceptedMaximumWidth": publicHost?.acceptedVideoConstraints.maxWidth as Any? ?? NSNull(),
        "acceptedMaximumHeight": publicHost?.acceptedVideoConstraints.maxHeight as Any? ?? NSNull(),
        "acceptedMaximumBitrate": publicHost?.acceptedVideoConstraints.maxBitrate as Any? ?? NSNull(),
        "hostStatus": publicState.map { String(describing: $0.status) } as Any? ?? NSNull(),
        "hostFailureCount": publicCallbacks.failures.count,
        "candidatePreparation": candidatePreparation,''',1)
s=s.replace('"completed": direct ? directCompleted : states.last?.status == "completed",','"completed": reachedEnd,',1)
s=s.replace('      if direct ? directCompleted : states.last?.status == "completed" { completed = true; break }','''      if reachedEnd { completed = true; break }
      if let host = publicHost, let sessionId = publicSessionId {
        let schedule: [(String, Double)] = [("caps", 8), ("clear-caps", 24), ("fixed", 50), ("restore-auto", 70)]
        let index = publicPolicyEvents.count
        if index < schedule.count, ProcessInfo.processInfo.systemUptime - started >= schedule[index].1 {
          let phase = schedule[index].0
          var event: [String: Any] = ["phase": phase, "elapsed": ProcessInfo.processInfo.systemUptime - started,
            "applied": false, "sessionId": sessionId]
          let beforeItem = player.currentItem
          publicPolicyEvents.append(event)
          let eventsURL = directory.appendingPathComponent("public-policy-events.json")
          func writeEvents() throws {
            try JSONSerialization.data(withJSONObject: publicPolicyEvents, options: [.sortedKeys]).write(to: eventsURL, options: .atomic)
          }
          try writeEvents()
          do {
            if phase == "caps" || phase == "clear-caps" {
              try await host.setVideoConstraints(command: .init(sessionId: sessionId,
                constraints: .init(maxWidth: phase == "caps" ? 320 : nil)))
            } else {
              let id = phase == "fixed" ? "dash-video-w320-h180-b350000" : nil
              try await host.selectVideoTrack(command: .init(sessionId: sessionId, trackId: id))
            }
            event["applied"] = true
            event["itemChanged"] = player.currentItem !== beforeItem
            event["sessionId"] = host.sessionId
            event["elapsedAfter"] = ProcessInfo.processInfo.systemUptime - started
            policyPhase = phase
          } catch {
            event["elapsedAfter"] = ProcessInfo.processInfo.systemUptime - started
            publicPolicyEvents[index] = event; try writeEvents(); throw error
          }
          publicPolicyEvents[index] = event; try writeEvents()
        }
      }''',1)
s=s.replace('    backend?.dispose(); player.pause(); player.replaceCurrentItem(with: nil)','    publicHost?.close(); backend?.dispose(); player.pause(); player.replaceCurrentItem(with: nil)',1)
p.write_text(s)
import sys
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter')
from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:
 Path(f'packages/yl_player/example/{platform}/RunnerTests/{p.name}').write_bytes(native_test_source(p))
