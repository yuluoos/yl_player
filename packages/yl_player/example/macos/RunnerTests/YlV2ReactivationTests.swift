import Foundation
import Network
import XCTest
#if os(iOS)
import Flutter
@testable import yl_player_ios
#else
import FlutterMacOS
import CoreVideo
@testable import yl_player_macos
#endif

final class YlV2ReactivationTests: XCTestCase {
  #if os(macOS)
  func testCredentialsOnlyHlsRestoresAuthenticatedPlaybackAfterCandidateActivationFailure() throws {
    let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("assets/test_media")
    let server = try RollbackHlsServer(
      key: Data(contentsOf: assets.appendingPathComponent("hls_key.bin")),
      segment: Data(contentsOf: assets.appendingPathComponent("hls_encrypted_segment0.ts")))
    defer { server.close() }
    let configuration = PlayerConfiguration(map: ["audioPolicy": "appManaged"])
    var events = [[String: Any?]]()
    let backend = YlAvPlayerBackend(playerId: 91, textures: ReactivationTextures(),
      configuration: configuration, emit: { events.append($0) })
    let slot = YlBackendSlot(initial: backend)
    defer { slot.dispose() }
    let source: [String: Any?] = ["uri": server.url.absoluteString, "kind": "network",
      "formatHint": "hls", "credentials": ["Authorization": "Bearer rollback-test"],
      "loadToken": 1, "loadOptions": ["autoplay": false]]
    func prepare() throws -> YlPreparedHlsAsset {
      try YlPreparedHlsAsset(originURL: server.url, headers: [:],
        credentials: ["Authorization": "Bearer rollback-test"],
        configuration: configuration.network, cancellationToken: YlOpenCancellationToken())
    }
    func requireVideo(_ description: String) {
      let done = expectation(description: description)
      let deadline = Date().addingTimeInterval(8)
      var sawVideo = false
      func poll() {
        if let buffer = backend.copyPixelBuffer()?.takeRetainedValue() {
          sawVideo = CVPixelBufferGetWidth(buffer) > 0
        }
        if sawVideo || Date() >= deadline { done.fulfill() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() } }
      }
      poll()
      wait(for: [done], timeout: 9)
      XCTAssertTrue(sawVideo, description)
    }
    try backend.stagePreparedHls(source: source, prepared: prepare(), resume: false)
    try backend.activate()
    try backend.command(name: "play", arguments: [:])
    requireVideo("Initial authenticated HLS must render real video")
    try backend.command(name: "pause", arguments: [:])
    backend.emitState()
    let publicGeneration = try XCTUnwrap(events.last?["generation"] as? UInt64)
    let slotGeneration = slot.generation
    let requestsBeforeRollback = server.requests.count
    let candidate = FailingActivationBackend {
      XCTAssertFalse(backend.isActive, "Candidate activation must follow old-backend quiescence")
    }
    XCTAssertThrowsError(try slot.replace { candidate }) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "test.activation_failed")
    }
    XCTAssertTrue(candidate.disposed)
    XCTAssertTrue(slot.current === backend)
    XCTAssertEqual(slot.generation, slotGeneration)
    // Use the production rollback decision. A false decision leaves the bare
    // AVURLAsset activated by the slot; the authentication/video checks fail.
    if slot.takeRollbackRequiresExternalActivation() {
      try backend.stagePreparedHls(source: source, prepared: prepare(), resume: true)
      try backend.activate()
    }
    try backend.command(name: "play", arguments: [:])
    requireVideo("Rollback must restore authenticated HLS video")
    backend.emitState()
    XCTAssertEqual(events.last?["generation"] as? UInt64, publicGeneration)
    XCTAssertEqual(events.last?["loadToken"] as? Int, 1)
    let restoredRequests = Array(server.requests.dropFirst(requestsBeforeRollback))
    for path in ["/master.m3u8", "/media.m3u8", "/key.bin", "/segment0.ts"] {
      let requests = restoredRequests.filter { $0.path == path }
      XCTAssertFalse(requests.isEmpty, "Restoration must fetch \(path)")
      XCTAssertTrue(requests.allSatisfy { $0.authorized }, "Restoration must authenticate \(path)")
    }
  }

  func testActiveFallbackReplacementUsesDefaultAudioBackedClock() throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("assets/test_media/network_seek_h264_aac.mkv")
    let server = try ReactivationMediaServer(data: Data(contentsOf: fixture))
    defer { server.close() }
    var events = [[String: Any?]]()
    let owner = YlMacosPlayer(playerId: 91, textures: ReactivationTextures(),
      configuration: .init(map: ["audioPolicy": "appManaged"]), emit: { events.append($0) })
    defer { owner.dispose() }
    let texture = owner.textureId
    func open(_ token: Int) {
      let done = expectation(description: "active replacement committed")
      owner.beginOpen(["uri": server.url.absoluteString, "kind": "network",
        "formatHint": "matroska", "loadToken": token,
        "loadOptions": ["autoplay": true]], willCommit: { _ in },
        didCommit: {}, didRollback: {}, completion: { result in
          if case .failure(let error) = result { XCTFail("Load failed: \(error.code)") }
          done.fulfill()
        })
      wait(for: [done], timeout: 10)
    }
    open(1)
    XCTAssertTrue(owner.isActive)
    let first = events.last?["generation"] as? UInt64
    let started = expectation(description: "real fallback audio starts")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { started.fulfill() }
    wait(for: [started], timeout: 2)
    open(2)
    owner.emitState()
    XCTAssertTrue(owner.isActive)
    XCTAssertEqual(owner.textureId, texture)
    XCTAssertNotEqual(events.last?["generation"] as? UInt64, first)
    XCTAssertEqual(events.last?["loadToken"] as? Int, 2)
    XCTAssertEqual((events.last?["state"] as? [String: Any?])?["engine"] as? String, "nativeFallback")
  }
  #endif

  func testFailedReplacementThenReactivationPreservesAcceptedSessionControls() throws {
    #if os(iOS)
    let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mkv"))
    #else
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("assets/test_media/network_seek_h264_aac.mkv")
    #endif
    let server = try ReactivationMediaServer(data: Data(contentsOf: fixture))
    defer { server.close() }
    var events = [[String: Any?]]()
    #if os(iOS)
    let owner = YlIosPlayer(playerId: 91, textures: ReactivationTextures(), configuration: .init(map: ["audioPolicy": "appManaged"]), emit: { events.append($0) })
    #else
    let owner = YlMacosPlayer(playerId: 91, textures: ReactivationTextures(), configuration: .init(map: ["audioPolicy": "appManaged"]), emit: { events.append($0) })
    #endif
    defer { owner.dispose() }
    func open(_ source: [String: Any?]) -> Result<Void, NativePlayerError>? {
      let done = expectation(description: "open completed")
      var outcome: Result<Void, NativePlayerError>?
      #if os(iOS)
      owner.beginOpen(source, didCommit: {}, completion: { outcome = $0; done.fulfill() })
      #else
      owner.beginOpen(source, willCommit: { _ in }, didCommit: {}, didRollback: {}, completion: { outcome = $0; done.fulfill() })
      #endif
      wait(for: [done], timeout: 10)
      return outcome
    }
    func command(_ name: String, _ args: [String: Any?] = [:]) {
      let done = expectation(description: name)
      owner.beginCommand(name: name, arguments: args) { result in
        if case .failure(let error) = result { XCTFail("Command rejected: \(error.code)") }
        done.fulfill()
      }
      wait(for: [done], timeout: 5)
    }
    let source: [String: Any?] = ["uri": server.url.absoluteString, "kind": "network", "formatHint": "matroska", "loadToken": 1, "loadOptions": ["startPositionMs": 500, "autoplay": true, "videoConstraints": ["maxWidth": 640]]]
    if case .failure(let error)? = open(source) {
      #if os(iOS)
      if error.code == "decoder.video_hardware_unavailable" { throw XCTSkip("Simulator VideoToolbox unavailable; no hardware playback claim") }
      #endif
      return XCTFail("Initial load failed: \(error.code)")
    }
    let initiallyPlaying = expectation(description: "initial start position survives media preroll")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { initiallyPlaying.fulfill() }
    wait(for: [initiallyPlaying], timeout: 2)
    command("pause")
    owner.emitState()
    let initialPosition = (events.last?["state"] as? [String: Any?])?["positionMs"] as? Int64 ?? 0
    XCTAssertGreaterThanOrEqual(initialPosition, 450, "Initial Load start position must suppress preroll")
    command("setQualityConstraint", ["constraint": ["maxWidth": 800]])
    command("setVolume", ["volume": 0.2])
    command("setPlaybackSpeed", ["speed": 2.0])
    command("seekTo", ["positionMs": 700])
    owner.emitState()
    let initialState = try XCTUnwrap(events.last?["state"] as? [String: Any?])
    XCTAssertGreaterThanOrEqual((initialState["positionMs"] as? Int64) ?? 0, 650, "Accepted seek must establish the resume position")
    let tracks = initialState["audioTracks"] as? [[String: Any?]] ?? []
    let trackId = tracks.last?["id"] as? String
    if let trackId { command("selectAudioTrack", ["trackId": trackId]) }
    let generation = events.last?["generation"] as? UInt64
    if case .success? = open(["uri": "", "loadToken": 2, "loadOptions": ["startPositionMs": 9000, "autoplay": true, "videoConstraints": ["maxWidth": 1]]]) {
      XCTFail("Invalid candidate committed")
    }
    XCTAssertEqual(owner.lastQualityConstraint["maxWidth"] as? Int, 800)
    owner.emitState()
    let beforeDeactivation = try XCTUnwrap(events.last?["state"] as? [String: Any?])
    XCTAssertGreaterThanOrEqual((beforeDeactivation["positionMs"] as? Int64) ?? 0, 650, "Failed candidate must preserve the resume position")
    owner.deactivate()
    let resumed = expectation(description: "same session reactivated")
    #if os(iOS)
    owner.beginActivation(forcePlay: false, didCommit: {}, completion: { result in
      if case .failure(let error) = result { XCTFail("Reactivation rejected: \(error.code)") }
      resumed.fulfill()
    })
    #else
    owner.beginActivation(forcePlay: false, willCommit: { _ in }, didCommit: {}, didRollback: {}, completion: { result in
      if case .failure(let error) = result { XCTFail("Reactivation rejected: \(error.code)") }
      resumed.fulfill()
    })
    #endif
    wait(for: [resumed], timeout: 10)
    owner.emitState()
    let state = try XCTUnwrap(events.last?["state"] as? [String: Any?])
    XCTAssertEqual(events.last?["generation"] as? UInt64, generation)
    XCTAssertEqual(owner.lastQualityConstraint["maxWidth"] as? Int, 800)
    XCTAssertTrue(["paused", "ready"].contains(state["status"] as? String ?? ""))
    let stayedPaused = expectation(description: "restoration does not replay initial autoplay")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { stayedPaused.fulfill() }
    wait(for: [stayedPaused], timeout: 2)
    owner.emitState()
    let pausedPosition = (events.last?["state"] as? [String: Any?])?["positionMs"] as? Int64 ?? 0
    XCTAssertEqual(pausedPosition, (state["positionMs"] as? Int64) ?? 0, accuracy: 50)
    XCTAssertGreaterThanOrEqual((state["positionMs"] as? Int64) ?? 0, 650)
    let selected = (state["audioTracks"] as? [[String: Any?]])?.first { $0["isSelected"] as? Bool == true }
    XCTAssertEqual(selected?["id"] as? String, trackId)
    command("play")
    let started = expectation(description: "restored output is advancing")
    var playbackStart: Int64?
    var minimumResumedPosition = pausedPosition
    let deadline = Date().addingTimeInterval(3)
    func observeStart() {
      owner.emitState()
      let position = (events.last?["state"] as? [String: Any?])?["positionMs"] as? Int64 ?? 0
      minimumResumedPosition = min(minimumResumedPosition, position)
      if position > pausedPosition + 100 || Date() >= deadline {
        playbackStart = position
        started.fulfill()
      } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { observeStart() }
      }
    }
    observeStart()
    wait(for: [started], timeout: 4)
    let baseline = try XCTUnwrap(playbackStart)
    XCTAssertGreaterThanOrEqual(minimumResumedPosition, 650, "Audio preroll must not rewind the accepted resume target")
    XCTAssertGreaterThan(baseline, pausedPosition + 100)
    let advanced = expectation(description: "restored speed advances timeline")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { advanced.fulfill() }
    wait(for: [advanced], timeout: 2)
    owner.emitState()
    let later = (events.last?["state"] as? [String: Any?])?["positionMs"] as? Int64 ?? 0
    XCTAssertGreaterThan(later - baseline, 280)

  }
}

