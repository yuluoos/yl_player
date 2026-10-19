import XCTest
import AVFoundation
import Network
import UIKit
@testable import yl_player_apple

@MainActor
final class YlAppleHostTests: XCTestCase {
  func testCancelOpenMatchesOnlyThePreparingCandidate() async throws {
    try await AppleHostCharacterizations.cancelCandidate(self)
  }
  func testPlayerVolumeAndCandidateOptionsSurviveFailedReplacementAndStop() async throws {
    try await AppleHostCharacterizations.volumeAndOptions(self)
  }
  func testStopCancelsPendingOpenRetainsTextureAndAllowsFreshOpen() async throws {
    try await AppleHostCharacterizations.stopPending(self)
  }
  func testPlayerPersistsSuccessfulQualityConstraint() async throws {
    try await AppleHostCharacterizations.persistedQuality(self)
  }
  func testCapabilitiesDescribeCompletePlayerWithCanonicalMimeCodecs() async throws {
    try await AppleHostCharacterizations.capabilities(self)
  }
  func testCapabilitiesOmitUnsupportedHardwareCodecs() async throws {
    try await AppleHostCharacterizations.capabilities(self, hevc: false)
  }
  func testFallbackMetricsUseDartContractDroppedFrameKey() async throws {
    try await AppleHostCharacterizations.metrics(self)
  }
  func testChannelGenerationsAreStrictlyIncreasing() async throws {
    try await AppleHostCharacterizations.generations(self)
  }
  func testFullStateEnvelopeUsesVersionedGeneration() async throws {
    try await AppleHostCharacterizations.fullState(self)
  }
  func testDeltaEnvelopeContainsOnlyDynamicPayload() async throws {
    try await AppleHostCharacterizations.delta(self)
  }
  func testFailedReplacementThenReactivationPreservesAcceptedSessionControls() async throws {
    try await AppleHostCharacterizations.reactivation(self)
  }
}

