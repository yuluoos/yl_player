from pathlib import Path
b=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Session')
p=b/'YlAppleSessionCoordinator.swift';s=p.read_text().replace('  private let dashRecovery = YlDashAutoRecoveryController()','  private let dashRecovery: YlDashAutoRecoveryController').replace('       automaticDashRecoveryEnabled: Bool = true,','       automaticDashRecoveryEnabled: Bool = true,\n       dashRecoveryController: YlDashAutoRecoveryController = YlDashAutoRecoveryController(),').replace('    self.afterDashRecoveryPreparation = afterDashRecoveryPreparation','    self.dashRecovery = dashRecoveryController\n    self.afterDashRecoveryPreparation = afterDashRecoveryPreparation');p.write_text(s)
p=b/'YlApplePlayerHost.swift';s=p.read_text().replace('       automaticDashRecoveryEnabled: Bool = true,','       automaticDashRecoveryEnabled: Bool = true,\n       dashRecoveryController: YlDashAutoRecoveryController = YlDashAutoRecoveryController(),').replace('      automaticDashRecoveryEnabled: automaticDashRecoveryEnabled,','      automaticDashRecoveryEnabled: automaticDashRecoveryEnabled,\n      dashRecoveryController: dashRecoveryController,');p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();at=s.index('  func testProductionRecoveryBudgetUsesCommittedSessionNotReusedRequestLabel')
s=s[:at]+'''  @MainActor func testProductionLoadCommitsRecoveryBudgetBeforeReturningAndFailureKeepsIt() async throws {
    let server = try DashHTTPServer(), data = mpd
    defer { server.close() }
    server.handler = { request in
      (200, [:], request.path == "/bad.mpd" ? Data("<MPD type=\\"dynamic\\"/>".utf8) : data)
    }
    let controller = YlDashAutoRecoveryController()
    let host = YlApplePlayerHost(playerId: 992, suffix: "production-budget",
      options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 100),
      services: .init(platform: .current, textureOutput: AppleTestTexture(), makeDisplayDriver: { AppleClockDisplay(onTick: $0) }),
      callbacks: AppleRecordingCallbacks(), automaticDashRecoveryEnabled: false, dashRecoveryController: controller)
    defer { host.close() }
    try host.attach()
    let first = try await host.load(request: AppleHostFixture.request("reused", url: server.url("/movie.mpd").absoluteString, format: .dash))
    for t in [0.0, 1, 9, 17] {
      controller.tick(productionSample(t, high: t == 0), prepare: { _ in XCTFail("No ticket before backoff"); throw YlOpenCancellationToken.cancellationError() },
        currentSample: { nil }, commit: { _ in XCTFail("No installation"); return [:] })
    }
    XCTAssertEqual(host.dashRecoveryAttempts, 1)
    do {
      _ = try await host.load(request: AppleHostFixture.request("failed", url: server.url("/bad.mpd").absoluteString, format: .dash))
      XCTFail("Malformed candidate must not commit")
    } catch {}
    XCTAssertEqual(host.dashRecoveryAttempts, 1, "Failed Load keeps the surviving source budget")
    let second = try await host.load(request: AppleHostFixture.request("reused", url: server.url("/movie.mpd").absoluteString, format: .dash))
    XCTAssertNotEqual(first.sessionId, second.sessionId)
    XCTAssertEqual(host.dashRecoveryAttempts, 0, "New committed session cannot expose the old budget before the next timer tick")
    XCTAssertTrue(host.dashRecoveryEvents.isEmpty)
  }

''' +s[at:];p.write_text(s)
import sys
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:Path(f'packages/yl_player/example/{platform}/RunnerTests/YlDashResourceLoaderTests.swift').write_bytes(native_test_source(p))
r=Path('/private/tmp/yl-production-races');import json,subprocess
cmd=json.loads(Path('/private/tmp/yl-postcommit-failure/final-macos-contracts-command.json').read_text());cmd=[x for x in cmd if not x.startswith('-only-testing:')];cmd=[x.replace('/private/tmp/yl-postcommit-failure/final-macos-contracts.xcresult',str(r/'budget-red.xcresult')) for x in cmd];cmd.append('-only-testing:RunnerTests/YlDashResourceLoaderTests/testProductionLoadCommitsRecoveryBudgetBeforeReturningAndFailureKeepsIt');(r/'budget-red-command.json').write_text(json.dumps(cmd,indent=2)+'\n')
with (r/'budget-red.log').open('w') as f:result=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(r/'budget-red-result.json').write_text(json.dumps(dict(exitCode=result.returncode))+'\n');print('budget-red',result.returncode)
