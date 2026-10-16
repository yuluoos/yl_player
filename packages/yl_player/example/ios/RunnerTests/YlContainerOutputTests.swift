@testable import yl_player_apple
import AVFoundation
import CoreImage
import CryptoKit
import MachO
import XCTest
import YlFFmpegBridge

private final class ContainerTexture: YlTextureOutput {
  let textureId: Int64 = 993
  var rgb: [Int] = []
  var history: [[Int]] = []
  var onImage: (([Int]) -> Void)?
  // Fixture references are encoded RGB values. Do not transform them through
  // this host's display ICC profile; physical display colour is separate proof.
  private let context = CIContext(options: [.cacheIntermediates: false,
    .workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
  func publish(_ pixel: CVPixelBuffer?) {
    guard let pixel else { return }
    let image = CIImage(cvPixelBuffer: pixel)
    var rgba = [UInt8](repeating: 0, count: 4)
    context.render(image, toBitmap: &rgba, rowBytes: 4,
      bounds: CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1),
      format: .RGBA8, colorSpace: nil)
    rgb = rgba.prefix(3).map(Int.init); history.append(rgb); onImage?(rgb)
  }
  func resize(width: Int, height: Int) {}
  func clear() { rgb = [] }
  func dispose() { clear() }
}
private final class ContainerDisplay: YlDisplayDriving {
  var isPaused = false
  let tick: () -> Void
  init(_ tick: @escaping () -> Void) { self.tick = tick }
  func invalidate() { isPaused = true }
  func fire() { if !isPaused { tick() } }
}
private final class ContainerPCM: YlAudioPacketConverting {
  struct Block { let pts: Int64; let rate: Double; let samples: [[Float]] }
  let converter = YlAppleCompressedAudioConverter()
  // Preserve the real converter format, including explicit surround labels.
  var pcmFormat: AVAudioFormat? { converter.pcmFormat }
  var reservesOutputBuffers: Bool { converter.reservesOutputBuffers }
  private let lock = NSLock()
  private var blocks = [Block]()
  private var lastGeneration: UInt64 = 0
  var generation: UInt64 { lock.withLock { lastGeneration } }
  func configure(stream: YlAudioStreamConfiguration) throws { try converter.configure(stream: stream) }
  func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate { converter.estimateOutput(for: packet) }
  func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer? {
    lock.withLock { lastGeneration = packet.generation }
    let output = try converter.convert(packet: packet)
    if let output, let pcm = output.payload as? AVAudioPCMBuffer, let data = pcm.floatChannelData {
      let channels = Int(pcm.format.channelCount), frames = Int(pcm.frameLength)
      let samples = (0..<channels).map { channel in
        (0..<frames).map { frame in pcm.format.isInterleaved ? data[0][frame * channels + channel] : data[channel][frame] }
      }
      lock.withLock { blocks.append(.init(pts: output.ptsUs, rate: pcm.format.sampleRate, samples: samples)) }
    }
    return output
  }
  func reset() { converter.reset() }
  var evidence: [Block] { lock.withLock { blocks } }
  func clearEvidence() { lock.withLock { blocks.removeAll() } }
  func verifyTone(start: Int64, end: Int64, expected: Double, channels: Int = 2, file: StaticString = #filePath, line: UInt = #line) {
    let rows = lock.withLock { blocks }
    XCTAssertFalse(rows.isEmpty, file: file, line: line)
    XCTAssertTrue(rows.allSatisfy { $0.samples.count == channels }, "Decoded channel count changed", file: file, line: line)
    for channel in 0..<channels {
      var samples = [Float](); var rate = 0.0
      for row in rows where row.samples.count > channel {
        rate = row.rate
        for (index, value) in row.samples[channel].enumerated() {
          let pts = row.pts + Int64(Double(index) * 1_000_000 / row.rate)
          if pts >= start && pts < end { samples.append(value) }
        }
      }
      XCTAssertGreaterThan(samples.count, 4000, "Missing decoded PCM", file: file, line: line)
      guard samples.count > 4000 else { continue }
      let crossings = zip(samples, samples.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
      let frequency = Double(crossings) * rate / Double(samples.count)
      let target = channels == 6 && channel == 3 ? 60 + (expected - 440) / 22 : expected + Double(channel * 55)
      XCTAssertEqual(frequency, target, accuracy: 9, file: file, line: line)
      XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.01, file: file, line: line)
    }
  }
}
private final class ContainerAudioFactory: YlAudioRendererMaking {
  private(set) var pcm = ContainerPCM()
  private(set) var renderer: YlAudioRenderer?
  func clock() -> Int64? {
    guard let renderer else { return nil }
    switch renderer.clockObservation(expectedGeneration: pcm.generation) {
    case .running(let sample): return sample.positionUs
    case .ended(let position, _): return position
    default: return nil
    }
  }
  func makeRenderer(bufferBudget: YlFallbackBufferBudget) -> YlAudioRenderer {
    // Real platform output and consumed audio clock; record the decoded PCM
    // without replacing the device output with a fabricated completion clock.
    pcm = ContainerPCM()
    let created = YlAudioRenderer(bufferBudget: bufferBudget, converter: pcm)
    renderer = created; return created
  }
}

/// Pinned host decoder PCM, including encoded delay/padding. Timestamp lookup
/// uses the independent demux frame table; there is no correlation/re-alignment.
private struct ContainerReference: Decodable {
  struct Packet: Decodable { let ptsUs: Int64; let offset: Int; let count: Int }
  struct Window: Decodable { let start: Int; let count: Int; let f32le: String }
  struct Track: Decodable {
    let track: Int; let channels: Int; let rate: Int; let frames: Int
    let packetFrames: [Packet]; let windows: [Window]
    func start(at target: Int64) -> (index: Int, pts: Int64) {
      for packet in packetFrames {
        let skip = max(0, Int((target - packet.ptsUs) * Int64(rate) + 999_999) / 1_000_000)
        if skip < packet.count {
          return (packet.offset + skip, packet.ptsUs + (Int64(skip) * 1_000_000 + Int64(rate)-1) / Int64(rate))
        }
      }
      return (frames, -1)
    }
    func verify(_ rows: [ContainerPCM.Block], target: Int64, file: StaticString = #filePath, line: UInt = #line) throws {
      let start = start(at: target)
      XCTAssertEqual(try XCTUnwrap(rows.first, file: file, line: line).pts, start.pts, accuracy: 1, file: file, line: line)
      XCTAssertTrue(rows.allSatisfy { $0.samples.count == channels && $0.rate == Double(rate) }, file: file, line: line)
      let samples = rows.flatMap { block in (0..<(block.samples.first?.count ?? 0)).flatMap { frame in block.samples.map { $0[frame] } } }
      let expectedPackets = packetFrames.compactMap { packet -> (Int64, Int)? in
        let skip = max(0, Int((target - packet.ptsUs) * Int64(rate) + 999_999) / 1_000_000)
        guard skip < packet.count else { return nil }
        return (packet.ptsUs + (Int64(skip) * 1_000_000 + Int64(rate)-1) / Int64(rate), packet.count - skip)
      }
      XCTAssertEqual(rows.count, expectedPackets.count, "Missing/duplicated PCM packet", file: file, line: line)
      for (row, expected) in zip(rows, expectedPackets) {
        XCTAssertEqual(row.pts, expected.0, accuracy: 1, file: file, line: line)
        XCTAssertEqual(row.samples[0].count, expected.1, file: file, line: line)
      }
      XCTAssertEqual(samples.count / channels, frames - start.index, "Lost/duplicated head or tail PCM", file: file, line: line)
      // First and last 4096 frames include codec priming and the short FLAC tail.
      for index in [start.index, frames - 4096] {
        let window = try XCTUnwrap(windows.first { $0.start <= index && $0.start + $0.count >= index + 4096 }, file: file, line: line)
        let data = try XCTUnwrap(Data(base64Encoded: window.f32le), file: file, line: line)
        let reference = data.withUnsafeBytes { bytes in stride(from: 0, to: data.count, by: 4).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) } }
        let actualOffset = (index - start.index) * channels, refOffset = (index - window.start) * channels
        guard actualOffset >= 0, actualOffset + 4096 * channels <= samples.count else { XCTFail("Missing reference window", file: file, line: line); continue }
        var peak: Float = 0
        for i in 0..<(4096 * channels) { peak = max(peak, abs(samples[actualOffset+i] - reference[refOffset+i])) }
        XCTAssertLessThan(peak, 0.0002, "track=\(track) window=\(index) unshifted PCM mismatch", file: file, line: line)
      }
      let last = try XCTUnwrap(rows.last, file: file, line: line)
      let expectedLast = try XCTUnwrap(packetFrames.last, file: file, line: line)
      XCTAssertEqual(last.pts + Int64(last.samples[0].count) * 1_000_000 / Int64(rate),
        expectedLast.ptsUs + Int64(expectedLast.count) * 1_000_000 / Int64(rate), accuracy: 1, file: file, line: line)
      print("P03_PCM_BOUNDARY track=\(track) channels=\(channels) target=\(target) frames=\(samples.count/channels) first=\(rows.first!.pts) last=\(last.pts) pinned_reference_windows=true")
    }
  }
  let tracks: [Track]
  static func load() throws -> Self {
    let url = try XCTUnwrap(Bundle(for: YlContainerOutputTests.self).url(forResource: "p03-pcm-reference", withExtension: "json"))
    return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
  }
}