@MainActor
final class YlAppleMemoryWarningTests: XCTestCase {
  func testExternalPlaybackSurvivesBackgroundAndRevocationSuspends() async throws {
    let center = NotificationCenter()
    let registry = YlApplePlayerRegistry(makeServices: { _ in YlAppleRegistryTests.services() },
      makeCallbacks: { _ in AppleRecordingCallbacks() }, installHost: { _, _ in },
      lifecycle: YlIosLifecycle(center: center))
    defer { registry.detach() }
    registry.setExternalPlaybackActive(true)
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    let created = try registry.create(request: .init(schemaMajor: 7,
      options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 500)))
    let host = try XCTUnwrap(registry.host(for: created.channelSuffix))
    _ = try await host.load(request: AppleHostFixture.request("car"))
    XCTAssertTrue(host.isActive, "Car-only launches can create a player in the background")
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    XCTAssertTrue(host.isActive, "Locking the phone must not suspend external playback")
    registry.setExternalPlaybackActive(false)
    XCTAssertFalse(host.isActive, "Disconnect revokes the background exemption")
    registry.setExternalPlaybackActive(true)
    try await AppleHostCharacterizations.waitFor({ host.isActive })
  }

  func testForegroundRestoresOnlyPreviouslyActivePlayer() async throws {
    let center = NotificationCenter()
    let registry = YlApplePlayerRegistry(makeServices: { _ in YlAppleRegistryTests.services() },
      makeCallbacks: { _ in AppleRecordingCallbacks() }, installHost: { _, _ in },
      lifecycle: YlIosLifecycle(center: center))
    defer { registry.detach() }
    let options = ApplePlayerOptionsMessage(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 500)
    let a = try registry.create(request: .init(schemaMajor: 7, options: options))
    let b = try registry.create(request: .init(schemaMajor: 7, options: options))
    let old = try XCTUnwrap(registry.host(for: a.channelSuffix))
    let current = try XCTUnwrap(registry.host(for: b.channelSuffix))
    _ = try await old.load(request: AppleHostFixture.request("old"))
    _ = try await current.load(request: AppleHostFixture.request("current"))
    XCTAssertFalse(old.isActive)
    XCTAssertTrue(current.isActive)
    var oldRestorations = 0
    let oldCommit = old.didCommit
    old.didCommit = { oldRestorations += 1; oldCommit?() }
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    XCTAssertFalse(current.isActive)
    center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    try await AppleHostCharacterizations.waitFor({ current.isActive })
    XCTAssertFalse(old.isActive)
    XCTAssertEqual(oldRestorations, 0, "Foreground cannot revive a peer that was inactive before suspension")
  }

  func testActualLifecycleMemoryWarningDeactivatesSessionAndPreservesTexture() async throws {
    let key = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "hls_key", withExtension: "bin"))
    let segment = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "hls_encrypted_segment0", withExtension: "ts"))
    let server = try RollbackHlsServer(key: Data(contentsOf: key), segment: Data(contentsOf: segment))
    defer { server.close() }
    let center = NotificationCenter()
    let lifecycle = YlIosLifecycle(center: center)
    let output = AppleTestTexture()
    let callbacks = AppleRecordingCallbacks()
    let registry = YlApplePlayerRegistry(makeServices: { _ in
      YlPlatformServices(platform: .ios, textureOutput: output,
        makeDisplayDriver: { AppleClockDisplay(onTick: $0) }, activateAudioSession: {})
    }, makeCallbacks: { _ in callbacks }, installHost: { _, _ in }, lifecycle: lifecycle)
    defer { registry.detach() }
    let created = try registry.create(request: .init(schemaMajor: 7,
      options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 500)))
    let host = try XCTUnwrap(registry.host(for: created.channelSuffix))
    try host.attach()
    var request = AppleHostFixture.request("memory", url: server.url.absoluteString, format: .hls)
    request.source.request = .init(headers: [:], credentials: ["Authorization": "Bearer rollback-test"])
    let loaded = try await host.load(request: request)
    try await AppleHostCharacterizations.waitFor({ host.initialState.status == .ready || host.initialState.status == .paused })
    XCTAssertTrue(host.isActive)
    center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    XCTAssertFalse(host.isActive)
    XCTAssertEqual(host.sessionId, loaded.sessionId)
    XCTAssertEqual(host.initialState.status, .paused)
    XCTAssertNil(host.initialState.failure)
    XCTAssertEqual(output.disposals, 0)
    try await host.play(command: .init(sessionId: loaded.sessionId))
    XCTAssertTrue(host.isActive)
    XCTAssertEqual(host.sessionId, loaded.sessionId)
    registry.detach()
    XCTAssertEqual(output.disposals, 1)
    center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    XCTAssertEqual(output.disposals, 1)
  }
}

@MainActor
final class YlAirPlayHostTests: XCTestCase {
  func testDirectAirPlayAssessmentPreservesStrictPolicyRejection() throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    var request = AppleHostFixture.request("airplay", url: "https://example.invalid/video.m3u8", format: .hls)
    let direct = try f.host.assessAirPlay(request: .init(source: request.source, options: request.options))
    XCTAssertEqual(direct.outcome, .compatible)
    XCTAssertEqual(direct.candidateEngine, .avPlayer)
    request.options.decoderPolicyOverride = .hardwareRequired
    let strict = try f.host.assessAirPlay(request: .init(source: request.source, options: request.options))
    XCTAssertEqual(strict.outcome, .incompatible)
    XCTAssertEqual(strict.rejection?.code, "policy.unsupported")
  }

  func testAirPlayCustomSourceNeedsInspectionAndHeaderedHlsIsRejected() throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    var request = AppleHostFixture.request("airplay", url: "https://example.invalid/video.mkv", format: .matroska)
    let custom = try f.host.assessAirPlay(request: .init(source: request.source, options: request.options))
    XCTAssertEqual(custom.outcome, .requiresInspection)
    XCTAssertEqual(custom.candidateEngine, .avPlayer)
    request.source.format = .hls
    request.source.request = .init(headers: ["X-AirPlay-Test": "private"], credentials: [:])
    let headered = try f.host.assessAirPlay(request: .init(source: request.source, options: request.options))
    XCTAssertEqual(headered.outcome, .incompatible)
    XCTAssertEqual(headered.rejection?.code, "policy.unsupported")
    XCTAssertFalse(f.host.airPlayState["enabled"] as! Bool)
  }

  func testRejectedAirPlayLoadPreservesExistingSession() async throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    let original = try await f.load(AppleHostFixture.request("original"))
    var request = AppleHostFixture.request("rejected", url: "https://example.invalid/drm.m3u8", format: .hls)
    request.options.decoderPolicyOverride = .hardwareRequired
    do { _ = try await f.host.loadAirPlay(request: request); XCTFail("strict AirPlay load accepted") } catch {}
    XCTAssertEqual(f.host.initialState.sessionId, original.sessionId)
    XCTAssertFalse(f.host.airPlayState["enabled"] as! Bool)
  }
}


