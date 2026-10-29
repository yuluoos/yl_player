from pathlib import Path
import sys
root=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple')
p=root/'Engines/AvPlayer/YlDashAutoRecoveryController.swift';s=p.read_text().replace('  var onDecision:', '  var onEvent: (([String: Any]) -> Void)?\n  var onDecision:').replace('      self.events.append(event)', '      self.events.append(event)\n      self.onEvent?(event)');p.write_text(s)
for name,expr in [('YlAppleSessionCoordinator','avBackend'),('YlApplePlayerHost','coordinator')]:
 p=root/f'Shared/Session/{name}.swift';s=p.read_text();i=s.index('  var onDashRecoveryDecision:');s=s[:i]+f'  var diagnosticProxySnapshot: [String: Double] {{ {expr}.diagnosticProxySnapshot }}\n  var diagnosticResumeSeekPending: Bool {{ {expr}.diagnosticResumeSeekPending }}\n'+s[i:];p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text()
s=s.replace('      let started = expectation(description: "held preparation " + action)', '      let finalized = expectation(description: "candidate finalized " + action)\n      controller.onEvent = { _ in finalized.fulfill() }\n      let started = expectation(description: "held preparation " + action)')
a=s.index('      // Drain both the preparation queue');b=s.index('      XCTAssertEqual(installs',a);s=s[:a]+'      await fulfillment(of: [finalized], timeout: 2)\n      XCTAssertEqual(controller.events.count, 1)\n'+s[b:]
s=s.replace('    let productionEpoch =', '''    let productionCommand = env["YL_ABR_PROBE_PRODUCTION_COMMAND"] ?? "none"
    guard ["none", "pause-resume"].contains(productionCommand), productionCommand == "none" || productionRecovery else {
      XCTFail("Invalid production command scenario"); return
    }
    var productionCommandEvents: [String: Any] = [:]
    var productionCommandTask: Task<Void, Never>?
    defer { productionCommandTask?.cancel() }
    let productionEpoch =''')
s=s.replace('        host.onDashRecoveryDecision = { decision in', '        host.onDashRecoveryDecision = { [weak host] decision in')
s=s.replace('          catch { productionPolicyWriteFailed = true }\n        }', '''          catch { productionPolicyWriteFailed = true }
          if productionCommand == "pause-resume", productionCommandTask == nil,
            decision["reason"] as? String == "reserved", decision["attempts"] as? Int == 1 {
            productionCommandTask = Task { @MainActor [weak host] in
              do {
                let host = try XCTUnwrap(host), sessionId = try XCTUnwrap(publicSessionId)
                let item = player.currentItem
                productionCommandEvents = ["sessionId": sessionId, "reservationAttempts": host.dashRecoveryAttempts,
                  "pauseStarted": ProcessInfo.processInfo.systemUptime - productionEpoch]
                try host.pause(command: .init(sessionId: sessionId))
                productionCommandEvents["pauseAcknowledged"] = !host.playbackIntent && player.rate == 0
                productionCommandEvents["pausePosition"] = CMTimeGetSeconds(player.currentTime())
                try await Task.sleep(nanoseconds: 2_000_000_000)
                productionCommandEvents["beforeResumePosition"] = CMTimeGetSeconds(player.currentTime())
                productionCommandEvents["beforeResumeAttempts"] = host.dashRecoveryAttempts
                productionCommandEvents["itemUnchangedBeforeResume"] = player.currentItem === item
                productionCommandEvents["installedBeforeResume"] = host.dashRecoveryEvents.contains { $0["outcome"] as? String == "installed" }
                try await host.play(command: .init(sessionId: sessionId))
                productionCommandEvents["resumed"] = host.playbackIntent
                productionCommandEvents["resumeCompleted"] = ProcessInfo.processInfo.systemUptime - productionEpoch
              } catch { productionCommandEvents["failed"] = true }
              do {
                try JSONSerialization.data(withJSONObject: productionCommandEvents, options: [.sortedKeys])
                  .write(to: directory.appendingPathComponent("production-command-events.json"), options: .atomic)
              } catch { productionPolicyWriteFailed = true }
            }
          }
        }''')
s=s.replace('"resumeSeekPending": backend?.diagnosticResumeSeekPending ?? false', '"resumeSeekPending": backend?.diagnosticResumeSeekPending ?? publicHost?.diagnosticResumeSeekPending ?? false')
s=s.replace('"productionRecovery": productionRecovery,', '"productionRecovery": productionRecovery, "productionCommand": productionCommand,\n        "productionCommandEvents": productionCommandEvents,')
s=s.replace('"proxy": backend?.diagnosticProxySnapshot ?? [:]', '"proxy": backend?.diagnosticProxySnapshot ?? publicHost?.diagnosticProxySnapshot ?? [:]')
s=s.replace('    XCTAssertFalse(productionPolicyWriteFailed)', '''    XCTAssertFalse(productionPolicyWriteFailed)
    if productionCommand == "pause-resume" {
      XCTAssertEqual(productionCommandEvents["pauseAcknowledged"] as? Bool, true)
      XCTAssertEqual(productionCommandEvents["resumed"] as? Bool, true)
      XCTAssertEqual(publicHost?.dashRecoveryAttempts, 2)
    }''')
p.write_text(s);sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path('packages/yl_player/example')/platform/'RunnerTests'/p.name).write_bytes(native_test_source(p))
p=Path('tool/playback_network/abr_device.py');s=p.read_text().replace("'public-policy-failure.json', 'signals.jsonl'", "'public-policy-failure.json', 'production-command-events.json', 'signals.jsonl'");p.write_text(s)
p=Path('tool/playback_network/abr_accesslog.py');s=p.read_text();s=s.replace("    if not enabled: return False", "    command = getattr(args, 'production_command', 'none')\n    if command not in ('none', 'pause-resume') or (not enabled and command != 'none'):\n        raise ValueError('invalid production command scenario')\n    if not enabled: return False",1)
s=s.replace("    lows = [r['elapsed'] for r in rows if r.get('width') == 320]\n    require(bool(lows) and any(f.get('frames', 0) > 0 and f.get('width') == 640 and f['elapsed'] > min(lows) for f in frames))", "    high_seen = False; down = None\n    for r in rows:\n        if r.get('width') == 640: high_seen = True\n        elif r.get('width') == 320 and high_seen and down is None: down = r['elapsed']\n    require(down is not None and rows[-1].get('width') == 640)\n    require(any(f.get('frames', 0) > 0 and f.get('width') == 640 and f['elapsed'] > down for f in frames))")
s=s.replace("YL_ABR_PROBE_PRODUCTION_RECOVERY='1' if production else '0',", "YL_ABR_PROBE_PRODUCTION_RECOVERY='1' if production else '0',\n            YL_ABR_PROBE_PRODUCTION_COMMAND=getattr(args, 'production_command', 'none'),")
s=s.replace("    p.add_argument('--production-recovery'", "    p.add_argument('--production-command', choices=('none', 'pause-resume'), default='none')\n    p.add_argument('--production-recovery'")
p.write_text(s)
