from pathlib import Path
import sys
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();marker='  @MainActor func testSameDashCandidateRevocationCancelsPartiallyReceivedUpstream() async throws {'
t='''  @MainActor func testHeldBodyServerHandlesSplitHeadersAndContinuesUntilPeerEOF() async throws {
    let server = try DashHeldBodyServer(manifest:mpd,body:Data(repeating:1,count:128),redirect:URL(string:"http://127.0.0.1:1/revoke")!)
    defer { server.close() }
    let connection = NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:UInt16(server.url("/").port!))!,using:.tcp)
    defer { connection.cancel() }
    let ready = expectation(description:"client ready"), received = expectation(description:"partial response")
    let headerComplete = AbrPrerollCompletion()
    connection.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
    connection.start(queue:DispatchQueue.global()); await fulfillment(of:[ready],timeout:2)
    connection.receive(minimumIncompleteLength:1,maximumLength:4096) { data,_,_,error in
      XCTAssertNil(error); XCTAssertNotNil(data)
      XCTAssertEqual(headerComplete.result,true,"Server must not dispatch an incomplete request header")
      received.fulfill()
    }
    connection.send(content:Data("GET /ini".utf8),completion:.contentProcessed { _ in })
    try await Task.sleep(nanoseconds:100_000_000)
    headerComplete.finish(true)
    connection.send(content:Data("t.mp4 HTTP/1.1\\r\\nHost: owned\\r\\nX-Fixture-Hold: 1\\r\\n\\r\\n".utf8),completion:.contentProcessed { _ in })
    await fulfillment(of:[received],timeout:2)
    connection.send(content:Data("trailing-client-bytes".utf8),completion:.contentProcessed { _ in })
    try await Task.sleep(nanoseconds:100_000_000)
    connection.cancel()
    try await AppleHostCharacterizations.waitFor({ server.peerClosed==1 },timeout:2)
    XCTAssertEqual(server.heldCount,1)
  }

''';assert marker in s;s=s.replace(marker,t+marker,1);p.write_text(s)
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:(Path(f'packages/yl_player/example/{platform}/RunnerTests')/p.name).write_bytes(native_test_source(p))
