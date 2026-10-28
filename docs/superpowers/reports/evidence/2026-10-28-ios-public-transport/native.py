from pathlib import Path
import sys
base=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Session')
p=base/'YlAppleSessionCoordinator.swift';s=p.read_text().replace('  private var restorationIntentRevision: UInt64 = 0','  private var restorationIntentRevision: UInt64 = 0\n  /// Monotonic authority for acknowledged transport/track intents within this owner.\n  var acknowledgedTransportRevision: UInt64 { restorationIntentRevision }',1);p.write_text(s)
p=base/'YlApplePlayerHost.swift';s=p.read_text().replace('  var playbackIntent: Bool { coordinator.currentPlaybackIntent }','  var playbackIntent: Bool { coordinator.currentPlaybackIntent }\n  var acknowledgedTransportRevision: UInt64 { coordinator.acknowledgedTransportRevision }',1);p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text()
s=s.replace('struct Ticket { let id: UUID, generation: Int, attempt: Int, due: Double }','struct Ticket { let id: UUID, generation: Int, attempt: Int, due: Double; let intentRevision: UInt64 }',1)
s=s.replace('  private var generation: Int?\n','  private var generation: Int?\n  private var intentRevision: UInt64?\n',1)
s=s.replace('"elapsed": finite(s.time), "generation": s.generation, "allowed": s.allowed,','"elapsed": finite(s.time), "generation": s.generation, "intentRevision": s.intentRevision, "allowed": s.allowed,',1)
s=s.replace('    guard eligible(s), last.map','    if intentRevision != s.intentRevision { intentRevision = s.intentRevision; invalidateIntent() }\n    guard eligible(s), last.map',1)
s=s.replace('due: s.time + (attempts == 1 ? 0.5 : 1.0))','due: s.time + (attempts == 1 ? 0.5 : 1.0), intentRevision: s.intentRevision)',1)
s=s.replace('eligible(s) && s.width == 320 && s.generation == ticket.generation &&','eligible(s) && s.width == 320 && s.generation == ticket.generation && s.intentRevision == ticket.intentRevision &&',1)
at='  func testRecoveryTicketRejectsAcknowledgedIntentRevisionWithoutItemChange() throws {\n'
t='''  @MainActor func testPublicTransportRevisionOnlyAdvancesForAcknowledgedCommands() async throws {
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    let loaded = try await fixture.host.load(request: AppleHostFixture.request("intent-revision"))
    let initial = fixture.host.acknowledgedTransportRevision
    XCTAssertThrowsError(try fixture.host.seekTo(command: .init(sessionId: loaded.sessionId, positionMs: -1)))
    XCTAssertThrowsError(try fixture.host.pause(command: .init(sessionId: "retired")))
    XCTAssertEqual(fixture.host.acknowledgedTransportRevision, initial)
    try fixture.host.seekTo(command: .init(sessionId: loaded.sessionId, positionMs: 1000))
    XCTAssertEqual(fixture.host.acknowledgedTransportRevision, initial + 1)
    try fixture.host.pause(command: .init(sessionId: loaded.sessionId))
    XCTAssertEqual(fixture.host.acknowledgedTransportRevision, initial + 2)
    try fixture.host.setVolume(volume: 0.5)
    XCTAssertEqual(fixture.host.acknowledgedTransportRevision, initial + 2)
    try fixture.host.seekTo(command: .init(sessionId: loaded.sessionId, positionMs: 0))
    XCTAssertEqual(fixture.host.acknowledgedTransportRevision, initial + 3, "Returning to the old position cannot revive old authority")
  }

'''
s=s.replace(at,t+at,1)
s=s.replace('&& ["caps-during-preparation", "fixed-during-preparation"].contains(autoScenario))','&& ["caps-during-preparation", "fixed-during-preparation", "pause-during-preparation", "seek-during-preparation"].contains(autoScenario))',1)
s=s.replace('    var resumeTask: Task<Void, Never>?\n','    var resumeTask: Task<Void, Never>?\n    var publicResume: [String: Any]?\n',1)
s=s.replace('overdue: logs.reduce(0) { $0 + $1.downloadOverdue })','overdue: logs.reduce(0) { $0 + $1.downloadOverdue },\n        intentRevision: publicHost?.acknowledgedTransportRevision ?? 0)',1)
s=s.replace('"publicPolicyCycle": publicPolicyCycle, "publicPolicyRace": publicPolicyRace, "policyPhase": policyPhase,','"publicPolicyCycle": publicPolicyCycle, "publicPolicyRace": publicPolicyRace, "policyPhase": policyPhase,\n        "publicIntentRevision": publicHost?.acknowledgedTransportRevision as Any? ?? NSNull(),\n        "publicPlaybackIntent": publicHost?.playbackIntent as Any? ?? NSNull(),\n        "publicResume": publicResume as Any? ?? NSNull(),',1)
s=s.replace('''                    if autoScenario == "caps-during-preparation" {''','''                    event["publicCommandIntentBefore"] = host.acknowledgedTransportRevision
                    event["publicCommandPositionBefore"] = finite(CMTimeGetSeconds(player.currentTime()))
                    if autoScenario == "pause-during-preparation" {
                      try host.pause(command: .init(sessionId: sessionId))
                      event["publicPausePosition"] = finite(CMTimeGetSeconds(player.currentTime()))
                      let pausedElapsed = ProcessInfo.processInfo.systemUptime - started
                      resumeTask = Task { @MainActor in
                        do {
                          try await Task.sleep(nanoseconds: 2_000_000_000)
                          let begin = ProcessInfo.processInfo.systemUptime - started
                          try await host.play(command: .init(sessionId: sessionId))
                          publicResume = ["applied": true, "startedElapsed": begin,
                            "completedElapsed": ProcessInfo.processInfo.systemUptime - started,
                            "pausedElapsed": pausedElapsed, "sessionId": host.sessionId as Any? ?? NSNull(),
                            "itemUnchanged": player.currentItem === item,
                            "oldTicketAuthorized": automaticPolicy.authorizes(ticket, automaticSample())]
                        } catch { publicResume = ["applied": false] }
                      }
                    } else if autoScenario == "seek-during-preparation" {
                      let target = Int64(CMTimeGetSeconds(player.currentTime()) * 1000) + 1000
                      event["publicSeekTargetMs"] = target
                      try host.seekTo(command: .init(sessionId: sessionId, positionMs: target))
                    } else if autoScenario == "caps-during-preparation" {''',1)