@MainActor
extension YlAirPlayHostTests {
  func testAutomaticHlsLiveLoadsReadyWithAirPlayEnabled() async throws {
    let server = try AirPlayLiveFixtureServer(bundle: Bundle(for: Self.self))
    defer { server.close() }
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    var request = AppleHostFixture.request("live-airplay", url: server.url.absoluteString, format: .automatic)
    request.source.intent = .live
    let reply = try await f.host.loadAirPlay(request: request)
    XCTAssertEqual(f.host.sessionId, reply.sessionId)
    XCTAssertEqual(f.host.initialState.engine, .avPlayer)
    XCTAssertTrue(f.av.allowsExternalPlayback)
    let item = try XCTUnwrap(f.av.currentItem)
    try await AppleHostCharacterizations.waitFor({ item.status == .readyToPlay }, timeout: 15)
    XCTAssertEqual((item.asset as? AVURLAsset)?.url, server.url,
      "Live HLS must use the original stream, never complete-VOD remux")
    XCTAssertEqual(f.host.airPlayState["enabled"] as? Bool, true)
    XCTAssertNil(f.host.initialState.failure)
  }

  func testAutomaticLiveAirPlayRequiresInspectionInsteadOfRejection() throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    var request = AppleHostFixture.request("live", url: "https://example.invalid/live.m3u8", format: .automatic)
    request.source.intent = .live
    let result = try f.host.assessAirPlay(request: .init(source: request.source, options: request.options))
    XCTAssertEqual(result.outcome, .requiresInspection)
    XCTAssertNil(result.rejection)
  }

  func testAirPlayOptInBelongsToCommittedLoadAndStopClearsIt() async throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    let loaded = try await f.host.loadAirPlay(request: AppleHostFixture.request("remote"))
    XCTAssertTrue(f.av.allowsExternalPlayback)
    XCTAssertEqual(f.host.airPlayState["sessionId"] as? String, loaded.sessionId)
    XCTAssertEqual(f.host.airPlayState["enabled"] as? Bool, true)
    let revision = try XCTUnwrap(f.host.airPlayState["revision"] as? Int64)
    _ = try await f.load(AppleHostFixture.request("local"))
    XCTAssertFalse(f.av.allowsExternalPlayback)
    XCTAssertEqual(f.host.airPlayState["enabled"] as? Bool, false)
    XCTAssertGreaterThan(f.host.airPlayState["revision"] as! Int64, revision)
    try await f.host.stop()
    XCTAssertTrue(f.host.airPlayState["sessionId"] is NSNull)
  }

  func testReplacingAirPlayWithFallbackReleasesRetiredOrigin() async throws {
    #if targetEnvironment(simulator)
    // This test asserts ownership/cleanup, not hardware decode. AVPlayer still
    // consumes the real remux; only the replacement decoder is substituted.
    let f = AppleHostFixture(videoSessionFactory: AirPlayPassiveVTFactory())
    #else
    let f = AppleHostFixture()
    #endif
    defer { f.host.close() }
    try f.host.attach()
    let server = try ReactivationMediaServer(data: AppleHostCharacterizations.fixtureMedia()); defer { server.close() }
    _ = try await f.host.loadAirPlay(request: AppleHostFixture.request("remux", url: server.url.absoluteString, format: .matroska))
    let url = try XCTUnwrap((f.av.currentItem?.asset as? AVURLAsset)?.url)
    _ = try await f.load(AppleHostFixture.request("fallback", url: server.url.absoluteString, format: .matroska))
    XCTAssertNil(f.av.currentItem)
    XCTAssertEqual(f.host.airPlayState["enabled"] as? Bool, false)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    let client = URLSession(configuration: configuration)
    defer { client.invalidateAndCancel() }
    do { _ = try await client.data(from: url); XCTFail("Replaced AirPlay origin still serves media") } catch {}
  }

  func testNetworkCustomSourceLoadsThroughAirPlayRemuxAndReleasesOriginOnStop() async throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    let server = try ReactivationMediaServer(data: AppleHostCharacterizations.fixtureMedia()); defer { server.close() }
    let reply = try await f.host.loadAirPlay(request: AppleHostFixture.request("remux", url: server.url.absoluteString, format: .matroska))
    XCTAssertEqual(f.host.initialState.sessionId, reply.sessionId)
    XCTAssertTrue(f.av.allowsExternalPlayback)
    let item = try XCTUnwrap(f.av.currentItem)
    try await AppleHostCharacterizations.waitFor({ item.status == .readyToPlay }, timeout: 15)
    XCTAssertEqual(f.host.airPlayState["enabled"] as? Bool, true)
    let url = try XCTUnwrap((item.asset as? AVURLAsset)?.url)
    XCTAssertEqual(url.pathExtension, "m3u8")
    let (_, response) = try await URLSession.shared.data(from: url)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    try await f.host.stop()
    XCTAssertNil(f.av.currentItem)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    let client = URLSession(configuration: configuration)
    defer { client.invalidateAndCancel() }
    do { _ = try await client.data(from: url); XCTFail("Retired AirPlay origin still serves media") } catch {}
  }
}