private final class ReactivationTextures: NSObject, FlutterTextureRegistry {
  func register(_ texture: FlutterTexture) -> Int64 { 92 }
  func unregisterTexture(_ textureId: Int64) {}
  func textureFrameAvailable(_ textureId: Int64) {}
}

private final class ReactivationMediaServer {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "yl.test.reactivation.http")
  let url: URL
  init(data: Data) throws {
    let listener = try NWListener(using: .tcp, on: .any)
    self.listener = listener
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
    listener.newConnectionHandler = { connection in
      connection.start(queue: DispatchQueue.global())
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { bytes, _, _, _ in
        let request = String(decoding: bytes ?? Data(), as: UTF8.self).lowercased()
        let range = request.components(separatedBy: "\r\n").first { $0.hasPrefix("range: bytes=") }?.components(separatedBy: "=").last
        let bounds = range?.split(separator: "-", omittingEmptySubsequences: false)
        let start = bounds?.first.flatMap { Int($0) } ?? 0
        let end = min(bounds?.last.flatMap { Int($0) } ?? data.count - 1, data.count - 1)
        guard start >= 0, start <= end else { connection.cancel(); return }
        let body = data.subdata(in: start..<(end + 1))
        var headers = "HTTP/1.1 \(range == nil ? "200 OK" : "206 Partial Content")\r\nContent-Type: video/x-matroska\r\nAccept-Ranges: bytes\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if range != nil { headers += "Content-Range: bytes \(start)-\(end)/\(data.count)\r\n" }
        connection.send(content: Data((headers + "\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
      }
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
      listener.cancel()
      throw NSError(domain: "TestServer", code: 1)
    }
    url = URL(string: "http://127.0.0.1:\(port.rawValue)/fixture.mkv")!
  }
  func close() { listener.cancel() }
}

#if os(macOS)
private final class FailingActivationBackend: YlPlaybackBackend {
  let beforeFailure: () -> Void
  var disposed = false
  var isActive: Bool { false }
  init(beforeFailure: @escaping () -> Void) { self.beforeFailure = beforeFailure }
  func activate() throws {
    beforeFailure()
    throw NativePlayerError(category: "resource", code: "test.activation_failed", message: "Candidate activation failed.")
  }
  func stop() {}
  func deactivate() {}
  func command(name: String, arguments: [String: Any?]) throws {}
  func emitState() {}
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? { nil }
  func dispose() { disposed = true }
}

private final class RollbackHlsServer {
  struct Request { let path: String; let authorized: Bool }
  private final class Log {
    let lock = NSLock()
    var values = [Request]()
  }
  private let listener: NWListener
  private let log = Log()
  var requests: [Request] { log.lock.withLock { log.values } }
  let url: URL
  init(key: Data, segment: Data) throws {
    listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
    let log = self.log
    listener.newConnectionHandler = { connection in
      connection.start(queue: DispatchQueue.global())
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { bytes, _, _, _ in
        let text = String(decoding: bytes ?? Data(), as: UTF8.self)
        let path = text.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let authorized = text.lowercased().contains("authorization: bearer rollback-test")
        log.lock.withLock { log.values.append(Request(path: path, authorized: authorized)) }
        let body: Data
        let type: String
        switch path {
        case "/master.m3u8":
          body = Data(("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-STREAM-INF:BANDWIDTH=350000,CODECS=\"avc1.42c00d,mp4a.40.2\",RESOLUTION=320x180\nmedia.m3u8\n").utf8)
          type = "application/vnd.apple.mpegurl"
        case "/media.m3u8":
          body = Data(("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x00000000000000000000000000000000\n#EXTINF:1.968000,\nsegment0.ts\n#EXT-X-ENDLIST\n").utf8)
          type = "application/vnd.apple.mpegurl"
        case "/key.bin": body = key; type = "application/octet-stream"
        case "/segment0.ts": body = segment; type = "video/mp2t"
        default: connection.cancel(); return
        }
        let responseBody = authorized ? body : Data()
        let header = "HTTP/1.1 \(authorized ? "200 OK" : "401 Unauthorized")\r\nContent-Type: \(type)\r\nContent-Length: \(responseBody.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + responseBody,
          completion: .contentProcessed { _ in connection.cancel() })
      }
    }
    listener.start(queue: DispatchQueue(label: "yl.test.rollback.hls"))
    guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
      listener.cancel()
      throw NSError(domain: "TestServer", code: 1)
    }
    url = URL(string: "http://127.0.0.1:\(port.rawValue)/master.m3u8")!
  }
  func close() { listener.cancel() }
}
#endif