s=s.replace('''                    event["publicCommandApplied"] = true
                    event["publicCommandSessionId"]''','''                    event["publicCommandIntentAfter"] = host.acknowledgedTransportRevision
                    event["publicCommandApplied"] = true
                    event["publicCommandSessionId"]''',1)
# Avoid the legacy backend injection in the new public transport path.
s=s.replace('if autoScenario == "seek-during-preparation", ticket.attempt == 1 {','if !publicPolicyRace, autoScenario == "seek-during-preparation", ticket.attempt == 1 {',1).replace('if autoScenario == "pause-during-preparation", ticket.attempt == 1 {','if !publicPolicyRace, autoScenario == "pause-during-preparation", ticket.attempt == 1 {',1)
p.write_text(s)
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path(f'packages/yl_player/example/{platform}/RunnerTests')/p.name).write_bytes(native_test_source(p))
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');s=p.read_text().replace("{'ios': 840, 'macos': 884}","{'ios': 842, 'macos': 886}");p.write_text(s)
raw=Path('/private/tmp/yl-public-transport');s=Path('/private/tmp/yl-public-race/run-contracts.py').read_text().replace("out=Path('/private/tmp/yl-public-race')","out=Path('/private/tmp/yl-public-transport')");(raw/'run-contracts.py').write_text(s)
s=Path('/private/tmp/yl-public-race/build.py').read_text().replace("out=Path('/private/tmp/yl-public-race')","out=Path('/private/tmp/yl-public-transport')");(raw/'build.py').write_text(s)
