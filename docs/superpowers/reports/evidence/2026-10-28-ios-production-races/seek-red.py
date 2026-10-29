from pathlib import Path
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();at=s.index('  @MainActor\n  func testSameSessionAutomaticReplacementRetainsFrameOnlyWithoutChangedIntent')
s=s[:at]+'''  @MainActor func testAutomaticUserSeekBlocksOldFramesUntilLatestLanding() async throws {
    let player = DashCatalogClockPlayer(), output = AppleTestTexture(), pixels = DashPixelOutput(width: 320, height: 180)
    var tick: (() -> Void)?
    let backend = YlAvPlayerBackend(playerId: 99,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { tick = $0; return AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), player: player, makeVideoOutput: { _ in pixels }, emit: { _ in })
    defer { backend.dispose() }
    let data = mpd
    try backend.stagePreparedHls(source: .init(uri: origin.absoluteString, kind: .network, formatHint: .dash),
      prepared: prepare(DashLoaderProtocol.configuration { $0.respond(data) }), resume: false)
    try backend.activate(); try backend.play(); tick?()
    let count = output.frames.count
    XCTAssertGreaterThan(count, 0)
    try backend.seek(toMs: 1000)
    let first = try XCTUnwrap(player.seekCompletion)
    tick?(); XCTAssertEqual(output.frames.count, count, "Automatic selection cannot publish the old timeline while seek is pending")
    XCTAssertNil(backend.copyPixelBuffer()?.takeRetainedValue())
    try backend.seek(toMs: 2000)
    let latest = try XCTUnwrap(player.seekCompletion)
    first(true)
    let staleDrained = expectation(description: "stale callback drained")
    DispatchQueue.main.async { staleDrained.fulfill() }; await fulfillment(of: [staleDrained], timeout: 1)
    XCTAssertNil(backend.copyPixelBuffer()?.takeRetainedValue(), "An older seek callback cannot reopen publication")
    player.measuredTime = CMTime(seconds: 2, preferredTimescale: 1000); pixels.measuredItemTime = player.measuredTime
    latest(true)
    let landed = expectation(description: "latest callback drained")
    DispatchQueue.main.async { landed.fulfill() }; await fulfillment(of: [landed], timeout: 1)
    tick?(); XCTAssertEqual(output.frames.count, count + 1)
  }

''' +s[at:];p.write_text(s)
import sys,json,subprocess
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:Path(f'packages/yl_player/example/{platform}/RunnerTests/YlDashResourceLoaderTests.swift').write_bytes(native_test_source(p))
r=Path('/private/tmp/yl-production-races');cmd=json.loads((r/'budget-red-command.json').read_text());cmd=[x.replace('budget-red.xcresult','seek-red.xcresult').replace('testProductionLoadCommitsRecoveryBudgetBeforeReturningAndFailureKeepsIt','testAutomaticUserSeekBlocksOldFramesUntilLatestLanding') for x in cmd];(r/'seek-red-command.json').write_text(json.dumps(cmd,indent=2)+'\n')
with (r/'seek-red.log').open('w') as f:result=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(r/'seek-red-result.json').write_text(json.dumps(dict(exitCode=result.returncode))+'\n');print('seek-red',result.returncode)
