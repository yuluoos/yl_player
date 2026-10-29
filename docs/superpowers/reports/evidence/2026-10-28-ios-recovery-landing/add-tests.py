from pathlib import Path
import sys
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift')
s=p.read_text(); at=s.index('  @MainActor func testAutomaticUserSeekBlocksOldFramesUntilLatestLanding')
s=s[:at]+'''  @MainActor func testAutomaticReplacementFailedLandingCannotPublishWrongTimeline() async throws {
    for publicSeek in [false, true] {
      let player = DashCatalogClockPlayer(), output = AppleTestTexture(), pixels = DashPixelOutput(width: 320, height: 180)
      var failures: [NativePlayerError] = [], states: [YlNativeState] = []
      let backend = YlAvPlayerBackend(playerId: 99,
        services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in AppleTestDisplay() }),
        configuration: .init(map: ["audioPolicy": "appManaged"]), player: player, makeVideoOutput: { _ in pixels }, emit: {
          if case .failure(let error) = $0.event { failures.append(error) }
          if case .state(let state) = $0.event { states.append(state) }
        })
      defer { backend.dispose() }
      let data = mpd, source = YlAppleSourceDescriptor(uri: origin.absoluteString, kind: .network, formatHint: .dash)
      let original = try prepare(DashLoaderProtocol.configuration { $0.respond(data) })
      let snapshot = try XCTUnwrap(original.loader.dashSnapshot)
      try backend.stagePreparedHls(source: source, prepared: original, resume: false)
      try backend.activate()
      player.measuredTime = CMTime(seconds: 12, preferredTimescale: 1000)
      player.resetClockOnReplacement = true
      let replacement = try YlPreparedHlsAsset(originURL: origin, isDash: true, headers: [:],
        configuration: .init(map: [:]), cancellationToken: .init(), dashSnapshot: snapshot)
      try backend.replaceActiveDash(source: source, prepared: replacement)
      if publicSeek { try backend.seek(toMs: 20_000) }
      XCTAssertEqual(CMTimeGetSeconds(try XCTUnwrap(player.requestedSeek)), publicSeek ? 20 : 12)
      XCTAssertNil(backend.copyPixelBuffer()?.takeRetainedValue())
      let failedLanding = try XCTUnwrap(player.seekCompletion)
      failedLanding(false)
      let drained = expectation(description: "failed landing delivered")
      DispatchQueue.main.async { drained.fulfill() }; await fulfillment(of: [drained], timeout: 1)
      XCTAssertNil(backend.copyPixelBuffer()?.takeRetainedValue(), "A failed recovery landing cannot open output at the new item's zero position")
      XCTAssertEqual(failures.map(\\.code), ["source.seek_failed"])
      XCTAssertEqual(states.last?.status, "error")
      failedLanding(false)
      let duplicate = expectation(description: "duplicate drained")
      DispatchQueue.main.async { duplicate.fulfill() }; await fulfillment(of: [duplicate], timeout: 1)
      XCTAssertEqual(failures.count, 1, "Only the current landing can terminate once")
    }
  }

'''+s[at:];p.write_text(s)
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter')
from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:Path(f'packages/yl_player/example/{platform}/RunnerTests/YlDashResourceLoaderTests.swift').write_bytes(native_test_source(p))
