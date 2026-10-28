from pathlib import Path
import sys
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text()
s=s.replace('allowed: () -> Bool, onReady: () async -> Void = {},','allowed: () -> Bool, onReady: @escaping @MainActor () async -> Void = {},',1)
s=s.replace('(outcome: String, item: AVPlayerItem?, detached: Bool, stage: String, reusesPrerolledItem: Bool)', '(outcome: String, item: AVPlayerItem?, detached: Bool, stage: String, reusesPrerolledItem: Bool, readyCommand: Task<Void, Never>?)',2)
s=s.replace('''    var candidate: AVPlayer?
    var stage = "beforeLoading"''','''    var candidate: AVPlayer?
    var readyCommand: Task<Void, Never>?
    var stage = "beforeLoading"''',1)
s=s.replace('return (outcome, item, candidate?.currentItem == nil, stage, reusesPrerolledItem)','return (outcome, item, candidate?.currentItem == nil, stage, reusesPrerolledItem, readyCommand)',1)
s=s.replace('''    await onReady() // Revalidate after an asynchronous public command, before seek.
    if let reason = rejection() { return finish(reason) }''','''    let commandCompletion = AbrPrerollCompletion()
    // Public commands have independent ownership. Keep enforcing the candidate's
    // deadline while they wait; the caller joins this task after recording cleanup.
    readyCommand = Task { @MainActor in
      await onReady()
      commandCompletion.finish(true)
    }
    while commandCompletion.result == nil {
      if let reason = rejection() { return finish(reason) }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    if let reason = rejection() { return finish(reason) }''',1)
s=s.replace('''      await release.value
      if expire''','''      await release.value
      await result.readyCommand?.value
      if expire''',1)
at='''            let prepared = await AbrDiagnosticPreroll.prepare(replacement.asset, position: player.currentTime(),
              deadlineUptime: min(warmupStarted + 2, started + ticket.due + 5),'''
new='''            let warmupDeadline = min(warmupStarted + 2, started + ticket.due + 5)
            event["warmupDeadlineElapsed"] = warmupDeadline - started
            let prepared = await AbrDiagnosticPreroll.prepare(replacement.asset, position: player.currentTime(),
              deadlineUptime: warmupDeadline,'''
assert s.count(at)==1;s=s.replace(at,new)
at='''            event["warmupOldItemRetained"] = player.currentItem === item
            preparationSucceeded = prepared.outcome == "ready"'''
new='''            event["warmupOldItemRetained"] = player.currentItem === item
            // Candidate cleanup is already recorded, even if a public command
            // is still finishing. Its late completion cannot change the outcome.
            await prepared.readyCommand?.value
            preparationSucceeded = prepared.outcome == "ready"'''
assert s.count(at)==1;s=s.replace(at,new)
p.write_text(s)
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path(f'packages/yl_player/example/{platform}/RunnerTests')/p.name).write_bytes(native_test_source(p))
# New output names preserve all pre-review contracts.
raw=Path('/private/tmp/yl-public-race');s=(raw/'run-contracts.py').read_text().replace('final-','deadline-fixed-');(raw/'run-deadline-contracts.py').write_text(s)