@MainActor final class YlContainerOutputTests: XCTestCase {
  private func checkOutput(name: String, ext: String, format: YlSourceFormat, channels: Int = 2, allowSimulatorHardwareSkip: Bool = false) async throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    let bound = try ContainerBoundAV(name: name, media: url)
    defer { bound?.attach(to: self) }
    let prepared = try YlPreparedFallback(source: .init(uri: url.absoluteString, kind: .file, formatHint: format), requireHardwareProbe: false)
    if channels == 6 {
      let stream = try XCTUnwrap(prepared.audioStreams.first)
      XCTAssertEqual(stream.channel_count, 6)
      XCTAssertEqual(stream.channel_layout_mask, 0x60f, "AC3 encoded speaker layout must survive discovery")
    }
    let texture = ContainerTexture(), audio = ContainerAudioFactory()
    texture.onImage = { bound?.image($0, clock: audio.clock()) }
    var display: ContainerDisplay?, state: YlNativeState?, errors = [NativePlayerError]()
    var initial: YlFallbackBackend?
    do {
      initial = try YlFallbackBackend(playerId: 993,
      services: .init(platform: .current, textureOutput: texture, makeDisplayDriver: { let d = ContainerDisplay($0); display = d; return d }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: prepared, generation: 1,
      audioRendererFactory: audio, emit: { callback in
        if case .state(let value) = callback.event { state = value }
        if case .failure(let error) = callback.event { errors.append(error) }
      })
      try initial?.activate()
    } catch {
      initial?.dispose()
      bound?.disposed = true; bound?.failureCode = (error as? NativePlayerError)?.code ?? "test.activation"
      #if targetEnvironment(simulator)
      if allowSimulatorHardwareSkip && bound == nil && (error as? NativePlayerError)?.code == "decoder.video_hardware_unavailable" {
        throw XCTSkip("iOS Simulator has no hardware decoder for this fixture; no output acceptance.")
      }
      #endif
      throw error
    }
    let backend = try XCTUnwrap(initial)
    defer { backend.dispose(); bound?.disposed = true; bound?.releasedAudioBytes = audio.renderer?.scheduledBytes ?? 0 }
    func advance(until condition: () -> Bool) async throws {
      let deadline = ProcessInfo.processInfo.systemUptime + 10
      while !condition() && errors.isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
        display?.fire(); backend.emitState(); try await Task.sleep(nanoseconds: 10_000_000)
      }
      XCTAssertTrue(errors.isEmpty, errors.map(\.code).joined(separator: ","))
      XCTAssertTrue(condition(), "State=\(state?.status ?? "none") position=\(state?.positionMs ?? -1)")
    }
    try backend.play()
    try await advance(until: { state?.status == "completed" })
    bound?.completed = state?.status == "completed"
    bound?.capture(audio.pcm.evidence, markers: [0,1,2,3])
    for expected in [[255,0,0], [0,255,0], [0,0,255], [255,255,255]] {
      XCTAssertTrue(texture.history.contains { rgb in zip(rgb, expected).allSatisfy { abs($0 - $1) < 24 } }, "Missing displayed marker \(expected), observed=\(Set(texture.history))")
    }
    for second in 0..<4 {
      audio.pcm.verifyTone(start: Int64(second) * 1_000_000 + 250_000,
        end: Int64(second) * 1_000_000 + 750_000, expected: Double(440 + second * 220), channels: channels)
    }
    for (target, rgb, tone): (Int64, [Int], Double) in [(1250,[0,255,0],660), (2250,[0,0,255],880), (0,[255,0,0],440)] {
      try backend.pause(); audio.pcm.clearEvidence(); texture.history.removeAll()
      try await Task.detached { try backend.seek(toMs: target, cancellationToken: nil) }.value
      bound?.begin("seek-\(target)")
      try backend.play()
      try await advance(until: { (state?.positionMs ?? 0) >= target + 450 && !texture.history.isEmpty })
      XCTAssertTrue(texture.history.contains { value in zip(value,rgb).allSatisfy { abs($0 - $1) < 24 } }, "seek=\(target), observed=\(Set(texture.history))")
      audio.pcm.verifyTone(start: target * 1000 + 100_000, end: target * 1000 + 400_000, expected: tone, channels: channels)
      bound?.capture(audio.pcm.evidence, markers: [Int(target / 1000)])
    }
    backend.stop(); backend.dispose(); backend.dispose()
    bound?.outcome = "passed"; bound?.failureCode = ""
  }
  func testProgramStreamActualPixelsPCMAndBidirectionalSeek() async throws {
    do { try await checkOutput(name: "p03-ps-avc-mp3", ext: "mpg", format: .mpegPs, allowSimulatorHardwareSkip: true) }
    catch let error as NativePlayerError { XCTFail("PS: \(error.code): \(error.message)") }
  }
  func testNonzeroVorbisDelayActualPixelsPCMAndBidirectionalSeek() async throws {
    do { try await checkOutput(name: "p03-webm-vp9-vorbis", ext: "webm", format: .webm, allowSimulatorHardwareSkip: true) }
    catch let error as NativePlayerError { XCTFail("Vorbis: \(error.code): \(error.message)") }
  }
  func testAC3SurroundActualPixelsSixChannelPCMAndSeek() async throws {
    do { try await checkOutput(name: "p03-mkv-avc-ac3-51", ext: "mkv", format: .matroska, channels: 6) }
    catch let error as NativePlayerError { XCTFail("AC3: \(error.code): \(error.message)") }
  }
  func testEAC3ActualPixelsPCMAndSeek() async throws {
    try await checkOutput(name: "p03-mkv-avc-eac3", ext: "mkv", format: .matroska)
  }
  func testDTSActualPixelsPCMAndSeek() async throws {
    try await checkOutput(name: "p03-mkv-avc-dts", ext: "mkv", format: .matroska)
  }
  func testFLACActualPixelsPCMAndSeek() async throws {
    try await checkOutput(name: "p03-mkv-avc-flac", ext: "mkv", format: .matroska)
  }

  func testRealConvertersPreserveFirstAndLastSamples() throws {
    let reference = try ContainerReference.load()
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "p03-pcm-switch", withExtension: "mkv"))
    for track in reference.tracks where track.track != 1 || track.channels == 6 {
      var context: YLFMediaContextRef?; var info = YLFMediaInfo()
      XCTAssertEqual(ylf_open_local(url.path, &context, &info), 0)
      defer { ylf_close(&context) }
      let opened = try XCTUnwrap(context)
      var stream = YLFStreamInfo()
      XCTAssertEqual(ylf_copy_stream_info(opened, Int32(track.track), &stream), 0)
      let count = ylf_stream_codec_config_size(opened, stream.index)
      var cookie = Data(count: count)
      if count > 0 { XCTAssertEqual(cookie.withUnsafeMutableBytes {
        ylf_copy_stream_codec_config(opened, stream.index, $0.bindMemory(to: UInt8.self).baseAddress, count)
      }, 0) }
      let pcm = ContainerPCM()
      try pcm.configure(stream: .init(codec: .init(bridgeCodec: stream.codec), sampleRate: Double(stream.sample_rate),
        channelCount: Int(stream.channel_count), magicCookie: cookie, generation: 1, channelMask: stream.channel_layout_mask))
      while true {
        var packet: YLFPacketRef?
        let result = ylf_read_packet(opened, &packet)
        if result == YLFResultEOF { break }
        XCTAssertEqual(result, 0)
        defer { ylf_packet_release(&packet) }
        let owned = try XCTUnwrap(packet)
        guard ylf_packet_stream_index(owned) == stream.index else { continue }
        _ = try pcm.convert(packet: .init(data: Data(bytes: try XCTUnwrap(ylf_packet_data(owned)), count: ylf_packet_size(owned)),
          ptsUs: ylf_packet_pts_us(owned), durationUs: ylf_packet_duration_us(owned), generation: 1, presentationStartUs: 0))
      }
      try track.verify(pcm.evidence, target: 0)
    }
  }

  func testCodecTrackSwitchPreservesTargetSamplesAndTail() async throws {
    let reference = try ContainerReference.load()
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "p03-pcm-switch", withExtension: "mkv"))
    let prepared = try YlPreparedFallback(source: .init(uri: url.absoluteString, kind: .file, formatHint: .matroska), requireHardwareProbe: false)
    let texture = ContainerTexture(), audio = ContainerAudioFactory()
    var display: ContainerDisplay?, state: YlNativeState?, errors = [NativePlayerError]()
    let backend = try YlFallbackBackend(playerId: 994,
      services: .init(platform: .current, textureOutput: texture, makeDisplayDriver: { let d = ContainerDisplay($0); display = d; return d }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), prepared: prepared, generation: 1,
      audioRendererFactory: audio, emit: {
        if case .state(let value) = $0.event { state = value }
        if case .failure(let error) = $0.event { errors.append(error) }
      })
    defer { backend.dispose() }
    try backend.activate()
    for index in [2,3,4,1] {
      try backend.pause()
      try await Task.detached { try backend.seek(toMs: 2500, cancellationToken: nil) }.value
      try backend.selectAudioTrack("audio-\(index)")
      let pcm = audio.pcm
      try backend.play()
      let deadline = ProcessInfo.processInfo.systemUptime + 8
      repeat {
        display?.fire(); backend.emitState(); try await Task.sleep(nanoseconds: 10_000_000)
      } while state?.status != "completed" && errors.isEmpty && ProcessInfo.processInfo.systemUptime < deadline
      XCTAssertTrue(errors.isEmpty, errors.map(\.code).joined(separator: ","))
      XCTAssertEqual(state?.status, "completed")
      let track = try XCTUnwrap(reference.tracks.first { $0.track == index && ($0.channels == 6 || index != 1) })
      try track.verify(pcm.evidence, target: 2_500_000)
    }
  }

  func testDASHWindowOwnsNegativePCMClipping() throws {
    let reference = try ContainerReference.load()
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "p03-pcm-switch", withExtension: "mkv"))
    for track in reference.tracks where track.track != 1 || track.channels == 6 {
      var context: YLFMediaContextRef?; var info = YLFMediaInfo()
      XCTAssertEqual(ylf_open_local(url.path, &context, &info), 0)
      defer { ylf_close(&context) }
      let opened = try XCTUnwrap(context)
      var stream = YLFStreamInfo()
      XCTAssertEqual(ylf_copy_stream_info(opened, Int32(track.track), &stream), 0)
      let size = ylf_stream_codec_config_size(opened, stream.index)
      var cookie = Data(count: size)
      if size > 0 { XCTAssertEqual(cookie.withUnsafeMutableBytes {
        ylf_copy_stream_codec_config(opened, stream.index, $0.bindMemory(to: UInt8.self).baseAddress, size)
      }, 0) }
      var bytes: Data?
      while bytes == nil {
        var packet: YLFPacketRef?
        XCTAssertEqual(ylf_read_packet(opened, &packet), 0)
        defer { ylf_packet_release(&packet) }
        let owned = try XCTUnwrap(packet)
        if ylf_packet_stream_index(owned) == stream.index {
          bytes = Data(bytes: try XCTUnwrap(ylf_packet_data(owned)), count: ylf_packet_size(owned))
        }
      }
      let scope = try YlManagedBufferLedger().makeScope(maxBytes: nil)
      let window = try YlDashProgramTimeline.Window(start: YlDashProgramTime(0), end: YlDashProgramTime(1))
      let converter = YlDashAudioConverter(window: window, scope: scope)
      // These owned controls have known encoded layouts; this test isolates the
      // rational DASH timestamp owner from the separate discovery assertions.
      let mask: UInt64 = track.track == 1 ? 0x60f : (track.track == 2 ? 3 : stream.channel_layout_mask)
      try converter.configure(stream: .init(codec: .init(bridgeCodec: stream.codec), sampleRate: 48000,
        channelCount: track.channels, magicCookie: cookie, generation: 1, channelMask: mask))
      let data = try XCTUnwrap(bytes)
      let input = YlCompressedAudioPacket(data: data, ptsUs: -5000, durationUs: 32000, generation: 1)
      XCTAssertNil(input.presentationStartUs)
      try converter.register(YlDashProgramTime(-1, 200), forMicroseconds: -5000)
      let output = try XCTUnwrap(converter.convert(packet: input))
      let pcm = try XCTUnwrap(output.payload as? AVAudioPCMBuffer)
      XCTAssertEqual(output.ptsUs, 0)
      XCTAssertEqual(Int(pcm.frameLength), try XCTUnwrap(track.packetFrames.first).count - 240)
      converter.reset()
      // A fully clipped packet must still retire its timestamp entry. Exceed
      // the adapter's 256-entry bound without retaining any decoded output.
      for index in 0..<260 {
        let pts = Int64(-1_000_000 - index * 32_000)
        try converter.register(YlDashProgramTime(pts, 1_000_000), forMicroseconds: pts)
        XCTAssertNil(try converter.convert(packet: .init(data: data, ptsUs: pts, durationUs: 32000, generation: 1)))
      }
      converter.reset()
    }
  }

  func testPCMTrimRoundsForwardAndRejectsTimestampOverflow() throws {
    for interleaved in [false, true] {
      let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: interleaved))
      let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
      pcm.frameLength = 3
      let samples = try XCTUnwrap(pcm.floatChannelData)
      for frame in 0..<3 { for channel in 0..<2 {
        if interleaved { samples[0][frame * 2 + channel] = Float(frame * 10 + channel) }
        else { samples[channel][frame] = Float(frame * 10 + channel) }
      } }
      XCTAssertEqual(try ylTrimPCMToPresentationStart(pcm, ptsUs: 100, targetUs: 101), 123)
      XCTAssertEqual(pcm.frameLength, 2)
      XCTAssertEqual(samples[0][0], 10)
      XCTAssertEqual(interleaved ? samples[0][1] : samples[1][0], 11)
      XCTAssertThrowsError(try ylTrimPCMToPresentationStart(pcm, ptsUs: Int64.max - 1, targetUs: Int64.max))
      XCTAssertEqual(pcm.frameLength, 2, "Reject overflow before moving samples")
      XCTAssertNil(try ylTrimPCMToPresentationStart(pcm, ptsUs: 0, targetUs: 1_000_000))
    }
  }

  func testDolbyTrimRetainsAllocationAndResetsHistory() throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "p03-pcm-switch", withExtension: "mkv"))
    var context: YLFMediaContextRef?; var info = YLFMediaInfo()
    XCTAssertEqual(ylf_open_local(url.path, &context, &info), 0)
    defer { ylf_close(&context) }
    let opened = try XCTUnwrap(context)
    var bytes: Data?
    while bytes == nil {
      var packet: YLFPacketRef?
      XCTAssertEqual(ylf_read_packet(opened, &packet), 0)
      defer { ylf_packet_release(&packet) }
      let owned = try XCTUnwrap(packet)
      if ylf_packet_stream_index(owned) == 2 {
        bytes = Data(bytes: try XCTUnwrap(ylf_packet_data(owned)), count: ylf_packet_size(owned))
      }
    }
    let ledger = YlManagedBufferLedger(), converter = YlAppleCompressedAudioConverter()
    let scope = try ledger.makeScope(maxBytes: nil)
    converter.bufferScope = scope
    try converter.configure(stream: .init(codec: .eac3, sampleRate: 48000,
      channelCount: 2, magicCookie: Data(), generation: 1, channelMask: 3))
    let packet = YlCompressedAudioPacket(data: try XCTUnwrap(bytes), ptsUs: -5000, durationUs: 32000, generation: 1, presentationStartUs: 0)
    var firstSamples = [Float]()
    for _ in 0..<2 {
      var result = try converter.convert(packet: packet)
      XCTAssertEqual(result?.ptsUs, 0)
      XCTAssertEqual((result?.payload as? AVAudioPCMBuffer)?.frameLength, 1296)
      XCTAssertEqual(result?.reservation?.bytes, 1536 * 2 * 4, "Trim must retain original allocation charge")
      XCTAssertEqual(ledger.snapshot.currentBytes, 1536 * 2 * 4)
      let data = try XCTUnwrap((result?.payload as? AVAudioPCMBuffer)?.floatChannelData)
      let samples = (0..<16).map { data[0][$0] }
      if firstSamples.isEmpty { firstSamples = samples } else { XCTAssertEqual(samples, firstSamples) }
      result = nil
      XCTAssertEqual(ledger.snapshot.currentBytes, 0)
      converter.reset()
    }
    var preroll = packet; preroll.presentationStartUs = 1_000_000
    XCTAssertNil(try converter.convert(packet: preroll))
    XCTAssertEqual(ledger.snapshot.currentBytes, 0, "Discarded preroll must release scratch and PCM")
  }

}

