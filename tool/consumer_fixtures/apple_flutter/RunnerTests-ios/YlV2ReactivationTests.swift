import Foundation
import AVFoundation
import CoreVideo
import Network
import XCTest
#if os(iOS)
import Flutter
@testable import yl_player_apple
#else
import FlutterMacOS
@testable import yl_player_apple
#endif

final class YlV2ReactivationTests: XCTestCase {
  func testCredentialsOnlyHlsRestoresAuthenticatedPlaybackAfterCandidateActivationFailure() throws {
    let bundle = Bundle(for: Self.self)
    let server = try RollbackHlsServer(
      key: Data(contentsOf: XCTUnwrap(bundle.url(forResource: "hls_key", withExtension: "bin"))),
      segment: Data(contentsOf: XCTUnwrap(bundle.url(forResource: "hls_encrypted_segment0", withExtension: "ts"))))
    defer { server.close() }
    let configuration = PlayerConfiguration(map: ["audioPolicy": "appManaged"])
    var events = [[String: Any?]]()
    let avPlayer = AVPlayer()
    let backend = YlAvPlayerBackend(playerId: 91, textures: ReactivationTextures(),
      configuration: configuration, player: avPlayer, emit: { events.append($0) })
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
        if (sawVideo && avPlayer.rate > 0) || Date() >= deadline { done.fulfill() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() } }
      }
      poll()
      wait(for: [done], timeout: 9)
      XCTAssertTrue(sawVideo, description)
    }
    let prepared = try prepare()
    try backend.stagePreparedHls(source: source, prepared: prepared, resume: false)
    try backend.activate()
    try backend.command(name: "setPlaybackSpeed", arguments: ["speed": 1.5])
    try backend.command(name: "setVolume", arguments: ["volume": 0.2])
    try backend.command(name: "play", arguments: [:])
    requireVideo("Initial authenticated HLS must render real video")
    backend.emitState()
    let publicGeneration = try XCTUnwrap(events.last?["generation"] as? UInt64)
    let slotGeneration = slot.generation
    let candidate = FailingActivationBackend {
      XCTAssertFalse(backend.isActive, "Candidate activation must follow old-backend quiescence")
    }
    XCTAssertThrowsError(try slot.replace { candidate }) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "test.activation_failed")
    }
    XCTAssertTrue(candidate.disposed)
    XCTAssertTrue(slot.current === backend)
    XCTAssertEqual(slot.generation, slotGeneration)
    // iOS slot performs its actual synchronous rollback activation.
    // Do not manually stage a loader or issue Play to repair it in the test.
    requireVideo("Rollback must restore authenticated HLS video")
    backend.emitState()
    XCTAssertEqual(events.last?["generation"] as? UInt64, publicGeneration)
    XCTAssertEqual(events.last?["loadToken"] as? Int, 1)
    XCTAssertEqual(avPlayer.rate, 1.5, accuracy: 0.01, "Rollback must preserve playing intent and speed")
    XCTAssertEqual(avPlayer.volume, 0.2, accuracy: 0.01)
    let restoredRequests = server.requests
    for path in ["/master.m3u8", "/media.m3u8", "/key.bin", "/segment0.ts"] {
      let requests = restoredRequests.filter { $0.path == path }
      XCTAssertFalse(requests.isEmpty, "Restoration must fetch \(path)")
      XCTAssertTrue(requests.allSatisfy { $0.authorized }, "Restoration must authenticate \(path)")
    }
    // Paused intent also survives a second failure without a fabricated Play.
    try backend.command(name: "pause", arguments: [:])
    XCTAssertThrowsError(try slot.replace { FailingActivationBackend {} })
    XCTAssertEqual(avPlayer.rate, 0)
    try prepared.loader.preflight(cancellationToken: YlOpenCancellationToken())
    backend.emitState()
    XCTAssertEqual(events.last?["generation"] as? UInt64, publicGeneration)
  }

  func testHeldHlsResourcesReleaseOnCommitStopDisposeAndDeactivation() throws {
    let bundle = Bundle(for: Self.self)
    let server = try RollbackHlsServer(
      key: Data(contentsOf: XCTUnwrap(bundle.url(forResource: "hls_key", withExtension: "bin"))),
      segment: Data(contentsOf: XCTUnwrap(bundle.url(forResource: "hls_encrypted_segment0", withExtension: "ts"))))
    defer { server.close() }
    for boundary in ["commit", "stop", "dispose", "deactivate", "failedRollback"] {
      var rejectActivation = false
      let configuration = PlayerConfiguration(map: boundary == "failedRollback" ? [:] : ["audioPolicy": "appManaged"])
      let backend = YlAvPlayerBackend(playerId: 91, textures: ReactivationTextures(),
        configuration: configuration, activateAudioSession: {
          if rejectActivation { throw NSError(domain: "TestActivation", code: 1) }
        }, emit: { _ in })
      let slot = YlBackendSlot(initial: backend)
      defer { backend.dispose(); slot.dispose() }
      let prepared = try YlPreparedHlsAsset(originURL: server.url, headers: [:],
        credentials: ["Authorization": "Bearer rollback-test"],
        configuration: configuration.network, cancellationToken: YlOpenCancellationToken())
      try backend.stagePreparedHls(source: ["uri": server.url.absoluteString, "kind": "network",
        "formatHint": "hls", "credentials": ["Authorization": "Bearer rollback-test"]],
        prepared: prepared, resume: false)
      try backend.activate()
      if boundary == "commit" {
        _ = try slot.replace { SuccessfulActivationBackend() }
      } else if boundary == "failedRollback" {
        rejectActivation = true
        XCTAssertThrowsError(try slot.replace { FailingActivationBackend {} })
        XCTAssertFalse(backend.isActive)
      } else {
        backend.quiesceForReplacement()
        switch boundary {
        case "stop": slot.stop()
        case "dispose": slot.dispose()
        default: backend.deactivate()
        }
      }
      XCTAssertThrowsError(try prepared.loader.preflight(cancellationToken: YlOpenCancellationToken()), boundary) { error in
        XCTAssertEqual((error as? NativePlayerError)?.code, "network.cancelled", boundary)
      }
    }
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


private final class SuccessfulActivationBackend: YlPlaybackBackend {
  private(set) var isActive = false
  func activate() throws { isActive = true }
  func stop() { isActive = false }
  func deactivate() { isActive = false }
  func command(name: String, arguments: [String: Any?]) throws {}
  func emitState() {}
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? { nil }
  func dispose() { isActive = false }
}
