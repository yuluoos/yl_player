from pathlib import Path
base=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Session')
p=base/'YlAppleSessionCoordinator.swift';s=p.read_text().replace('  var onDashRecoveryDecision:', '  var onDashRecoveryEvent: (([String: Any]) -> Void)? {\n    get { dashRecovery.onEvent }\n    set { dashRecovery.onEvent = newValue }\n  }\n  var onDashRecoveryDecision:')
s=s.replace('  private let beforeDashCapsPreparation:', '  private let afterDashRecoveryPreparation: ((YlOpenCancellationToken) -> Void)?\n  private let beforeDashCapsPreparation:')
s=s.replace('       automaticDashRecoveryEnabled: Bool = true,','       automaticDashRecoveryEnabled: Bool = true,\n       afterDashRecoveryPreparation: ((YlOpenCancellationToken) -> Void)? = nil,')
s=s.replace('    self.beforeDashCapsPreparation = beforeDashCapsPreparation','    self.afterDashRecoveryPreparation = afterDashRecoveryPreparation\n    self.beforeDashCapsPreparation = beforeDashCapsPreparation')
s=s.replace('      return .headeredHls(source: source, prepared: try self.prepareHeaderedHls(source: source,\n        token: token, credentialContext: credentials, videoConstraints: .unconstrained, dashSnapshot: snapshot))','      let candidate = YlPreparedOpen.headeredHls(source: source, prepared: try self.prepareHeaderedHls(source: source,\n        token: token, credentialContext: credentials, videoConstraints: .unconstrained, dashSnapshot: snapshot))\n      self.afterDashRecoveryPreparation?(token)\n      return candidate')
p.write_text(s)
p=base/'YlApplePlayerHost.swift';s=p.read_text().replace('       automaticDashRecoveryEnabled: Bool = true,','       automaticDashRecoveryEnabled: Bool = true,\n       afterDashRecoveryPreparation: ((YlOpenCancellationToken) -> Void)? = nil,').replace('      automaticDashRecoveryEnabled: automaticDashRecoveryEnabled,','      automaticDashRecoveryEnabled: automaticDashRecoveryEnabled,\n      afterDashRecoveryPreparation: afterDashRecoveryPreparation,')
pos=s.index('  var onDashRecoveryDecision:');s=s[:pos]+'''  var onDashRecoveryEvent: (([String: Any]) -> Void)? {
    get { coordinator.onDashRecoveryEvent }
    set { coordinator.onDashRecoveryEvent = newValue }
  }
'''+s[pos:];p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text().replace('["none", "pause-resume"].contains(productionCommand)','["none", "pause-resume", "pause-prepared", "seek-prepared", "load-prepared"].contains(productionCommand)')
s=s.replace('    var productionCommandEvents: [String: Any] = [:]','''    var productionCommandEvents: [String: Any] = [:]
    var productionObservedEvents: [[String: Any]] = []
    let productionBarrier = DispatchSemaphore(value: 0)
    defer { productionBarrier.signal() }
    // The serial preparation queue invokes this only after a real candidate exists.
    // The main queue issues public commands; the production deadline remains 2s.
    var productionPreparedCallback: ((YlOpenCancellationToken) -> Void)?
    if productionCommand.hasSuffix("-prepared") {
      productionPreparedCallback = { token in
        DispatchQueue.main.async {
          productionCommandEvents["candidateCallback"] = true
        }
      }
    }''')
