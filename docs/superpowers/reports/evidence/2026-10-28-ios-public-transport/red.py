from pathlib import Path
import json,subprocess,sys
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text().replace('    let bytes: Int64, transfer: Double, requests: Int, overdue: Int\n','    let bytes: Int64, transfer: Double, requests: Int, overdue: Int\n    var intentRevision: UInt64 = 0\n',1)
at='  func testAutomaticRecoveryCandidateBudgetAndSafety() {\n'
t='''  func testRecoveryTicketRejectsAcknowledgedIntentRevisionWithoutItemChange() throws {
    var policy = AbrDiagnosticRecoveryPolicy()
    func sample(_ time: Double, width: Int = 320, revision: UInt64 = 0) -> AbrDiagnosticRecoveryPolicy.Sample {
      .init(time: time, generation: 0, allowed: true, width: width,
        position: time, remaining: 120 - time, bufferAhead: 10,
        bytes: Int64(time * 200_000), transfer: time, requests: Int(time * 4), overdue: 1,
        intentRevision: revision)
    }
    for (time, width) in [(0.0,640),(1.0,320),(9.0,320),(17.0,320)] { _ = policy.observe(sample(time,width:width)) }
    let ticket = try XCTUnwrap(policy.observe(sample(17.5)))
    XCTAssertTrue(policy.authorizes(ticket, sample(17.6)))
    XCTAssertFalse(policy.authorizes(ticket, sample(17.6, revision: 1)), "An acknowledged forward seek keeps the item but revokes its old ticket")
    _ = policy.observe(sample(18, revision: 1))
    XCTAssertFalse(policy.authorizes(ticket, sample(18.1, revision: 2)), "Pause/resume or a second seek cannot revive old authority")
    XCTAssertEqual(policy.attempts, 1, "Changing accepted intent never refunds source budget")
    _ = policy.observe(sample(26, revision: 1)); _ = policy.observe(sample(34, revision: 1))
    XCTAssertEqual(policy.attempts, 2)
    XCTAssertNil(policy.observe(sample(34.99, revision: 1)))
    let next = try XCTUnwrap(policy.observe(sample(35, revision: 1)))
    XCTAssertEqual(next.attempt, 2)
    XCTAssertTrue(policy.authorizes(next, sample(35.1, revision: 1)))
  }

'''
assert at in s;s=s.replace(at,t+at);p.write_text(s)
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path(f'packages/yl_player/example/{platform}/RunnerTests')/p.name).write_bytes(native_test_source(p))
raw=Path('/private/tmp/yl-public-transport');cmd=json.loads(Path('/private/tmp/yl-public-race/final-macos-contracts-command.json').read_text());cmd=[x for x in cmd if not x.startswith('-only-testing:')];cmd[cmd.index('-resultBundlePath')+1]=str(raw/'intent-red.xcresult');cmd+=['-only-testing:RunnerTests/YlDashResourceLoaderTests/testRecoveryTicketRejectsAcknowledgedIntentRevisionWithoutItemChange']
(raw/'intent-red-command.json').write_text(json.dumps(cmd,indent=2)+'\n')
with (raw/'intent-red.log').open('w') as f:r=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(raw/'intent-red-result.json').write_text(json.dumps(dict(exitCode=r.returncode))+'\n');print(r.returncode)