private final class AirPlayLiveFixtureServer {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "yl.test.airplay-live")
  private var connections = [NWConnection]()
  var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/live.m3u8")! }
  init(bundle: Bundle) throws {
    let segment = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "hls_encrypted_segment0", withExtension: "ts")))
    let key = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "hls_key", withExtension: "bin")))
    let playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x00000000000000000000000000000000\n"
      + (0..<5).map { "#EXT-X-DISCONTINUITY\n#EXTINF:1.968,\nsegment\($0).ts\n" }.joined()
    listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      self.connections.append(connection)
      connection.start(queue: self.queue)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { bytes, _, _, _ in
        let path = String(decoding: bytes ?? Data(), as: UTF8.self)
          .split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let body: Data; let type: String
        if path == "/live.m3u8" { body = Data(playlist.utf8); type = "application/vnd.apple.mpegurl" }
        else if path == "/key.bin" { body = key; type = "application/octet-stream" }
        else if (0..<5).contains(where: { path == "/segment\($0).ts" }) { body = segment; type = "video/mp2t" }
        else { connection.cancel(); return }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
      }
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
      listener.cancel(); throw NSError(domain: "AirPlayLiveFixtureServer", code: 1)
    }
  }
  func close() { queue.sync { listener.cancel(); connections.forEach { $0.cancel() }; connections.removeAll() } }
}

#if targetEnvironment(simulator)
private final class AirPlayPassiveVTFactory: YlVTSessionFactory {
  func makeSession(formatDescription: CMVideoFormatDescription,
      output: @escaping (YlVTDecodedImage) -> Void) throws -> YlVTSession { AirPlayPassiveVTSession() }
}
private final class AirPlayPassiveVTSession: YlVTSession {
  let usesHardwareDecoder = true
  let hardwareEvidence = YlHardwareDecoderEvidence(mode: .hardware)
  func decode(_ sample: CMSampleBuffer, generation: UInt64, reservation: YlVideoDecodeReservation?) -> OSStatus {
    reservation?.release(); return noErr
  }
  func flush() {}
  func invalidate() {}
}
#endif

