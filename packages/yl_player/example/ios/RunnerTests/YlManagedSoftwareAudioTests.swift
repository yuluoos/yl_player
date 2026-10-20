@testable import yl_player_media_core
@testable import yl_player_apple
import AVFoundation
import Network
import XCTest
import YlFFmpegBridge

/// Real loopback HTTP requests, including a first 503 and exact Range responses.
private final class SoftwareAudioHTTP {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "yl.p03.audio.http")
  private let lock = NSLock()
  private var log = [String]()
  var requests: [String] { lock.withLock { log } }
  init(data: Data, retryFirst: Bool) throws {
    listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      connection.start(queue: queue)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { bytes, _, _, _ in
        guard let bytes, !bytes.isEmpty else { connection.cancel(); return }
        let request = String(decoding: bytes, as: UTF8.self).lowercased()
        let first = self.lock.withLock { () -> Bool in self.log.append(request); return self.log.count == 1 }
        if first && retryFirst {
          connection.send(content: Data("HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
          return
        }
        let range = request.components(separatedBy: "\r\n").first { $0.hasPrefix("range: bytes=") }?.components(separatedBy: "=").last
        let fields = range?.split(separator: "-", omittingEmptySubsequences: false)
        let start = fields?.first.flatMap { Int($0) } ?? 0
        let end = min(fields?.last.flatMap { Int($0) } ?? data.count - 1, data.count - 1)
        guard request.contains("x-p03: owned\r\n"), start >= 0, start <= end else { connection.cancel(); return }
        let body = data.subdata(in: start..<(end + 1))
        var header = "HTTP/1.1 \(range == nil ? "200 OK" : "206 Partial Content")\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
        if range != nil { header += "Content-Range: bytes \(start)-\(end)/\(data.count)\r\n" }
        connection.send(content: Data((header + "\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
      }
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success else { throw NSError(domain: "fixture", code: 1) }
  }
  var address: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/fixture.mkv")! }
  func close() { listener.cancel() }
}

final class YlManagedSoftwareAudioTests: XCTestCase {
  func testManagedRangeRetryAndActualOpusVorbisPCMOwnership() async throws {
    for (name, codec) in [("opus_switch", YlAudioCodec.opus), ("vorbis_switch", .vorbis)] {
      let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mkv"))
      let server = try SoftwareAudioHTTP(data: Data(contentsOf: fixture), retryFirst: true)
      defer { server.close() }
      let ledger = YlManagedBufferLedger(); let scope = try ledger.makeScope(maxBytes: nil)
      let source = YlAppleSourceDescriptor(uri: server.address.absoluteString, kind: .network, formatHint: .matroska,
        intent: .onDemand, headers: ["X-P03": "owned"], networkPolicy: .managed, bufferScope: scope)
      var retries = 0
      let prepared = try YlPreparedFallback(source: source, requireHardwareProbe: false,
        onRetry: { _, _, _ in retries += 1 })
      defer { prepared.discard() }
      let stream = try XCTUnwrap(prepared.audioStreams.first { YlAudioCodec(bridgeCodec: $0.codec) == codec })
      let converter = YlAppleCompressedAudioConverter(); converter.bufferScope = scope
      try converter.configure(stream: .init(codec: codec, sampleRate: Double(stream.sample_rate),
        channelCount: Int(stream.channel_count), magicCookie: try XCTUnwrap(prepared.audioCookies[stream.index]), generation: 1))
      let media = try prepared.takeMedia(); defer { media.close() }
      let context = try XCTUnwrap(media.context)
      var outputs = [YlScheduledAudioBuffer]()
      for _ in 0..<300 {
        var packet: YLFPacketRef?
        if ylf_read_packet(context, &packet) != 0 { break }
        defer { ylf_packet_release(&packet) }
        guard let p = packet, ylf_packet_stream_index(p) == stream.index else { continue }
        let count = ylf_packet_size(p), bytes = try XCTUnwrap(ylf_packet_data(p))
        var skip: UInt32 = 0, discard: UInt32 = 0
        XCTAssertEqual(ylf_packet_audio_trim(p, &skip, &discard), 0)
        let token = try scope.require(category: .compressedPackets, bytes: count)
        if let output = try converter.convert(packet: .init(reservation: token,
          data: Data(bytes: bytes, count: count), ptsUs: ylf_packet_pts_us(p), durationUs: ylf_packet_duration_us(p),
          generation: 1, skipSamples: skip, discardSamples: discard)) { outputs.append(output) }
        if outputs.count >= 12 { break }
      }
      XCTAssertEqual(outputs.count, 12); XCTAssertEqual(retries, 1)
      XCTAssertTrue(server.requests.contains { $0.contains("range: bytes=") })
      XCTAssertTrue(server.requests.allSatisfy { $0.contains("x-p03: owned") })
      for output in outputs {
        let pcm = try XCTUnwrap(output.payload as? AVAudioPCMBuffer)
        XCTAssertGreaterThan(pcm.frameLength, 0)
        XCTAssertEqual(output.byteCount, Int(pcm.frameLength * pcm.format.channelCount) * 4)
        XCTAssertEqual(output.reservation?.bytes, output.byteCount)
      }
      media.close(); prepared.discard()
      XCTAssertGreaterThan(ledger.snapshot.currentBytes, 0)
      outputs.removeAll()
      // Transport parser/delivery work retires on its serial queue after close.
      for _ in 0..<200 where ledger.snapshot.currentBytes != 0 {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      XCTAssertEqual(ledger.snapshot.currentBytes, 0, "\(ledger.snapshot.categories)")
    }
  }
  func testCancellationDuringManagedRetryReturnsAllOwnedBytes() throws {
    let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "vorbis_switch", withExtension: "mkv"))
    let server = try SoftwareAudioHTTP(data: Data(contentsOf: fixture), retryFirst: true); defer { server.close() }
    let ledger = YlManagedBufferLedger(); let scope = try ledger.makeScope(maxBytes: nil)
    let token = YlOpenCancellationToken()
    let source = YlAppleSourceDescriptor(uri: server.address.absoluteString, kind: .network, formatHint: .matroska,
      intent: .onDemand, headers: ["X-P03": "owned"], networkPolicy: .managed, bufferScope: scope)
    XCTAssertThrowsError(try YlPreparedFallback(source: source, requireHardwareProbe: false,
      cancellationToken: token, onRetry: { _, _, _ in token.cancel() })) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "network.cancelled")
    }
    XCTAssertEqual(server.requests.count, 1); XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }
}
