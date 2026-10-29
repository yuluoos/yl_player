from pathlib import Path
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();s=s.replace('  let buffer: CVPixelBuffer\n  var measuredItemTime', '  let buffer: CVPixelBuffer\n  var beforeCopy: (() -> Void)?\n  var measuredItemTime');s=s.replace('override func copyPixelBuffer(forItemTime itemTime: CMTime, itemTimeForDisplay outItemTimeForDisplay: UnsafeMutablePointer<CMTime>?) -> CVPixelBuffer? { buffer }','override func copyPixelBuffer(forItemTime itemTime: CMTime, itemTimeForDisplay outItemTimeForDisplay: UnsafeMutablePointer<CMTime>?) -> CVPixelBuffer? { beforeCopy?(); return buffer }')
at=s.index('  @MainActor func testAutomaticUserSeekBlocksOldFramesUntilLatestLanding')
s=s[:at]+'''  @MainActor func testSeekRevisionRejectsInFlightRasterCopyAndStaleFixedFailure() async throws {
    for fixed in [false, true] {
      let player = DashCatalogClockPlayer(), pixels = DashPixelOutput(width: fixed ? 640 : 320, height: fixed ? 360 : 180)
      var failures: [String] = []
      let backend = YlAvPlayerBackend(playerId: 99,
        services: .init(platform: .current, textureOutput: AppleTestTexture(), makeDisplayDriver: { _ in AppleTestDisplay() }),
        configuration: .init(map: ["audioPolicy": "appManaged"]), player: player, makeVideoOutput: { _ in pixels }, emit: {
          if case .failure(let error) = $0.event { failures.append(error.code) }
        })
      defer { backend.dispose() }
      let data = mpd
      try backend.stagePreparedHls(source: .init(uri: origin.absoluteString, kind: .network, formatHint: .dash),
        prepared: prepare(DashLoaderProtocol.configuration { $0.respond(data) }), resume: false)
      try backend.activate()
      if fixed {
        let track = try XCTUnwrap(backend.confirmedVideoTracks.first { $0.width == 320 })
        backend.acceptVideoSelection(.init(fixedTrackId: track.id, reason: "user"))
      }
      let entered = expectation(description: "raster copy entered"), released = DispatchSemaphore(value: 0)
      defer { released.signal() }
      pixels.beforeCopy = { entered.fulfill(); XCTAssertEqual(released.wait(timeout: .now()+3), .success) }
      let copy = Task.detached { backend.copyPixelBuffer()?.takeRetainedValue() != nil }
      await fulfillment(of: [entered], timeout: 1)
      try backend.seek(toMs: 1000)
      player.measuredTime = CMTime(seconds: 1, preferredTimescale: 1000)
      try XCTUnwrap(player.seekCompletion)(true)
      let landed = expectation(description: "seek landed")
      DispatchQueue.main.async { landed.fulfill() }; await fulfillment(of: [landed], timeout: 1)
      released.signal()
      let copied = await copy.value
      XCTAssertFalse(copied, "Old raster copy cannot cross a complete seek transition")
      let drained = expectation(description: "old errors drained")
      DispatchQueue.main.async { drained.fulfill() }; await fulfillment(of: [drained], timeout: 1)
      XCTAssertFalse(failures.contains("decoder.quality_constraint_unsupported"), "A stale fixed buffer cannot terminate the new landing")
    }
  }

''' +s[at:];p.write_text(s)
import sys,json,subprocess
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:Path(f'packages/yl_player/example/{platform}/RunnerTests/YlDashResourceLoaderTests.swift').write_bytes(native_test_source(p))
r=Path('/private/tmp/yl-production-races');cmd=json.loads((r/'seek-red-command.json').read_text());cmd=[x.replace('seek-red.xcresult','raster-red.xcresult').replace('testAutomaticUserSeekBlocksOldFramesUntilLatestLanding','testSeekRevisionRejectsInFlightRasterCopyAndStaleFixedFailure') for x in cmd];(r/'raster-red-command.json').write_text(json.dumps(cmd,indent=2)+'\n')
with (r/'raster-red.log').open('w') as f:result=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT)
(r/'raster-red-result.json').write_text(json.dumps(dict(exitCode=result.returncode))+'\n');print('raster-red',result.returncode)