/// Test-only evidence binds the loaded consumer and XCTest code before playback.
/// No production API exports PCM, filesystem paths or build fingerprints.
private final class ContainerBoundAV {
  let plan: [String: Any]
  let caseId: String
  let sessionId = UUID().uuidString
  let mediaHash: String
  var phases = [[String: Any]]()
  var pixels = [[String: Any]]()
  var phase = "play"
  var completed = false
  var disposed = false
  var outcome = "failed"
  var failureCode = "test.incomplete"
  var releasedAudioBytes = -1
  var images = [[String: String]]()

  static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  static func fileHash(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
    var hash = SHA256()
    while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  private static func require(_ condition: Bool, _ reason: String) throws {
    if !condition { throw NSError(domain: "P03BoundAV", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
  }
  init?(name: String, media: URL) throws {
    guard let encoded = ProcessInfo.processInfo.environment["YL_P03_BOUND_PLAN"] else { return nil }
    guard let bytes = Data(base64Encoded: encoded),
          let plan = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
      throw NSError(domain: "P03BoundAV", code: 2)
    }
    #if os(macOS)
    let platform = "macos"
    #else
    let platform = "ios"
    #endif
    try Self.require(plan["platform"] as? String == platform, "runtime platform mismatch")
    self.plan = plan; caseId = String(name.dropFirst(4)); mediaHash = try Self.fileHash(media)
    let rows = plan["planned"] as? [[String: Any]] ?? []
    try Self.require(rows.contains { $0["caseId"] as? String == caseId && $0["mediaHash"] as? String == mediaHash }, "media identity mismatch")
    var allowed = Set<String>()
    for (key, root) in [("productManifest", Bundle.main.bundleURL), ("testManifest", Bundle(for: YlContainerOutputTests.self).bundleURL)] {
      guard let encoded = plan[key] as? String, let data = Data(base64Encoded: encoded),
            let files = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw NSError(domain: "P03BoundAV", code: 3) }
      try Self.require(Self.digest(data) == plan[key == "productManifest" ? "buildSha256" : "testSha256"] as? String, "manifest identity mismatch")
      for file in files {
        guard let path = file["path"] as? String, let sha = file["sha256"] as? String else { throw NSError(domain: "P03BoundAV", code: 4) }
        try Self.require(!path.hasPrefix("/") && !path.split(separator: "/").contains(".."), "invalid artifact path")
        try Self.require(try Self.fileHash(root.appendingPathComponent(path)) == sha, "artifact changed: \(path)")
        allowed.insert(sha)
      }
    }
    for index in 0..<_dyld_image_count() {
      guard let pointer = _dyld_get_image_name(index) else { continue }
      let path = String(cString: pointer)
      guard path.hasPrefix(Bundle.main.bundleURL.path + "/") || path.contains("YlFFmpegBridge.framework/") || path.contains("yl_player_apple") else { continue }
      let sha = try Self.fileHash(URL(fileURLWithPath: path))
      try Self.require(allowed.contains(sha), "loaded image differs from frozen product: \(path)")
      images.append(["image": URL(fileURLWithPath: path).lastPathComponent, "sha256": sha])
    }
    try Self.require(images.contains { $0["image"] == "YlFFmpegBridge" }, "loaded bridge identity missing")
  }
  var origin: [String: Any] { ["runId": plan["runId"]!, "sessionId": sessionId, "buildSha256": plan["buildSha256"]!] }
  func image(_ rgb: [Int], clock: Int64?) {
    var value: [String: Any] = ["value": rgb, "format": "rgb8", "hostTimeUs": Int64(ProcessInfo.processInfo.systemUptime * 1_000_000)]
    if let clock { value["audioClockUs"] = clock }
    pixels.append(value)
  }
  func begin(_ value: String) { phase = value; pixels.removeAll() }
  func capture(_ rows: [ContainerPCM.Block], markers: [Int]) {
    var windows = [[String: Any]]()
    for marker in markers {
      let start = phase == "play" ? Int64(marker) * 1_000_000 + 250_000 : Int64(phase.dropFirst(5))! * 1000 + 100_000
      var samples = [Float](), first: Int64?, channels = 0, rate = 0
      for row in rows {
        channels = row.samples.count; rate = Int(row.rate)
        for frame in 0..<(row.samples.first?.count ?? 0) {
          let pts = row.pts + Int64(Double(frame) * 1_000_000 / row.rate)
          if pts >= start && pts < start + 500_000 && samples.count < 8192 * channels {
            if first == nil { first = pts }
            for channel in row.samples { samples.append(channel[frame]) }
          }
        }
      }
      let raw = samples.map { $0.bitPattern.littleEndian }.withUnsafeBytes { Data($0) }
      var window = origin
      window.merge(["phase": phase, "marker": marker, "rate": rate, "channels": channels,
        "startUs": first ?? -1, "frames": channels > 0 ? samples.count / channels : 0,
        "pcmF32LE": raw.base64EncodedString(), "pcmSha256": Self.digest(raw)]) { _, rhs in rhs }
      windows.append(window)
    }
    var row = origin; row.merge(["phase": phase, "pixels": pixels, "pcmWindows": windows]) { _, rhs in rhs }
    phases.append(row)
  }
  func attach(to test: XCTestCase) {
    var row = origin
    row.merge(["schema": 1, "platform": plan["platform"]!, "testSha256": plan["testSha256"]!,
      "caseId": caseId, "mediaHash": mediaHash, "identityVerified": true, "loadedImages": images,
      "runtime": ProcessInfo.processInfo.operatingSystemVersionString,
      "outcome": outcome, "failureCode": failureCode, "completed": completed, "disposed": disposed,
      "releasedAudioBytes": releasedAudioBytes, "phases": phases]) { _, rhs in rhs }
    do {
      let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
      let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
      attachment.name = "p03-bound-\(plan["runId"]!)-\(caseId).json"; attachment.lifetime = .keepAlways
      test.add(attachment)
    } catch { XCTFail("Cannot preserve bound A/V evidence: \(error)") }
  }
}