s=s.replace('    if publicPolicyCycle || publicPolicyRace || productionRecovery {\n      let host', '''    if productionCommand.hasSuffix("-prepared") {
      productionPreparedCallback = { token in
        let preparedAt = ProcessInfo.processInfo.systemUptime - productionEpoch
        DispatchQueue.main.async {
          guard productionCommandTask == nil else { productionBarrier.signal(); return }
          productionCommandTask = Task { @MainActor in
            defer { productionBarrier.signal() }
            do {
              let host = try XCTUnwrap(publicHost), session = try XCTUnwrap(publicSessionId)
              let item = player.currentItem, position = CMTimeGetSeconds(player.currentTime())
              let target = Int64(position * 1000) + 1000
              productionCommandEvents = ["sessionId": session, "scenario": productionCommand,
                "candidatePrepared": preparedAt, "commandStarted": ProcessInfo.processInfo.systemUptime - productionEpoch,
                "attemptsAtCommand": host.dashRecoveryAttempts, "positionBefore": position, "targetMs": target]
              if productionCommand == "pause-prepared" {
                try host.pause(command: .init(sessionId: session))
                productionCommandEvents["pausePosition"] = CMTimeGetSeconds(player.currentTime())
                productionCommandEvents["pauseAcknowledged"] = !host.playbackIntent && player.rate == 0
              } else if productionCommand == "seek-prepared" {
                try host.seekTo(command: .init(sessionId: session, positionMs: target))
              } else {
                let loaded = try await host.load(request: AppleHostFixture.request("public-policy-cycle",
                  url: url.absoluteString, format: .dash, autoplay: true, start: target))
                publicSessionId = loaded.sessionId
                productionCommandEvents["newSessionId"] = loaded.sessionId
                productionCommandEvents["newAttempts"] = host.dashRecoveryAttempts
              }
              productionCommandEvents["commandCompleted"] = ProcessInfo.processInfo.systemUptime - productionEpoch
              productionCommandEvents["tokenCancelled"] = token.isCancelled
              productionCommandEvents["itemUnchanged"] = player.currentItem === item
              productionCommandEvents["oldEvents"] = productionObservedEvents
              productionCommandEvents["released"] = ProcessInfo.processInfo.systemUptime - productionEpoch
              productionBarrier.signal()
              if productionCommand == "pause-prepared" {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                productionCommandEvents["beforeResumePosition"] = CMTimeGetSeconds(player.currentTime())
                productionCommandEvents["beforeResumeAttempts"] = host.dashRecoveryAttempts
                productionCommandEvents["itemUnchangedBeforeResume"] = player.currentItem === item
                try await host.play(command: .init(sessionId: session))
                productionCommandEvents["resumeCompleted"] = ProcessInfo.processInfo.systemUptime - productionEpoch
                productionCommandEvents["resumed"] = host.playbackIntent
              }
            } catch { productionCommandEvents["failed"] = true }
            do { try JSONSerialization.data(withJSONObject: productionCommandEvents, options: [.sortedKeys])
              .write(to: directory.appendingPathComponent("production-command-events.json"), options: .atomic) }
            catch { productionPolicyWriteFailed = true }
          }
        }
        _ = productionBarrier.wait(timeout: .now() + 3)
      }
    }
    if publicPolicyCycle || publicPolicyRace || productionRecovery {
      let host''')
s=s.replace('avPlayer: player, automaticDashRecoveryEnabled: productionRecovery,','avPlayer: player, automaticDashRecoveryEnabled: productionRecovery,\n        afterDashRecoveryPreparation: productionPreparedCallback,')
s=s.replace('      if productionRecovery {\n        host.onDashRecoveryDecision', '''      if productionRecovery {
        host.onDashRecoveryEvent = { event in productionObservedEvents.append(productionEvent(event)) }
        host.onDashRecoveryDecision''')
s=s.replace('          var row = decision\n', '          var row = decision\n          row["sessionId"] = publicSessionId ?? ""\n')
s=s.replace('    if productionCommand == "pause-resume" {\n      XCTAssertEqual', '''    if productionCommand.hasSuffix("-prepared") {
      XCTAssertEqual(productionCommandEvents["tokenCancelled"] as? Bool, true)
      XCTAssertNil(productionCommandEvents["failed"])
      XCTAssertEqual((productionCommandEvents["oldEvents"] as? [[String: Any]])?.first?["outcome"] as? String, "cancelled")
    }
    if productionCommand == "pause-resume" {
      XCTAssertEqual''')
# Drop redundant placeholder callback assignment.
s=s.replace('''    if productionCommand.hasSuffix("-prepared") {
      productionPreparedCallback = { token in
        DispatchQueue.main.async {
          productionCommandEvents["candidateCallback"] = true
        }
      }
    }
''','')
p.write_text(s)
import sys
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:Path(f'packages/yl_player/example/{platform}/RunnerTests/YlDashResourceLoaderTests.swift').write_bytes(native_test_source(p))