@MainActor
extension YlAirPlayHostTests {
  func testHttpFlvAirPlayBecomesReadyBeforeEOFAndRollsUntilStop() async throws {
    let upstream = try AirPlayFlvFixtureServer(); defer { upstream.close() }
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    var request = AppleHostFixture.request("flv-live", url: upstream.url.absoluteString, format: .flv)
    request.source.intent = .live
    _ = try await f.host.loadAirPlay(request: request)
    let item = try XCTUnwrap(f.av.currentItem)
    try await AppleHostCharacterizations.waitFor({ item.status == .readyToPlay }, timeout: 15)
    XCTAssertTrue(f.av.allowsExternalPlayback)
    XCTAssertGreaterThan(upstream.activeCount, 0, "Load must commit while upstream remains connected")
    let origin = try XCTUnwrap((item.asset as? AVURLAsset)?.url)
    XCTAssertNotEqual(origin, upstream.url)
    let first = try await livePlaylist(origin)
    XCTAssertFalse(first.contains("#EXT-X-ENDLIST"))
    XCTAssertFalse(first.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
    XCTAssertTrue(first.contains("#EXT-X-MAP:"))
    let sequence = try mediaSequence(first)
    var rolling = first
    for _ in 0..<100 {
      rolling = try await livePlaylist(origin)
      if try mediaSequence(rolling) > sequence { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertGreaterThan(try mediaSequence(rolling), sequence)
    XCTAssertNil(f.host.initialState.failure)
    try await f.host.stop()
    try await AppleHostCharacterizations.waitFor({ upstream.activeCount == 0 }, timeout: 5)
    XCTAssertGreaterThan(upstream.disconnectCount, 0)
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 2
    let client = URLSession(configuration: config); defer { client.invalidateAndCancel() }
    do { _ = try await client.data(from: origin); XCTFail("Stopped live origin still serves requests") } catch {}
  }

  func testHttpFlvAirPlayReconnectPublishesDiscontinuityAndNewMap() async throws {
    let upstream = try AirPlayFlvFixtureServer(); defer { upstream.close() }
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    var request = AppleHostFixture.request("flv-recovery", url: upstream.url.absoluteString, format: .flv)
    request.source.intent = .live
    let reply = try await f.host.loadAirPlay(request: request)
    let item = try XCTUnwrap(f.av.currentItem)
    try await AppleHostCharacterizations.waitFor({ item.status == .readyToPlay }, timeout: 15)
    let origin = try XCTUnwrap((item.asset as? AVURLAsset)?.url)
    let before = try await livePlaylist(origin)
    let firstMaps = Set(before.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-MAP:") }.map(String.init))
    let accepted = upstream.acceptCount
    upstream.disconnectCurrent()
    try await AppleHostCharacterizations.waitFor({ upstream.acceptCount > accepted }, timeout: 10)
    var recovered = ""
    for _ in 0..<100 {
      recovered = try await livePlaylist(origin)
      let maps = Set(recovered.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-MAP:") }.map(String.init))
      if recovered.contains("#EXT-X-DISCONTINUITY\n") && !maps.subtracting(firstMaps).isEmpty { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    let maps = Set(recovered.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-MAP:") }.map(String.init))
    XCTAssertTrue(recovered.contains("#EXT-X-DISCONTINUITY\n"))
    XCTAssertFalse(maps.subtracting(firstMaps).isEmpty)
    XCTAssertFalse(recovered.contains("#EXT-X-ENDLIST"))
    XCTAssertEqual(f.host.sessionId, reply.sessionId)
    XCTAssertTrue(f.av.currentItem === item)
    XCTAssertNil(f.host.initialState.failure)
    try await f.host.stop()
  }

  func testAutomaticRtmpAirPlayBecomesReadyWithoutUpstreamEOF() async throws {
    let upstream = try YlRtmpFixturePeer(repetitions: 32); defer { upstream.close() }
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    var request = AppleHostFixture.request("rtmp-live", url: "rtmp://127.0.0.1:\(upstream.port)/live/owned", format: .automatic)
    request.source.intent = .automatic
    _ = try await f.host.loadAirPlay(request: request)
    let item = try XCTUnwrap(f.av.currentItem)
    try await AppleHostCharacterizations.waitFor({ item.status == .readyToPlay }, timeout: 15)
    let origin = try XCTUnwrap((item.asset as? AVURLAsset)?.url)
    XCTAssertEqual(origin.pathExtension, "m3u8")
    XCTAssertEqual(upstream.acceptCount, 1)
    let playlist = try await livePlaylist(origin)
    XCTAssertFalse(playlist.contains("#EXT-X-ENDLIST"))
    XCTAssertNil(f.host.initialState.failure)
    try await f.host.stop()
  }

  func testStoppingHeldRtmpAirPlayStartupCancelsPromptly() async throws {
    let upstream = try RtmpScriptPeer(prefix: Data()); defer { upstream.close() }
    let f = AppleHostFixture(); defer { f.host.close() }
    try f.host.attach()
    var request = AppleHostFixture.request("rtmp-held", url: "rtmp://127.0.0.1:\(upstream.port)/live/held", format: .automatic)
    request.source.intent = .live
    var completed = false
    var failure: Error?
    let loading = Task { @MainActor in
      defer { completed = true }
      do { _ = try await f.host.loadAirPlay(request: request); XCTFail("Held startup committed") }
      catch { failure = error }
    }
    try await AppleHostCharacterizations.waitFor({ upstream.acceptCount > 0 }, timeout: 5)
    try await f.host.stop()
    try await AppleHostCharacterizations.waitFor({ completed }, timeout: 3)
    await loading.value
    XCTAssertNotNil(failure)
    XCTAssertNil(f.av.currentItem)
    XCTAssertEqual(f.host.airPlayState["enabled"] as? Bool, false)
  }

  func testAutomaticRtmpsLoadAndAirPlayReachTlsAndRejectUntrustedPeer() async throws {
    for airPlay in [false, true] {
      let peer = try YlRtmpFixturePeer(tlsIdentity: ManagedTLSFixture.localhost)
      defer { peer.close() }
      let f = AppleHostFixture(); defer { f.host.close() }
      var request = AppleHostFixture.request("rtmps-auto", url: "rtmps://127.0.0.1:\(peer.port)/live/private-token", format: .automatic)
      request.source.intent = .automatic
      do {
        if airPlay { _ = try await f.host.loadAirPlay(request: request) }
        else { _ = try await f.host.load(request: request) }
        XCTFail("Untrusted RTMPS must fail")
      } catch {
        XCTAssertEqual((error as? PigeonError)?.code, "network.rtmp_tls_failed")
      }
      XCTAssertEqual(peer.acceptCount, 1)
      XCTAssertNil(f.host.sessionId)
      XCTAssertEqual(f.host.airPlayState["enabled"] as? Bool, false)
    }
  }

  func testRtmpAirPlayRetainsTransportAndStrictPolicyRejections() throws {
    let f = AppleHostFixture(); defer { f.host.close() }
    var base = AppleHostFixture.request("rtmp-policy", url: "rtmp://127.0.0.1:1935/live/owned", format: .automatic)
    base.source.intent = .live
    var secure = base; secure.source.locator = "rtmps://127.0.0.1:1935/live/owned"
    var finite = base; finite.source.intent = .onDemand
    var headers = base; headers.source.request = .init(headers: ["Authorization": "private"], credentials: [:])
    var strict = base; strict.options.decoderPolicyOverride = .hardwareRequired
    let secureAssessment = try f.host.assessAirPlay(request: .init(source: secure.source, options: secure.options))
    XCTAssertEqual(secureAssessment.outcome, .requiresInspection)
    XCTAssertNil(secureAssessment.rejection)
    for request in [finite, headers, strict] {
      let assessment = try f.host.assessAirPlay(request: .init(source: request.source, options: request.options))
      XCTAssertEqual(assessment.outcome, .incompatible)
      XCTAssertNotNil(assessment.rejection)
    }
  }

  private func livePlaylist(_ url: URL) async throws -> String {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    return String(decoding: data, as: UTF8.self)
  }

  private func mediaSequence(_ playlist: String) throws -> Int {
    let line = try XCTUnwrap(playlist.split(separator: "\n").first { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") })
    return try XCTUnwrap(Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)))
  }
}

/// A genuinely open HTTP response: FLV header once, timestamp-shifted AV tags,
/// no video end-of-sequence marker, and no transport EOF until explicitly cut.
private final class AirPlayFlvFixtureServer {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "yl.test.airplay-flv")
  private var connections: [UUID: NWConnection] = [:]
  private var accepted = 0
  private var disconnected = 0
  private let header: Data
  private let tags: [(Data, UInt32)]
  private let span: UInt32
  var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/live.flv")! }
  var activeCount: Int { queue.sync { connections.count } }
  var acceptCount: Int { queue.sync { accepted } }
  var disconnectCount: Int { queue.sync { disconnected } }

  init() throws {
    let resource = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "flv"))
    let data = try Data(contentsOf: resource)
    header = Data(data.prefix(13))
    var parsed: [(Data, UInt32)] = []
    var offset = 13
    while offset < data.count {
      guard data.count - offset >= 15 else { throw YlByteSourceError.closed }
      let length = Int(data.rtmpUInt(offset + 1, 3))
      guard offset + length + 15 <= data.count else { throw YlByteSourceError.closed }
      let type = data[offset]
      let timestamp = UInt32(data.rtmpUInt(offset + 4, 3)) | UInt32(data[offset + 7]) << 24
      if (type == 8 || type == 9) && !(type == 9 && length >= 2 && data[offset + 12] == 2) {
        parsed.append((data.subdata(in: offset..<offset + length + 15), timestamp))
      }
      offset += length + 15
    }
    tags = parsed
    span = (parsed.map { $0.1 }.max() ?? 0) + 40
    listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      let id = UUID(); self.connections[id] = connection; self.accepted += 1
      connection.start(queue: self.queue)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] _, _, _, error in
        guard let self, error == nil else { connection.cancel(); return }
        let response = Data("HTTP/1.1 200 OK\r\nContent-Type: video/x-flv\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        var initial = response + self.header
        for epoch in 0..<16 { initial.append(self.body(epoch)) }
        connection.send(content: initial, completion: .contentProcessed { [weak self] error in
          guard let self else { return }
          if error != nil { self.retire(id); return }
          self.append(id, epoch: 16)
        })
        self.observeClose(id)
      }
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success else { listener.cancel(); throw YlByteSourceError.closed }
  }

  private func body(_ epoch: Int) -> Data {
    var output = Data()
    for (original, timestamp) in tags {
      var tag = original
      let time = timestamp + UInt32(epoch) * span
      tag[4] = UInt8(truncatingIfNeeded: time >> 16)
      tag[5] = UInt8(truncatingIfNeeded: time >> 8)
      tag[6] = UInt8(truncatingIfNeeded: time)
      tag[7] = UInt8(truncatingIfNeeded: time >> 24)
      output.append(tag)
    }
    return output
  }

  private func append(_ id: UUID, epoch: Int) {
    queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self, let connection = self.connections[id] else { return }
      connection.send(content: self.body(epoch), completion: .contentProcessed { [weak self] error in
        guard let self else { return }
        if error != nil { self.retire(id) } else { self.append(id, epoch: epoch + 1) }
      })
    }
  }

  private func observeClose(_ id: UUID) {
    guard let connection = connections[id] else { return }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, ended, error in
      guard let self else { return }
      if ended || error != nil { self.retire(id) } else { self.observeClose(id) }
    }
  }

  private func retire(_ id: UUID) {
    guard let connection = connections.removeValue(forKey: id) else { return }
    disconnected += 1
    connection.cancel()
  }
  func disconnectCurrent() { queue.sync { Array(connections.keys).forEach { retire($0) } } }
  func close() { queue.sync { listener.cancel(); Array(connections.keys).forEach { retire($0) } } }
}

@MainActor
extension YlAirPlayHostTests {
  func testLiveProducerFailureIsFencedAfterReplacementAndCurrentFailureTerminates() async throws {
    let origin = try AirPlayLiveFixtureServer(bundle: Bundle(for: Self.self)); defer { origin.close() }
    let old = AirPlayFailureFixture(), current = AirPlayFailureFixture()
    var failures: [NativePlayerError] = []
    let backend = YlAvPlayerBackend(playerId: 97,
      services: .init(platform: .current, textureOutput: AppleTestTexture(), makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: PlayerConfiguration(map: [:]), emit: {
        if case .failure(let error) = $0.event { failures.append(error) }
      })
    defer { backend.dispose() }
    try backend.activate()
    try backend.open(old.source(origin.url))
    XCTAssertEqual(old.handlers.count, 1)
    let retiredCallback = try XCTUnwrap(old.handlers.last)
    try backend.open(current.source(origin.url))
    XCTAssertEqual(old.cleanups, 1)
    retiredCallback(AirPlayFailureFixture.terminal)
    for _ in 0..<12 { await Task.yield() }
    XCTAssertTrue(failures.isEmpty)
    XCTAssertTrue(backend.isActive)
    current.fail()
    try await AppleHostCharacterizations.waitFor({ !failures.isEmpty }, timeout: 3)
    XCTAssertEqual(failures.map(\.code), [AirPlayFailureFixture.terminal.code])
    XCTAssertFalse(backend.isActive)
    backend.stop()
    XCTAssertEqual(current.cleanups, 1)
    backend.dispose()
    XCTAssertEqual(old.cleanups, 1)
    XCTAssertEqual(current.cleanups, 1)
  }

  func testSuspendedLiveProducerRetainsOwnershipAndReplaysFailureOnActivation() async throws {
    let origin = try AirPlayLiveFixtureServer(bundle: Bundle(for: Self.self)); defer { origin.close() }
    let producer = AirPlayFailureFixture()
    var failures: [NativePlayerError] = []
    let backend = YlAvPlayerBackend(playerId: 98,
      services: .init(platform: .current, textureOutput: AppleTestTexture(), makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: PlayerConfiguration(map: [:]), emit: {
        if case .failure(let error) = $0.event { failures.append(error) }
      })
    defer { backend.dispose() }
    try backend.activate()
    try backend.open(producer.source(origin.url))
    backend.deactivate()
    XCTAssertEqual(producer.cleanups, 0)
    producer.fail()
    for _ in 0..<12 { await Task.yield() }
    XCTAssertTrue(failures.isEmpty)
    try backend.activate()
    try await AppleHostCharacterizations.waitFor({ !failures.isEmpty }, timeout: 3)
    XCTAssertEqual(producer.handlers.count, 2)
    XCTAssertEqual(failures.map(\.code), [AirPlayFailureFixture.terminal.code])
    XCTAssertFalse(backend.isActive)
    backend.stop()
    XCTAssertEqual(producer.cleanups, 1)
  }
}

private final class AirPlayFailureFixture {
  static let terminal = NativePlayerError(category: "network", code: "airplay.live_failed", message: "Fixture producer ended")
  var handlers: [(NativePlayerError) -> Void] = []
  var cleanups = 0
  private var error: NativePlayerError?
  func source(_ url: URL) -> YlAppleSourceDescriptor {
    var source = YlAppleSourceDescriptor(uri: url.absoluteString, kind: .network, formatHint: .hls)
    source.intent = .live
    source.airPlay = true
    source.airPlayMedia = YlAirPlayPreparedMedia(url: url, cleanup: { self.cleanups += 1 }, observeFailure: { handler in
      self.handlers.append(handler)
      if let error = self.error { handler(error) }
    })
    return source
  }
  func fail() { error = Self.terminal; handlers.last?(Self.terminal) }
}
