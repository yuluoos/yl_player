from pathlib import Path
import sys
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text()
s=s.replace('allowed: () -> Bool, onReady: () -> Void = {},','allowed: () -> Bool, onReady: () async -> Void = {},',1)
s=s.replace('    onReady() // Explicit diagnostic injection after real readiness, before seek.','    await onReady() // Revalidate after an asynchronous public command, before seek.',1)
at='  func testFailedPreparationAndRevokedTicketNeverRefundSourceBudget() throws {\n'
t='''  @MainActor func testPrerollRevalidatesIntentAndDeadlineAfterAsyncReadyCommand() async throws {
    let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL)
    let app = try XCTUnwrap(Bundle(url: frameworks.appendingPathComponent("App.framework")))
    let media = try XCTUnwrap(app.resourceURL).appendingPathComponent(
      "flutter_assets/assets/test_media/format_matrix/mp4-avc-aac.mp4")
    for expire in [false, true] {
      var allowed = true, invoked = false, cleanups = 0
      let result = await AbrDiagnosticPreroll.prepare(AVURLAsset(url: media), position: .zero,
        deadlineUptime: ProcessInfo.processInfo.systemUptime + 2, allowed: { allowed },
        onReady: {
          invoked = true
          if expire { try? await Task.sleep(nanoseconds: 2_000_000_000) }
          else { await Task.yield(); allowed = false }
        }, cancelPending: { cleanups += 1 })
      XCTAssertTrue(invoked, "Must exercise the callback after actual readiness")
      XCTAssertEqual(result.outcome, expire ? "timedOut" : "cancelled")
      XCTAssertEqual(result.stage, "waitingReady")
      XCTAssertTrue(result.detached); XCTAssertNil(result.item); XCTAssertEqual(cleanups, 1)
    }
  }

'''
assert at in s;s=s.replace(at,t+at)
at='    // Preserve the historical managed probe\'s preparation-before-player order.\n'
t='''    let publicPolicyRace = env["YL_ABR_PROBE_PUBLIC_POLICY_RACE"] == "1"
    guard !publicPolicyRace || (!publicPolicyCycle && !direct && programmeSeconds == 120
      && recoveryAction == "auto-reload" && candidatePreparation == "asset-preroll" && startupDelayMs == 0
      && ["caps-during-preparation", "fixed-during-preparation"].contains(autoScenario)) else {
      XCTFail("Public policy race requires managed caps/fixed preroll diagnostic"); return
    }
'''
s=s.replace(at,t+at,1).replace('if direct || publicPolicyCycle {','if direct || publicPolicyCycle || publicPolicyRace {',1).replace('    if publicPolicyCycle {\n      let host','    if publicPolicyCycle || publicPolicyRace {\n      let host',1)
s=s.replace('        allowed: backend != nil && item?.status == .readyToPlay && player.rate > 0 &&','        allowed: (backend != nil || publicHost?.playbackIntent == true) && item?.status == .readyToPlay && player.rate > 0 &&',1)
s=s.replace('            fixedTrackId: backend?.videoSelection.fixedTrackId) && item?.isPlaybackLikelyToKeepUp == true,','            fixedTrackId: publicHost?.initialState.videoSelection?.fixedTrackId ?? backend?.videoSelection.fixedTrackId) && item?.isPlaybackLikelyToKeepUp == true,',1)
s=s.replace('"publicPolicyCycle": publicPolicyCycle, "policyPhase": policyPhase,','"publicPolicyCycle": publicPolicyCycle, "publicPolicyRace": publicPolicyRace, "policyPhase": policyPhase,',1)
s=s.replace('      if let host = publicHost, let sessionId = publicSessionId {','      if publicPolicyCycle, let host = publicHost, let sessionId = publicSessionId {',1)
# Backend scenarios still prepare their own policy asset. The public command owns its preparation.
s=s.replace('          if ["caps-during-preparation", "fixed-during-preparation"].contains(autoScenario), ticket.attempt == 1 {','          if !publicPolicyRace, ["caps-during-preparation", "fixed-during-preparation"].contains(autoScenario), ticket.attempt == 1 {',1)
at='''                if ["caps-during-preparation", "fixed-during-preparation"].contains(autoScenario), ticket.attempt == 1 {
                  automaticPolicy.invalidateIntent()
'''
t='''                if publicPolicyRace, ticket.attempt == 1 {
                  event["publicCommandReady"] = true
                  event["publicCommandManuallyInvalidated"] = false
                  event["publicCommandStartedElapsed"] = ProcessInfo.processInfo.systemUptime - started
                  event["publicCommandApplied"] = false
                  do {
                    let host = try XCTUnwrap(publicHost), sessionId = try XCTUnwrap(publicSessionId)
                    if autoScenario == "caps-during-preparation" {
                      try await host.setVideoConstraints(command: .init(sessionId: sessionId,
                        constraints: .init(maxWidth: 320)))
                    } else {
                      try await host.selectVideoTrack(command: .init(sessionId: sessionId,
                        trackId: "dash-video-w320-h180-b350000"))
                    }
                    event["publicCommandApplied"] = true
                    event["publicCommandSessionId"] = host.sessionId
                    event["publicCommandItemChanged"] = player.currentItem !== item
                  } catch { event["publicCommandApplied"] = false }
                  event["publicCommandCompletedElapsed"] = ProcessInfo.processInfo.systemUptime - started
                  // No invalidateIntent(): actual host policy/item identity must revoke eligibility.
                }
                if !publicPolicyRace, ["caps-during-preparation", "fixed-during-preparation"].contains(autoScenario), ticket.attempt == 1 {
                  automaticPolicy.invalidateIntent()
'''
assert s.count(at)==1;s=s.replace(at,t,1)
# Explicit fail closed if public path ever reaches an installable candidate; no new production recovery hook.
s=s.replace('''          } else if automaticPolicy.authorizes(ticket, automaticSample()) && player.currentItem === item {
            warmedItem = freshPreparedItem''','''          } else if publicPolicyRace {
            replacement.asset.cancelLoading(); replacement.discard()
            event["outcome"] = "cancelled"
            event["publicUnexpectedInstallEligibility"] = automaticPolicy.authorizes(ticket, automaticSample()) && player.currentItem === item
          } else if automaticPolicy.authorizes(ticket, automaticSample()) && player.currentItem === item {
            warmedItem = freshPreparedItem''',1)
p.write_text(s)
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path(f'packages/yl_player/example/{platform}/RunnerTests')/p.name).write_bytes(native_test_source(p))
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');s=p.read_text().replace("{'ios': 839, 'macos': 883}","{'ios': 840, 'macos': 884}");p.write_text(s)
