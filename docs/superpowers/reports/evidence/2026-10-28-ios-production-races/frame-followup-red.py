from pathlib import Path
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();old='''        backend.acceptVideoSelection(.init(fixedTrackId: track.id, reason: "user"))
      }
      let entered = expectation(description: "raster copy entered")''';new='''        backend.acceptVideoSelection(.init(fixedTrackId: track.id, reason: "user"))
        // Commit a fixed landing before the background copy snapshots FramePolicy.
        try backend.seek(toMs: 0); try XCTUnwrap(player.seekCompletion)(true)
        let fixedReady = expectation(description: "fixed policy ready")
        DispatchQueue.main.async { fixedReady.fulfill() }; await fulfillment(of: [fixedReady], timeout: 1)
        XCTAssertEqual(backend.videoSelection.fixedTrackId, track.id)
      }
      let entered = expectation(description: "raster copy entered")''';assert old in s;s=s.replace(old,new)
at=s.index('  @MainActor func testSeekRevisionRejectsInFlightRasterCopyAndStaleFixedFailure')
s=s[:at]+'''  @MainActor func testConfirmedCapsFrameFailureCannotBecomeSilentAfterSeek() async throws {
    let player = DashCatalogClockPlayer(), pixels = DashPixelOutput(width: 640, height: 360)
    var failures: [String] = []
    let backend = YlAvPlayerBackend(playerId: 99,
      services: .init(platform: .current, textureOutput: AppleTestTexture(), makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), player: player, makeVideoOutput: { _ in pixels }, emit: {
        if case .failure(let error) = $0.event { failures.append(error.code) }
      })
    defer { backend.dispose() }
    let data = mpd
    let prepared = try YlPreparedHlsAsset(originURL: origin, isDash: true,
      videoConstraints: .init(maxWidth: 320, maxHeight: 180, maxBitrate: nil), headers: [:],
      configuration: .init(map: [:]), cancellationToken: .init(), sessionConfiguration: DashLoaderProtocol.configuration { $0.respond(data) })
    try backend.stagePreparedHls(source: .init(uri: origin.absoluteString, kind: .network, formatHint: .dash), prepared: prepared, resume: false)
    try backend.activate()
    XCTAssertNil(backend.copyPixelBuffer()?.takeRetainedValue(), "Current caps violation is synchronously rejected and latched")
    try backend.seek(toMs: 1000)
    try XCTUnwrap(player.seekCompletion)(true)
    let drained = expectation(description: "confirmed terminal delivered")
    DispatchQueue.main.async { drained.fulfill() }; await fulfillment(of: [drained], timeout: 1)
    XCTAssertEqual(failures, ["decoder.quality_constraint_unsupported"], "Seek must not suppress a confirmed terminal latch and silently block output")
  }

''' +s[at:];p.write_text(s)
import sys,json,subprocess
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:Path(f'packages/yl_player/example/{platform}/RunnerTests/YlDashResourceLoaderTests.swift').write_bytes(native_test_source(p))
r=Path('/private/tmp/yl-production-races');cmd=json.loads((r/'raster-red-command.json').read_text());cmd=[x.replace('raster-red.xcresult','caps-latch-red.xcresult').replace('testSeekRevisionRejectsInFlightRasterCopyAndStaleFixedFailure','testConfirmedCapsFrameFailureCannotBecomeSilentAfterSeek') for x in cmd];(r/'caps-latch-red-command.json').write_text(json.dumps(cmd,indent=2)+'\n')
with (r/'caps-latch-red.log').open('w') as f:result=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(r/'caps-latch-red-result.json').write_text(json.dumps(dict(exitCode=result.returncode))+'\n');print('caps-latch-red',result.returncode)
