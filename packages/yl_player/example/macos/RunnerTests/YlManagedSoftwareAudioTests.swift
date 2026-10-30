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
  func testDisposeReleasesConverterPendingPacketsWhileRendererIsRetained() throws {
    for failsConversion in [false, true] {
      let ledger = YlManagedBufferLedger()
      let scope = try ledger.makeScope(maxBytes: nil)
      let converter = PendingPacketConverter(failsConversion: failsConversion)
      let renderer = YlAudioRenderer(bufferScope: scope, converter: converter, output: AdmissionOutput())
      try renderer.configure(stream: .init(codec: .aac, sampleRate: 48_000,
        channelCount: 2, magicCookie: Data(), generation: 1))
      func enqueue() throws -> YlAudioEnqueueResult {
        let token = try scope.require(category: .compressedPackets, bytes: 64)
        return try renderer.enqueue(packet: .init(reservation: token, data: Data(repeating: 1, count: 64),
          ptsUs: 0, durationUs: 20_000, generation: 1))
      }
      if failsConversion { XCTAssertThrowsError(try enqueue()) }
      else { XCTAssertEqual(try enqueue(), .buffered) }
      XCTAssertEqual(ledger.snapshot.currentBytes, 64)
      renderer.dispose()
      withExtendedLifetime((renderer, converter)) {
        XCTAssertEqual(ledger.snapshot.currentBytes, 0,
          "Disposal must release queued compressed input without waiting for renderer deinit")
      }
      renderer.dispose()
      XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    }
  }

  private final class PendingPacketConverter: YlAudioPacketConverting {
    let failsConversion: Bool
    private var pending: YlCompressedAudioPacket?
    init(failsConversion: Bool) { self.failsConversion = failsConversion }
    func configure(stream: YlAudioStreamConfiguration) throws {}
    func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate {
      .init(durationUs: 20_000, byteCount: 128)
    }
    func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer? {
      pending = packet
      if failsConversion { throw YlManagedBufferLedger.unsupported() }
      return nil
    }
    func reset() { pending = nil }
  }

  func testCoreAudioMP3LowRateUses576SamplePackets() throws {
    // Eight real MPEG-2 Layer III frames, sine 440Hz / 16kHz / 32kbps,
    // generated with libmp3lame, without ID3/Xing. No device/output mock decoder.
    let packets = [
      "//NIxAAceI5sFVgwACVa9U6p1TqnVOqdd7E2vrCImFyE6GjgE5tic4m0poEYAFmC8CgjEHIhyWEyYDAYDCyaYOAgCAIOicH+UdOdPnOX85y/u6fdlATB8+sPggGJQBg++TBA5l393Lg+D4Ph8EAQBAEAGD4Pg+HwQBAEHJE4PiAJIIEAaBBgWB2+f5gyFQEB",
      "//NIxBEgofZsLZ2gAJ0MgD6DpiMT5rslRg0VRsQephGLxwyMIGLggaAeBhhYGKYgoLJwDJYgGgxdDZgtGC0IUj/iURBUcoXMLm/8mRzRzSaIsRb/8mSKkBMiLEWMf/8ul0yLxeRLpdS///LxeRLpdBoKgqz/5YKhot////VaqqAAAJIIoQ/n//QM6UygtvDA",
      "//NIxBEZmHYmN95AADwFDAlBkMIEBYwggzTFuO9OXQwY/ZT/DK7LiMdYWsxNCRzADD9MHICMwDgAU7lYoegELKGttzM5u/Yv9b/+8ndXr/3l7+TW7s+5u39lxD7qj+7u/T1V///UqUFMJBjIBszRHM3bjQqswGUEcMC8CLTB0xlQynT+uNZLISjBhAeEwNUB",
      "//NIxC0j47oEAN/EcMDCjA0cwQ8E3MDvASDAUABUwB8AADAA1M5vJJKabf611aGaFw+PQXv/XPQJvU1Hq1R6tfTfT49Xq1cmTFJ0bf1aFybY3rq1fg9dqkoNB6PZ4LJunvRtq/67Y/rr8NOoxW929YAAEfv/5K1hC6Y8ACigAuYAYAiGAdgP5gOQG4YGuDYm",
      "//NIxCAhA74N6P9EqA7QmUZLXeNGnxDNhhPoRqasrCcHYUZpn0ZSheYXAMEA2gMV2xB/I3hf/3rrq1MmSor/+Wh9sbfbHrrrt/V6vXXNrjen+uTPvn2q1dXrk+famumCz59vvRqt/6ev11+DlrU6dhWgAAwGZ/Lv9oWMFgAwuAACB4aFUMJ8yGAgz5CE40E4",
      "//NIxB8fg74V9O/KiMuzBfDYyAKowosDxMC5BQTARg74wAkFMFAEsdAFCAABY09cMAgaO71113z647010xlG3z/bev++/rq9frkz/f/zNHZM21WjdH9/p6PXTdrZM/9GjdP9fjvX/EJW/enqR///1XaQkmDAGPKGSUmfiGAbAPpgN4IEYI0GImM2vu5m3ggG",
      "//NIxCQYaHYYCNf4ZmCCgYxkIsnL/8Z0WRmgPmGQAGAFXTq0desGtt7N1R396bk3IU9PR7ifVq09VqdGhdmd3JvbtVf+3/d+f3dK///lI19LhA4QgcCQzMGhgMQytMhFUNL/ZMYOmLTM0RScwawGsA347gPP/EDUiVAz8EADiGBYEBv4pQZsi5cT+vU9Wrfb",
      "//NIxEUaGN4UAO/qgD/9oln0XVPZtT7id9Ov/OFbN6F2bN9b2rcG13eq3/f+5H09FcAEC/n/2gbGnYnqHAUaGZjQAGYQya4IB61fmR4DiZpeoJOYPoBpGTB7GMdsmCx7ggMB0CVUGxwBK6e8b2q13JWz9iv1PZs/q16f9itPX7ehdq7EX+qlf9/579PUoAAA"
    ]
    let converter = YlAppleCompressedAudioConverter()
    try converter.configure(stream: .init(codec: .mp3, sampleRate: 16_000,
      channelCount: 1, magicCookie: Data(), generation: 1))
    var outputs = 0
    for (index, encoded) in packets.enumerated() {
      let packet = YlCompressedAudioPacket(data: try XCTUnwrap(Data(base64Encoded: encoded)),
        ptsUs: Int64(index) * 36_000, durationUs: Int64.max, generation: 1)
      let estimate = converter.estimateOutput(for: packet)
      XCTAssertEqual(estimate.durationUs, 36_000, "576 samples must fit a 40ms window")
      if let output = try converter.convert(packet: packet) {
        let pcm = try XCTUnwrap(output.payload as? AVAudioPCMBuffer)
        // CoreAudio can trim decoder priming from the first PCM block (47
        // samples on this host). Later complete packets must remain 576 frames.
        XCTAssertGreaterThan(pcm.frameLength, 0)
        XCTAssertLessThanOrEqual(pcm.frameLength, 576)
        if outputs > 0 { XCTAssertEqual(pcm.frameLength, 576) }
        XCTAssertEqual(output.durationUs, Int64(pcm.frameLength) * 1_000_000 / 16_000)
        XCTAssertLessThanOrEqual(Int(pcm.frameCapacity) * 4, estimate.byteCount)
        outputs += 1
      }
    }
    XCTAssertGreaterThan(outputs, 0)
    let output = AdmissionOutput()
    let renderer = YlAudioRenderer(maxScheduledDurationUs: 40_000, output: output)
    defer { renderer.dispose() }
    try renderer.configure(stream: .init(codec: .mp3, sampleRate: 16_000,
      channelCount: 1, magicCookie: Data(), generation: 1))
    var completed = 0
    for (index, encoded) in packets.enumerated() {
      let result = try renderer.enqueue(packet: .init(data: try XCTUnwrap(Data(base64Encoded: encoded)),
        ptsUs: Int64(index) * 36_000, durationUs: Int64.max, generation: 1))
      XCTAssertTrue(result == .scheduled || result == .buffered)
      while completed < output.completions.count { output.completions[completed](); completed += 1 }
    }
    XCTAssertGreaterThan(completed, 0, "A 40ms window must make actual progress for a 36ms MP3 frame")
  }

  func testCoreAudioEstimatesStayBoundedAcrossUntrustedDurations() throws {
    for (codec, channels, cookie) in [(YlAudioCodec.aac, 2, Data([0x11, 0x90])),
                                     (.aac, 6, Data([0x11, 0xb0])), (.mp3, 2, Data())] {
      let converter = YlAppleCompressedAudioConverter()
      try converter.configure(stream: .init(codec: codec, sampleRate: 48_000,
        channelCount: channels, magicCookie: cookie, generation: 1))
      let packet = YlCompressedAudioPacket(data: Data([1]), ptsUs: 0, durationUs: 1_000_000_000, generation: 1)
      let oversized = converter.estimateOutput(for: packet)
      XCTAssertLessThanOrEqual(oversized.durationUs, 24_000)
      XCTAssertLessThanOrEqual(oversized.byteCount, 1152 * 2 * channels * 4)
      // Keep RED safe: do not exercise integer extrema or allocate PCM until
      // the bounded estimate invariant holds. The unfixed six-channel path can overflow.
      guard oversized.durationUs <= 24_000, oversized.byteCount <= 1152 * 2 * channels * 4 else { continue }
      for duration in [Int64.min, -1, 0, 1, 21_000, Int64.max] {
        let estimate = converter.estimateOutput(for: .init(data: packet.data, ptsUs: 0,
          durationUs: duration, generation: 1))
        XCTAssertEqual(estimate.durationUs, oversized.durationUs)
        XCTAssertEqual(estimate.byteCount, oversized.byteCount)
      }
    }
  }

  func testRealAACAndMP3PCMAllocationDoesNotFollowContainerDuration() throws {
    for (name, ext, hint, codec) in [("h264_aac", "mkv", YlSourceFormat.matroska, YlAudioCodec.aac),
                                    ("h264_mp3", "flv", .flv, .mp3)] {
      let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
      let prepared = try YlPreparedFallback(source: .init(uri: fixture.absoluteString, kind: .file, formatHint: hint), requireHardwareProbe: false)
      defer { prepared.discard() }
      let stream = try XCTUnwrap(prepared.audioStreams.first)
      let media = try prepared.takeMedia(); defer { media.close() }
      let context = try XCTUnwrap(media.context)
      var packets = [(Data, Int64, Int64)]()
      for _ in 0..<100 {
        var packet: YLFPacketRef?
        if ylf_read_packet(context, &packet) != 0 { break }
        defer { ylf_packet_release(&packet) }
        guard let p = packet, ylf_packet_stream_index(p) == stream.index else { continue }
        packets.append((Data(bytes: try XCTUnwrap(ylf_packet_data(p)), count: ylf_packet_size(p)), ylf_packet_pts_us(p), ylf_packet_duration_us(p)))
        if packets.count == 8 { break }
      }
      XCTAssertEqual(packets.count, 8)
      let converter = YlAppleCompressedAudioConverter()
      let cookie = prepared.audioCookies[stream.index] ?? Data()
      try converter.configure(stream: .init(codec: codec, sampleRate: Double(stream.sample_rate),
        channelCount: Int(stream.channel_count), magicCookie: cookie, generation: 1))
      let probe = converter.estimateOutput(for: .init(data: packets[0].0, ptsUs: 0, durationUs: 1_000_000_000, generation: 1))
      XCTAssertLessThanOrEqual(probe.byteCount, 65_536)
      guard probe.byteCount <= 65_536 else { continue } // No huge allocations in RED.
      var baseline = [(Int64, Int64, Int, UInt32, Float)]()
      for declared in [Int64(0), 1, 1_000_000_000, Int64.max] {
        // Start each metadata variant with a fresh codec instance so residual
        // decoder/dither history is not a second variable in the PCM comparison.
        try converter.configure(stream: .init(codec: codec, sampleRate: Double(stream.sample_rate),
          channelCount: Int(stream.channel_count), magicCookie: cookie, generation: 1))
        var observed = [(Int64, Int64, Int, UInt32, Float)]()
        for (data, pts, originalDuration) in packets {
          let packet = YlCompressedAudioPacket(data: data, ptsUs: pts,
            durationUs: declared == 0 ? originalDuration : declared, generation: 1)
          let estimate = converter.estimateOutput(for: packet)
          guard let decoded = try converter.convert(packet: packet) else { continue }
          let pcm = try XCTUnwrap(decoded.payload as? AVAudioPCMBuffer)
          let samples = try XCTUnwrap(pcm.floatChannelData)
          let frameBytes = Int(pcm.format.channelCount) * MemoryLayout<Float>.size
          XCTAssertLessThanOrEqual(Int(pcm.frameCapacity) * frameBytes, estimate.byteCount)
          XCTAssertGreaterThanOrEqual(estimate.durationUs, decoded.durationUs)
          observed.append((decoded.ptsUs, decoded.durationUs, decoded.byteCount, pcm.frameLength, samples[0][0]))
        }
        XCTAssertFalse(observed.isEmpty)
        if declared == 0 { baseline = observed }
        else {
          XCTAssertEqual(observed.count, baseline.count)
          for (a, b) in zip(observed, baseline) {
            XCTAssertEqual(a.0, b.0); XCTAssertEqual(a.1, b.1); XCTAssertEqual(a.2, b.2)
            XCTAssertEqual(a.3, b.3); XCTAssertEqual(a.4, b.4)
          }
        }
      }
    }
  }

  func testDTSAdmissionEstimateCoversActualPCMDespiteContainerRounding() throws {
    let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "p03-mkv-avc-dts", withExtension: "mkv"))
    let source = YlAppleSourceDescriptor(uri: fixture.absoluteString, kind: .file, formatHint: .matroska)
    let prepared = try YlPreparedFallback(source: source, requireHardwareProbe: false)
    defer { prepared.discard() }
    let stream = try XCTUnwrap(prepared.audioStreams.first { $0.codec == YLFCodecDTS })
    let converter = YlDtsAudioConverter()
    try converter.configure(stream: .init(codec: .dts, sampleRate: Double(stream.sample_rate),
      channelCount: Int(stream.channel_count), magicCookie: Data(), generation: 1))
    let media = try prepared.takeMedia(); defer { media.close() }
    let context = try XCTUnwrap(media.context)
    var compressed: Data?
    var containerDuration: Int64 = 0
    for _ in 0..<100 {
      var packet: YLFPacketRef?
      if ylf_read_packet(context, &packet) != 0 { break }
      defer { ylf_packet_release(&packet) }
      guard let p = packet, ylf_packet_stream_index(p) == stream.index else { continue }
      compressed = Data(bytes: try XCTUnwrap(ylf_packet_data(p)), count: ylf_packet_size(p))
      containerDuration = ylf_packet_duration_us(p)
      break
    }
    let data = try XCTUnwrap(compressed)
    for declaredDuration in [Int64(0), 1, containerDuration, Int64.max] {
      converter.reset()
      let packet = YlCompressedAudioPacket(data: data, ptsUs: 0, durationUs: declaredDuration, generation: 1)
      let estimate = converter.estimateOutput(for: packet)
      let actual = try XCTUnwrap(converter.convert(packet: packet))
      XCTAssertGreaterThan(actual.durationUs, 0)
      XCTAssertGreaterThanOrEqual(estimate.durationUs, actual.durationUs,
        "Container duration \(declaredDuration) must not under-reserve decoded PCM")
      XCTAssertEqual(estimate.durationUs, 10_667,
        "512 samples must fit the existing 100ms window regardless of container rounding")
      XCTAssertGreaterThanOrEqual(estimate.byteCount, actual.byteCount)
    }
    // Repack an actual core frame without changing its coding payload. Changing
    // only the core sampling-frequency field exercises real 32/16 kHz decode.
    for (rate, rateCode, speed) in [(32_000, 3, Float(0.25)), (16_000, 2, Float(0.5))] {
      var core = [UInt8](data)
      core[8] = (core[8] & 0xc3) | UInt8(rateCode << 2)
      for packed in [false, true] {
        var bigEndian = core
        if packed {
          let bits = core.flatMap { byte in (0..<8).reversed().map { (Int(byte) >> $0) & 1 } }
          bigEndian = []
          for offset in stride(from: 0, to: bits.count, by: 14) {
            var word = 0
            for bit in 0..<14 { word = (word << 1) | (offset + bit < bits.count ? bits[offset + bit] : 0) }
            if offset == 14 { word |= 0xc000 } // 14-bit sync word padding.
            bigEndian += [UInt8(word >> 8), UInt8(word & 255)]
          }
        }
        for littleEndian in [false, true] {
          var bytes = bigEndian
          if littleEndian {
            for index in stride(from: 0, to: bytes.count - 1, by: 2) { bytes.swapAt(index, index + 1) }
          }
          let output = AdmissionOutput()
          let budget = try YlFallbackBufferBudget.make(configuration: PlayerConfiguration(map: [:]))
          let renderer = YlAudioRenderer(bufferBudget: budget, output: output)
          defer { renderer.dispose() }
          try renderer.configure(stream: .init(codec: .dts, sampleRate: Double(rate),
            channelCount: Int(stream.channel_count), magicCookie: Data(), generation: 1))
          renderer.setRate(speed)
          XCTAssertEqual(try renderer.enqueue(packet: .init(data: Data(bytes), ptsUs: 0,
            durationUs: 1, generation: 1)), .scheduled,
            "Core DTS must progress at \(rate)Hz / \(speed)x, packed=\(packed), LE=\(littleEndian)")
          XCTAssertEqual(renderer.scheduledDurationUs, Int64(512 * 1_000_000 / rate))
          XCTAssertEqual(output.completions.count, 1)
        }
      }
    }
    // Truncated, trailing extension, invalid rate and unknown sync must not get
    // the smaller core-only reservation based on an unvalidated prefix.
    var badRate = data; badRate[8] &= 0xc3
    for malformed in [Data(data.prefix(9)), data + Data([0x64, 0x58, 0x20, 0x25]),
                      badRate, Data([1, 2, 3, 4])] {
      let estimate = converter.estimateOutput(for: .init(data: malformed, ptsUs: 0, durationUs: 1, generation: 1))
      XCTAssertEqual(estimate.durationUs, 170_667)
    }
  }

  func testImpossibleDurationFailsBeforeConversionRatherThanRetryingForever() throws {
    let converter = AdmissionConverter()
    converter.estimate = .init(durationUs: 256_000, byteCount: 1)
    let output = AdmissionOutput()
    let renderer = YlAudioRenderer(maxScheduledDurationUs: 1_000_000, converter: converter, output: output)
    defer { renderer.dispose() }
    try renderer.configure(stream: admissionStream())
    renderer.setRate(0.25)
    XCTAssertThrowsError(try renderer.enqueue(packet: admissionPacket())) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "policy.unsupported")
    }
    XCTAssertEqual(converter.convertCount, 0)
    XCTAssertTrue(output.completions.isEmpty)
    converter.estimate = .init(durationUs: 16_000, byteCount: 1)
    converter.actual = converter.estimate
    XCTAssertEqual(try renderer.enqueue(packet: admissionPacket()), .scheduled)
  }

  func testConsumedPCMOverflowIsNotRetryableBackpressure() throws {
    for bytes in [false, true] {
      let converter = AdmissionConverter()
      converter.actual = .init(durationUs: bytes ? 1 : 16, byteCount: bytes ? 16 : 1)
      let output = AdmissionOutput()
      let renderer = YlAudioRenderer(maxScheduledDurationUs: 10, maxScheduledBytes: 10,
        converter: converter, output: output)
      defer { renderer.dispose() }
      try renderer.configure(stream: admissionStream())
      XCTAssertThrowsError(try renderer.enqueue(packet: admissionPacket())) {
        XCTAssertEqual(($0 as? NativePlayerError)?.code, "policy.unsupported")
      }
      XCTAssertEqual(converter.convertCount, 1)
      XCTAssertNil(converter.emitted, "Rejected PCM must release its payload")
      XCTAssertEqual(renderer.scheduledBytes, 0)
      XCTAssertEqual(renderer.scheduledDurationUs, 0)
      XCTAssertTrue(output.completions.isEmpty)
      renderer.reset(generation: 2)
      converter.actual = .init(durationUs: 1, byteCount: 1)
      XCTAssertEqual(try renderer.enqueue(packet: admissionPacket(generation: 2)), .scheduled)
    }
  }

  func testRealAACUnderreportedDurationDoesNotBecomeRetryableBackpressure() throws {
    let output = AdmissionOutput()
    let renderer = YlAudioRenderer(maxScheduledDurationUs: 1_000,
      maxScheduledBytes: 1_000_000, output: output)
    defer { renderer.dispose() }
    try renderer.configure(stream: admissionStream())
    // Valid AAC-LC stereo silence. The short container duration is deliberately
    // smaller than decoded PCM. Even short metadata must not turn an impossible
    // output window into retryable backpressure.
    var failed = false
    for index in 0..<4 {
      do {
        let result = try renderer.enqueue(packet: .init(
          data: Data([0x21, 0x10, 0x04, 0x60, 0x8c, 0x1c]),
          ptsUs: Int64(index) * 21_333, durationUs: 1, generation: 1))
        guard result == .buffered else {
          XCTFail("Consumed AAC must fail instead of requesting replay: \(result)")
          break
        }
      } catch {
        XCTAssertEqual((error as? NativePlayerError)?.code, "policy.unsupported")
        failed = true
        break
      }
    }
    XCTAssertTrue(failed)
    XCTAssertTrue(output.completions.isEmpty)
    XCTAssertEqual(renderer.scheduledDurationUs, 0)
  }

  func testAudioPipelineDoesNotRetainOrReplayConsumedPacketAfterOverflow() throws {
    let converter = AdmissionConverter()
    converter.actual = .init(durationUs: 16, byteCount: 1)
    let renderer = YlAudioRenderer(maxScheduledDurationUs: 10, maxScheduledBytes: 10,
      converter: converter, output: AdmissionOutput())
    try renderer.configure(stream: admissionStream())
    let budget = try YlFallbackBufferBudget.make(configuration: PlayerConfiguration(map: [:]))
    let pipeline = YlAudioPipeline(bufferBudget: budget, lock: NSLock(), generation: 1,
      factory: AdmissionFactory(renderer: renderer))
    let output = AdmissionPipelineOutput()
    pipeline.output = output
    pipeline.initializeRenderer()
    defer { pipeline.discardRenderer() }
    var backpressure = 0
    pipeline.enqueue(admissionPacket(), codecName: "AAC") { _ in backpressure += 1 }
    XCTAssertEqual(output.failures.map(\.code), ["policy.unsupported"])
    XCTAssertFalse(pipeline.hasPendingPacket)
    XCTAssertEqual(backpressure, 0)
    pipeline.retryPending(codecName: "AAC")
    XCTAssertEqual(converter.convertCount, 1)
    XCTAssertEqual(output.pumps, 0)
  }

  func testPreconversionBackpressureStillRetriesOnceCapacityIsReleased() throws {
    let converter = AdmissionConverter()
    converter.estimate = .init(durationUs: 8, byteCount: 8)
    converter.actual = converter.estimate
    let output = AdmissionOutput()
    let renderer = YlAudioRenderer(maxScheduledDurationUs: 10, maxScheduledBytes: 10,
      converter: converter, output: output)
    defer { renderer.dispose() }
    try renderer.configure(stream: admissionStream())
    XCTAssertEqual(try renderer.enqueue(packet: admissionPacket()), .scheduled)
    XCTAssertEqual(try renderer.enqueue(packet: admissionPacket()), .wouldExceedBytes)
    XCTAssertEqual(converter.convertCount, 1)
    output.completions[0]()
    XCTAssertEqual(try renderer.enqueue(packet: admissionPacket()), .scheduled)
    XCTAssertEqual(converter.convertCount, 2)
  }

  private func admissionStream() -> YlAudioStreamConfiguration {
    .init(codec: .aac, sampleRate: 48_000, channelCount: 2,
      magicCookie: Data([0x11, 0x90]), generation: 1)
  }
  private func admissionPacket(generation: UInt64 = 1) -> YlCompressedAudioPacket {
    .init(data: Data([1]), ptsUs: 0, durationUs: 1, generation: generation)
  }
  private final class AdmissionConverter: YlAudioPacketConverting {
    var estimate = YlAudioBufferEstimate(durationUs: 1, byteCount: 1)
    var actual = YlAudioBufferEstimate(durationUs: 1, byteCount: 1)
    var convertCount = 0
    weak var emitted: NSObject?
    func configure(stream: YlAudioStreamConfiguration) throws {}
    func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate { estimate }
    func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer? {
      convertCount += 1
      let payload = NSObject(); emitted = payload
      return .init(payload: payload, ptsUs: packet.ptsUs, durationUs: actual.durationUs,
        byteCount: actual.byteCount, generation: packet.generation)
    }
  }
  private final class AdmissionOutput: YlAudioOutputDriving {
    var volume: Float = 1
    var rate: Float = 1
    var renderedAudioTime: YlRenderedAudioTime? { nil }
    var completions = [() -> Void]()
    func configure(sampleRate: Double, channelCount: Int) throws {}
    func schedule(_ buffer: YlScheduledAudioBuffer, completion: @escaping () -> Void) {
      completions.append(completion)
    }
    func play() throws {}
    func pause() {}
    func reset() { completions.removeAll() }
    func dispose() { completions.removeAll() }
  }
  private struct AdmissionFactory: YlAudioRendererMaking {
    let renderer: YlAudioRenderer
    func makeRenderer(bufferBudget: YlFallbackBufferBudget) -> YlAudioRenderer { renderer }
  }
  private final class AdmissionPipelineOutput: YlAudioPipelineOutput {
    var failures = [NativePlayerError]()
    var pumps = 0
    func setDemuxPumping(_ value: Bool) {}
    func requestAudioPump() { pumps += 1 }
    func requestAudioPump(after delay: TimeInterval) { pumps += 1 }
    func fail(_ error: NativePlayerError) { failures.append(error) }
  }

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
