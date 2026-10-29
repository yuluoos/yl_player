from pathlib import Path
import shutil,json
out=Path('/private/tmp/yl-public-policy')
shutil.copytree(out/'capture-source',out/'before-pause-source')
shutil.copy2(out/'source-identity.json',out/'before-pause-source-identity.json')
for suffix in ['log','command.json','result.json']:shutil.copy2(out/('build-'+suffix if suffix!='log' else 'build.log'),out/('before-pause-build-'+suffix if suffix!='log' else 'before-pause-build.log'))
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift')
s=p.read_text();marker='final class YlDashResourceLoaderTests: XCTestCase {\n'
test='''  @MainActor func testDelayedItemReadinessPreservesAcknowledgedPause() async throws {
    let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL)
    let app = try XCTUnwrap(Bundle(url: frameworks.appendingPathComponent("App.framework")))
    let media = try XCTUnwrap(app.resourceURL).appendingPathComponent(
      "flutter_assets/assets/test_media/format_matrix/mp4-avc-aac.mp4")
    let player = AVPlayer(), output = AppleTestTexture()
    var tick: (() -> Void)?, states = [YlNativeState]()
    let backend = YlAvPlayerBackend(playerId: 995,
      services: .init(platform: .current, textureOutput: output,
        makeDisplayDriver: { tick = $0; return AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), player: player,
      emit: { if case .state(let state) = $0.event { states.append(state) } })
    defer { backend.dispose() }
    try backend.open(.init(uri: media.absoluteString, kind: .file, formatHint: .mp4))
    try await AppleHostCharacterizations.waitFor { states.last?.status == "ready" }
    XCTAssertFalse(backend.playbackIntent, "Initial readiness does not request playback")
    try backend.play()
    try await AppleHostCharacterizations.waitFor({ tick?(); return !output.frames.isEmpty }, timeout: 5)
    try backend.pause()
    try await AppleHostCharacterizations.waitFor { states.last?.status == "paused" }
    let item = try XCTUnwrap(player.currentItem)
    XCTAssertEqual(item.status, .readyToPlay)
    let paused = CMTimeGetSeconds(player.currentTime())
    // Deliver an unchanged ready status after the pause, as a queued KVO callback can.
    item.willChangeValue(forKey: "status")
    item.didChangeValue(forKey: "status")
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    XCTAssertEqual(states.last?.status, "paused")
    XCTAssertFalse(backend.playbackIntent)
    XCTAssertEqual(player.rate, 0)
    XCTAssertEqual(CMTimeGetSeconds(player.currentTime()), paused, accuracy: 0.05)
    try backend.play()
    try await AppleHostCharacterizations.waitFor({ tick?(); return CMTimeGetSeconds(player.currentTime()) > paused + 0.1 }, timeout: 5)
    XCTAssertTrue(backend.playbackIntent)
  }

'''
assert marker in s;s=s.replace(marker,marker+test,1);p.write_text(s)
for platform in ['ios','macos']:
 q=Path(f'packages/yl_player/example/{platform}/RunnerTests')/p.name
 q.write_text(s.replace('@testable import yl_player_apple','@testable import yl_player_apple\n@testable import yl_player_media_core',1))
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');s=p.read_text().replace("{'ios': 838, 'macos': 882}","{'ios': 839, 'macos': 883}");p.write_text(s)
cmd=json.loads((out/'ats-review-green-command.json').read_text());cmd=[x for x in cmd if not x.startswith('-only-testing:')];cmd[cmd.index('-resultBundlePath')+1]=str(out/'pause-red.xcresult');cmd+=['-only-testing:RunnerTests/YlDashResourceLoaderTests/testDelayedItemReadinessPreservesAcknowledgedPause']
(out/'pause-red-command.json').write_text(json.dumps(cmd,indent=2)+'\n')
import subprocess
with (out/'pause-red.log').open('w') as f:p=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(out/'pause-red-result.json').write_text(json.dumps({'exitCode':p.returncode})+'\n');print(p.returncode)
