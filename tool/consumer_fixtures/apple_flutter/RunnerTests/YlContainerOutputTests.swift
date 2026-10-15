@testable import yl_player_apple
import AVFoundation
import CoreImage
import XCTest

private final class ContainerTexture: YlTextureOutput {
  let textureId: Int64 = 993
  var rgb: [Int] = []
  var history: [[Int]] = []
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
    rgb = rgba.prefix(3).map(Int.init); history.append(rgb)
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
  private let lock = NSLock()
  private var blocks = [Block]()
  func configure(stream: YlAudioStreamConfiguration) throws { try converter.configure(stream: stream) }
  func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate { converter.estimateOutput(for: packet) }
  func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer? {
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
  func clearEvidence() { lock.withLock { blocks.removeAll() } }
  func verifyTone(start: Int64, end: Int64, expected: Double, file: StaticString = #filePath, line: UInt = #line) {
    let rows = lock.withLock { blocks }
    XCTAssertFalse(rows.isEmpty, file: file, line: line)
    for channel in 0..<2 {
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
      XCTAssertEqual(frequency, expected + Double(channel * 55), accuracy: 9, file: file, line: line)
      XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.01, file: file, line: line)
    }
  }
}
private final class ContainerAudioFactory: YlAudioRendererMaking {
  let pcm = ContainerPCM()
  func makeRenderer(bufferBudget: YlFallbackBufferBudget) -> YlAudioRenderer {
    // Real platform output and consumed audio clock; record the decoded PCM
    // without replacing the device output with a fabricated completion clock.
    YlAudioRenderer(bufferBudget: bufferBudget, converter: pcm)
  }
}

@MainActor final class YlContainerOutputTests: XCTestCase {
  private func checkOutput(name: String, ext: String, format: YlSourceFormat) async throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    let prepared = try YlPreparedFallback(source: .init(uri: url.absoluteString, kind: .file, formatHint: format), requireHardwareProbe: false)
    let texture = ContainerTexture(), audio = ContainerAudioFactory()
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
      #if targetEnvironment(simulator)
      if (error as? NativePlayerError)?.code == "decoder.video_hardware_unavailable" {
        throw XCTSkip("iOS Simulator has no hardware decoder for this fixture; no output acceptance.")
      }
      #endif
      throw error
    }
    let backend = try XCTUnwrap(initial)
    defer { backend.dispose() }
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
    for expected in [[255,0,0], [0,255,0], [0,0,255], [255,255,255]] {
      XCTAssertTrue(texture.history.contains { rgb in zip(rgb, expected).allSatisfy { abs($0 - $1) < 24 } }, "Missing displayed marker \(expected), observed=\(Set(texture.history))")
    }
    for second in 0..<4 {
      audio.pcm.verifyTone(start: Int64(second) * 1_000_000 + 250_000,
        end: Int64(second) * 1_000_000 + 750_000, expected: Double(440 + second * 220))
    }
    for (target, rgb, tone): (Int64, [Int], Double) in [(1250,[0,255,0],660), (2250,[0,0,255],880), (0,[255,0,0],440)] {
      try backend.pause(); audio.pcm.clearEvidence(); texture.history.removeAll()
      try await Task.detached { try backend.seek(toMs: target, cancellationToken: nil) }.value
      try backend.play()
      try await advance(until: { (state?.positionMs ?? 0) >= target + 450 && !texture.history.isEmpty })
      XCTAssertTrue(texture.history.contains { value in zip(value,rgb).allSatisfy { abs($0 - $1) < 24 } }, "seek=\(target), observed=\(Set(texture.history))")
      audio.pcm.verifyTone(start: target * 1000 + 100_000, end: target * 1000 + 400_000, expected: tone)
    }
    backend.stop(); backend.dispose(); backend.dispose()
  }
  func testProgramStreamActualPixelsPCMAndBidirectionalSeek() async throws {
    do { try await checkOutput(name: "p03-ps-avc-mp3", ext: "mpg", format: .mpegPs) }
    catch let error as NativePlayerError { XCTFail("PS: \(error.code): \(error.message)") }
  }
  func testNonzeroVorbisDelayActualPixelsPCMAndBidirectionalSeek() async throws {
    do { try await checkOutput(name: "p03-webm-vp9-vorbis", ext: "webm", format: .webm) }
    catch let error as NativePlayerError { XCTFail("Vorbis: \(error.code): \(error.message)") }
  }
}
