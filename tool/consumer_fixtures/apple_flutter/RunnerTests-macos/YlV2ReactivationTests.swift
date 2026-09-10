import Foundation
import Network
import XCTest
#if os(iOS)
import Flutter
@testable import yl_player_apple
#else
import FlutterMacOS
import CoreVideo
@testable import yl_player_apple
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
    let textures = ReactivationTextures()
    let backend = YlAvPlayerBackend(playerId: 91, textures: textures,
      configuration: configuration, emit: { events.append($0) })
    let slot = YlBackendSlot(initial: backend)
    defer { slot.dispose() }
    let source = YlAppleSourceDescriptor(uri: server.url.absoluteString, kind: .network, formatHint: .hls, credentials: ["Authorization": "Bearer rollback-test"], loadOptions: YlAppleLoadOptions(autoplay: false), loadRequestId: "1")
    func prepare() throws -> YlPreparedHlsAsset {
      try YlPreparedHlsAsset(originURL: server.url, headers: [:],
        credentials: ["Authorization": "Bearer rollback-test"],
        configuration: configuration.network, cancellationToken: YlOpenCancellationToken())
    }
    func requireVideo(_ description: String, afterPublication baseline: Int = 0) {
      let done = expectation(description: description)
      let deadline = Date().addingTimeInterval(8)
      var sawVideo = false
      func poll() {
        // Observe real production publication; reading AVPlayerItemVideoOutput
        // here would compete with displayLinkTick for its one-shot new frame.
        sawVideo = textures.videoPublicationCount > baseline
        if sawVideo || Date() >= deadline { done.fulfill() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() } }
      }
      poll()
      wait(for: [done], timeout: 9)
      XCTAssertTrue(sawVideo, description)
    }
    try backend.stagePreparedHls(source: source, prepared: prepare(), resume: false)
    try backend.activate()
    try backend.play()
    requireVideo("Initial authenticated HLS must render real video")
    try backend.pause()
    backend.emitState()
    let publicGeneration = try XCTUnwrap(events.last?["generation"] as? UInt64)
    let slotGeneration = slot.generation
    let requestsBeforeRollback = server.requests.count
    let publicationsBeforeRollback = textures.videoPublicationCount
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
    try backend.play()
    requireVideo("Rollback must restore authenticated HLS video", afterPublication: publicationsBeforeRollback)
    backend.emitState()
    XCTAssertEqual(events.last?["generation"] as? UInt64, publicGeneration)
    XCTAssertEqual(events.last?["loadRequestId"] as? String, "1")
    let restoredRequests = Array(server.requests.dropFirst(requestsBeforeRollback))
    for path in ["/master.m3u8", "/media.m3u8", "/key.bin", "/segment0.ts"] {
      let requests = restoredRequests.filter { $0.path == path }
      XCTAssertFalse(requests.isEmpty, "Restoration must fetch \(path)")
      XCTAssertTrue(requests.allSatisfy { $0.authorized }, "Restoration must authenticate \(path)")
    }
  }


  #endif


}

private final class ReactivationTextures: NSObject, FlutterTextureRegistry {
  private var texture: FlutterTexture?
  private(set) var videoPublicationCount = 0
  func register(_ texture: FlutterTexture) -> Int64 { self.texture = texture; return 92 }
  func unregisterTexture(_ textureId: Int64) { texture = nil }
  func textureFrameAvailable(_ textureId: Int64) {
    guard let buffer = texture?.copyPixelBuffer()?.takeRetainedValue(),
      CVPixelBufferGetWidth(buffer) > 0, CVPixelBufferGetHeight(buffer) > 0 else { return }
    videoPublicationCount += 1
  }
}

final class ReactivationMediaServer {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "yl.test.reactivation.http")
  let url: URL
  init(data: Data, supportsRanges: Bool = true, requiredHeaders: [String: String] = [:],
       onRequest: @escaping (String) -> Void = { _ in }) throws {
    let listener = try NWListener(using: .tcp, on: .any)
    self.listener = listener
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
    listener.newConnectionHandler = { connection in
      connection.start(queue: DispatchQueue.global())
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { bytes, _, _, _ in
        // A cancelled idle connection reports EOF, not an HTTP request.
        guard let bytes, !bytes.isEmpty else { connection.cancel(); return }
        let request = String(decoding: bytes, as: UTF8.self).lowercased()
        onRequest(request)
        if !requiredHeaders.allSatisfy({ name, value in
          request.contains("\(name.lowercased()): \(value.lowercased())\r\n")
        }) {
          connection.send(content: Data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
            completion: .contentProcessed { _ in connection.cancel() })
          return
        }
        let range = supportsRanges
          ? request.components(separatedBy: "\r\n").first { $0.hasPrefix("range: bytes=") }?.components(separatedBy: "=").last
          : nil
        let bounds = range?.split(separator: "-", omittingEmptySubsequences: false)
        let start = bounds?.first.flatMap { Int($0) } ?? 0
        let end = min(bounds?.last.flatMap { Int($0) } ?? data.count - 1, data.count - 1)
        guard start >= 0, start <= end else { connection.cancel(); return }
        let body = data.subdata(in: start..<(end + 1))
        var headers = "HTTP/1.1 \(range == nil ? "200 OK" : "206 Partial Content")\r\nContent-Type: video/x-matroska\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if supportsRanges { headers += "Accept-Ranges: bytes\r\n" }
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
  func play() throws {}
  func pause() throws {}
  func seek(toMs: Int64, cancellationToken: YlOpenCancellationToken?) throws {}
  func seekToLiveEdge() throws {}
  func setPlaybackSpeed(_ speed: Float) throws {}
  func setVolume(_ volume: Float) throws {}
  func selectAudioTrack(_ trackId: String, cancellationToken: YlOpenCancellationToken?) throws {}
  func setVideoConstraints(_ constraints: YlAppleVideoConstraints) throws {}
  func emitState() {}
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? { nil }
  func dispose() { disposed = true }
}

final class RollbackHlsServer {
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
