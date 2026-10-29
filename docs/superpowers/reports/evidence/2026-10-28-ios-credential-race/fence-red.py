from pathlib import Path
import sys
p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsHeaderPolicy.swift');s=p.read_text().replace('  func isStripped(_ resource: String) -> Bool {','''  func withUnchangedRevision(_ expected: UInt64, _ commit: () throws -> Void) rethrows -> Bool {
    guard revision == expected else { return false }
    try commit()
    return true
  }

  func isStripped(_ resource: String) -> Bool {''',1);p.write_text(s)
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();marker='  func testCredentialRevisionIsConcurrentIdempotentAndLoadScoped() {'
t='''  func testCredentialCommitFenceOrdersInstallationAndBackgroundStripping() throws {
    let context = YlHlsCredentialContext()
    let before = context.revision
    context.strip("first") // A redirect after the caller sampled, before commit.
    var installed = false
    XCTAssertFalse(context.withUnchangedRevision(before) { installed = true })
    XCTAssertFalse(installed)
    let attempted = DispatchSemaphore(value:0), finished = DispatchSemaphore(value:0)
    let done = expectation(description:"background stripping completes after commit")
    XCTAssertTrue(context.withUnchangedRevision(1) {
      DispatchQueue.global().async {
        attempted.signal(); context.strip("second"); finished.signal(); done.fulfill()
      }
      XCTAssertEqual(attempted.wait(timeout:.now()+1),.success)
      XCTAssertEqual(finished.wait(timeout:.now()+0.05),.timedOut,"Credential change cannot interleave inside accepted installation")
      installed = true
    })
    wait(for:[done],timeout:2)
    XCTAssertTrue(installed); XCTAssertEqual(context.revision,2)
    struct CommitFailure: Error {}
    XCTAssertThrowsError(try context.withUnchangedRevision(2) { throw CommitFailure() })
    context.strip("third"); XCTAssertEqual(context.revision,3,"Thrown commit must release the fence")
  }

''';assert marker in s;s=s.replace(marker,t+marker,1);p.write_text(s)
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path(f'packages/yl_player/example/{platform}/RunnerTests')/p.name).write_bytes(native_test_source(p))
