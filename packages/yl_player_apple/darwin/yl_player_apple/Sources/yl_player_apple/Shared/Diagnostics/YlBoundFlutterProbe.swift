#if DEBUG && YL_BOUND_AV
import AVFoundation
import CoreImage
import CryptoKit
import MachO
#if os(macOS)
import AppKit
import FlutterMacOS
#else
import Flutter
#endif

/// Explicit acceptance-build observer. Public Flutter commands own all playback;
/// this bridge never creates a player, swaps a surface, or admits a decoder.
final class YlBoundFlutterProbe {
  static var current: YlBoundFlutterProbe?
  private var plan: [String: Any] = [:]
  private var directory: URL?
  private var failure: String?
  private var identityVerified = false
  private var loadedImages = [[String: String]]()
  private var rows = [[String: Any]]()
  private var capture: Capture?
  private var readbackState = "not sampled"
  private let context = CIContext(options: [.cacheIntermediates: false,
    .workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
  private let channel: FlutterMethodChannel
  #if os(macOS)
  private let platform = "macos"
  #else
  private let platform = "ios"
  #endif

  static func register(messenger: FlutterBinaryMessenger) {
    guard let encoded = ProcessInfo.processInfo.environment["YL_P03_BOUND_PLAN"] else { return }
    let probe = YlBoundFlutterProbe(messenger: messenger, encoded: encoded)
    current = probe
    #if os(macOS)
    if probe.identityVerified {
      // A GUI output acceptance run needs the actual test window visible.
      // Activate only this process; never inspect or control another app.
      DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }
    #endif
  }
  private init(messenger: FlutterBinaryMessenger, encoded: String) {
    channel = FlutterMethodChannel(name: "yl_player_example/debug/bound_av", binaryMessenger: messenger)
    do {
      guard let data = Data(base64Encoded: encoded),
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let run = value["runId"] as? String, UUID(uuidString: run) != nil else { throw error("invalid plan") }
      plan = value
      let target = FileManager.default.temporaryDirectory.appendingPathComponent("p03-public-" + run)
      try require(!FileManager.default.fileExists(atPath: target.path), "run directory exists")
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
      directory = target
      print("YL_BOUND_RESULT=" + target.path); fflush(stdout)
      try require(value["platform"] as? String == platform && value["artifactKind"] as? String == "apple-public-flutter-debug-app", "platform/artifact mismatch")
      try verifyProduct(); identityVerified = true
    } catch { failure = String(describing: error); try? writeStatus(passed: false) }
    channel.setMethodCallHandler { [weak self] call, reply in
      guard let self else { return }
      do {
        if call.method == "finish" {
          let args = call.arguments as? [String: Any] ?? [:]
          if let message = args["failure"] as? String { self.failure = message }
          try self.writeStatus(passed: args["passed"] as? Bool == true); reply(nil); return
        }
        try self.require(self.identityVerified && self.failure == nil, self.failure ?? "identity unverified")
        try self.handle(call, reply: reply)
      } catch { reply(FlutterError(code: "bound.av", message: String(describing: error), details: nil)) }
    }
  }
  private func error(_ reason: String) -> NSError { NSError(domain: "P03BoundAV", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
  private func require(_ condition: Bool, _ reason: String) throws { if !condition { throw error(reason) } }
  static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  static func fileHash(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1 << 20), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  private func verifyProduct() throws {
    guard let encoded = plan["productManifest"] as? String, let data = Data(base64Encoded: encoded),
      let files = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw error("manifest missing") }
    try require(Self.digest(data) == plan["buildSha256"] as? String && plan["testSha256"] as? String == plan["buildSha256"] as? String, "manifest identity mismatch")
    var allowed = Set<String>()
    for file in files {
      guard let path = file["path"] as? String, let sha = file["sha256"] as? String else { throw error("invalid manifest entry") }
      try require(!path.hasPrefix("/") && !path.split(separator: "/").contains(".."), "invalid manifest path")
      try require(try Self.fileHash(Bundle.main.bundleURL.appendingPathComponent(path)) == sha, "installed product changed: " + path)
      allowed.insert(sha)
    }
    loadedImages.removeAll()
    for index in 0..<_dyld_image_count() {
      guard let pointer = _dyld_get_image_name(index) else { continue }
      let path = String(cString: pointer)
      guard path.hasPrefix(Bundle.main.bundleURL.path + "/") || path.contains("YlFFmpegBridge.framework/") || path.contains("yl_player_apple") else { continue }
      let sha = try Self.fileHash(URL(fileURLWithPath: path))
      try require(allowed.contains(sha), "loaded image outside frozen product: " + path)
      loadedImages.append(["image": URL(fileURLWithPath: path).lastPathComponent, "sha256": sha])
    }
    try require(loadedImages.contains { $0["image"] == "YlFFmpegBridge" }, "loaded bridge missing")
  }
  private func write(_ name: String, _ value: Any) throws {
    guard let directory else { throw error("no output directory") }
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: directory.appendingPathComponent(name), options: .atomic)
  }
  private func writeStatus(passed: Bool) throws {
    var stable = false
    if identityVerified { do { try verifyProduct(); stable = true } catch { failure = String(describing: error) } }
    try write("rows.json", rows)
    try write("status.json", ["passed": passed && failure == nil && rows.count == (plan["planned"] as? [Any])?.count && capture == nil && stable,
      "identityVerified": identityVerified, "artifactsUnchanged": stable, "failure": failure ?? "", "runId": plan["runId"] ?? ""])
  }

  func makeAudioFactory(output: YlTextureOutput) -> YlAudioRendererMaking? {
    guard identityVerified, let capture, capture.factory == nil else { return nil }
    let factory = BoundAudioFactory(); capture.factory = factory; capture.output = output
    return factory
  }
  func observe(_ host: YlApplePlayerHost) { if capture?.host == nil { capture?.host = host } }
  func verifySource(_ source: AppleSourceMessage, host: YlApplePlayerHost) throws {
    guard let capture else { throw error("unplanned public load") }
    try require(capture.host === host && source.kind == .file && source.drm == nil && source.locator == capture.path, "actual source/session mismatch")
    try require(try Self.fileHash(URL(fileURLWithPath: source.locator)) == capture.item["mediaHash"] as? String, "actual media hash mismatch")
  }

  /// Main-thread readback of the display layer attached by the product output.
  /// No process-wide view search and no decoder callback can satisfy this probe.
  static func displayedPixel(in container: CALayer?) -> CVPixelBuffer? {
    guard Thread.isMainThread, let container, container.bounds.width > 0, container.bounds.height > 0 else {
      current?.readbackState = "missing/empty container: \(String(describing: container?.bounds))"
      return nil
    }
    guard #available(macOS 14.4, iOS 17.4, *) else { return nil }
    var layers = [AVSampleBufferDisplayLayer]()
    func visit(_ layer: CALayer) {
      if let display = layer as? AVSampleBufferDisplayLayer { layers.append(display) }
      for child in layer.sublayers ?? [] { visit(child) }
    }
    visit(container)
    guard layers.count == 1, let layer = layers.first else {
      current?.readbackState = "display layer count: \(layers.count)"
      return nil
    }
    let rate = layer.controlTimebase.map { CMTimebaseGetRate($0) } ?? 0
    let pixel = layer.isReadyForDisplay && rate == 0 ? layer.sampleBufferRenderer.displayedPixelBuffer() : nil
    current?.readbackState = "rate=\(rate) ready=\(layer.isReadyForDisplay) status=\(layer.status.rawValue) pixel=\(pixel != nil) bounds=\(layer.bounds) error=\(String(describing: layer.error))"
    return pixel
  }
  private func handle(_ call: FlutterMethodCall, reply: @escaping FlutterResult) throws {
    precondition(Thread.isMainThread)
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "plan" { reply(plan); return }
    if call.method == "begin" {
      let planned = plan["planned"] as? [[String: Any]] ?? []
      try require(capture == nil && rows.count < planned.count, "unexpected begin")
      let item = planned[rows.count]
      guard let path = args["path"] as? String else { throw error("missing media path") }
      try require(args["caseId"] as? String == item["caseId"] as? String, "case order changed")
      try require(try Self.fileHash(URL(fileURLWithPath: path)) == item["mediaHash"] as? String, "fixture hash mismatch")
      capture = Capture(item: item, path: path); reply(nil); return
    }
    guard let c = capture, let host = c.host else { throw error("native host missing") }
    let session = args["sessionId"] as? String
    if call.method == "bind" {
      try require(session != nil && session == host.sessionId, "public/native identity mismatch")
      c.session = session!; reply(nil); return
    }
    try require(session == c.session && !c.session.isEmpty, "stale public session")
    switch call.method {
    case "diagnostics":
      var details = origin(c)
      details.merge(["phase": c.phase, "state": String(describing: host.initialState),
        "clock": c.factory?.diagnosticClock ?? "no renderer", "pixels": c.pixels,
        "readback": readbackState,
        "pcmBlocks": c.factory?.pcm.evidence.count ?? 0, "stamp": c.factory?.stamp ?? "none"]) { _, rhs in rhs }
      try write("unfinished.json", details)
      reply(details)
    case "capture":
      guard let audio = c.factory, let clock = audio.clock() else { reply(nil); return }
      let before = ProcessInfo.processInfo.systemUptime
      let pixel: CVPixelBuffer?
      #if os(macOS)
      pixel = (c.output as? YlMacosTextureOutput)?.boundDisplayedPixelBuffer()
      #else
      pixel = (c.output as? YlIosTextureOutput)?.boundDisplayedPixelBuffer()
      #endif
      if let pixel, c.pixels.count < 1000, ProcessInfo.processInfo.systemUptime - before <= 0.2 {
        let image = CIImage(cvPixelBuffer: pixel)
        var rgba = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &rgba, rowBytes: 4,
          bounds: CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        c.pixels.append(["value": rgba.prefix(3).map(Int.init), "format": "rgb8", "audioClockUs": clock,
          "hostTimeUs": Int64(before * 1_000_000)])
        c.viewAttached = true
        reply(clock); return
      }
      reply(nil)
    case "seekPhase":
      let target = (args["targetMs"] as? NSNumber)?.intValue ?? -1
      let phases = plan["phases"] as? [[String: Any]] ?? []
      try require(c.phases.count < phases.count && phases[c.phases.count]["phase"] as? String == "seek-\(target)", "seek order changed")
      c.phase = "seek-\(target)"; c.pixels.removeAll()
      c.beforeSeek = c.factory?.stamp; c.factory?.pcm.clear(); reply(nil)
    case "awaitPhase":
      try require(c.beforeSeek != nil && c.factory?.stamp != c.beforeSeek, "actual audio reset not observed")
      reply(nil)
    case "retain":
      try require(args["phase"] as? String == c.phase, "phase mismatch")
      if c.phase == "play" { c.completed = host.initialState.status == .completed }
      c.phases.append(capturePhase(c)); reply(nil)
    case "finishCase":
      let lifecycle = args["lifecycle"] as? [String: Bool] ?? [:]
      try require(host.disposed && c.completed && c.factory?.renderer?.scheduledBytes == 0, "native completion/release missing")
      try require(["created", "ready", "firstFrame", "completed", "disposed"].allSatisfy { lifecycle[$0] == true }, "public lifecycle missing")
      var row = origin(c)
      row.merge(["schema": 1, "platform": platform, "testSha256": plan["testSha256"]!,
        "caseId": c.item["caseId"]!, "mediaHash": c.item["mediaHash"]!, "identityVerified": identityVerified,
        "loadedImages": loadedImages, "outcome": "passed", "completed": c.completed, "disposed": host.disposed,
        "releasedAudioBytes": c.factory!.renderer!.scheduledBytes, "phases": c.phases,
        "publicSessionId": c.session, "publicApi": "YlPlayerController/YlPlayerView", "publicLifecycle": lifecycle,
        "pixelSource": "flutter-native-view-display-layer", "nativeViewAttached": c.viewAttached]) { _, rhs in rhs }
      row["audioClockMethod"] = "renderer-paused-consumption"
      rows.append(row); capture = nil; try write("rows.json", rows); reply(nil)
    default: reply(FlutterMethodNotImplemented)
    }
  }
  private func origin(_ c: Capture) -> [String: Any] { ["runId": plan["runId"]!, "sessionId": c.session, "buildSha256": plan["buildSha256"]!] }
  private func capturePhase(_ c: Capture) -> [String: Any] {
    let phases = plan["phases"] as? [[String: Any]] ?? []
    let markers = phases.first { $0["phase"] as? String == c.phase }?["markers"] as? [Int] ?? []
    var windows = [[String: Any]]()
    for marker in markers {
      let start = c.phase == "play" ? Int64(marker) * 1_000_000 + 250_000 : (Int64(c.phase.dropFirst(5)) ?? -1) * 1000 + 100_000
      var samples = [Float](), first: Int64?, channels = 0, rate = 0
      for row in c.factory?.pcm.evidence ?? [] {
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
      var window = origin(c)
      window.merge(["phase": c.phase, "marker": marker, "rate": rate, "channels": channels, "startUs": first ?? -1,
        "frames": channels > 0 ? samples.count / channels : 0, "pcmF32LE": raw.base64EncodedString(), "pcmSha256": Self.digest(raw)]) { _, rhs in rhs }
      windows.append(window)
    }
    var row = origin(c); row.merge(["phase": c.phase, "pixels": c.pixels, "pcmWindows": windows]) { _, rhs in rhs }; return row
  }
  private final class Capture {
    let item: [String: Any]; let path: String
    var factory: BoundAudioFactory?; var output: YlTextureOutput?; var host: YlApplePlayerHost?
    var session = "", phase = "play", completed = false, viewAttached = false
    var beforeSeek: String?
    var pixels = [[String: Any]](), phases = [[String: Any]]()
    init(item: [String: Any], path: String) { self.item = item; self.path = path }
  }
}

/// Decorates the actual converter, retaining post-trim samples without replacing
/// AVAudioEngine output or its consumed-sample clock. Each reset drops old PCM.
private final class BoundPCM: YlAudioPacketConverting {
  struct Block { let pts: Int64; let rate: Double; let samples: [[Float]] }
  private let converter = YlAppleCompressedAudioConverter()
  private let expectedScope: YlManagedBufferScope?
  init(scope: YlManagedBufferScope? = nil) {
    expectedScope = scope
    // Renderer injects the scope only into its concrete default converter.
    // A decorator must forward the same scope to preserve all reservations.
    converter.bufferScope = scope
  }
  var pcmFormat: AVAudioFormat? { converter.pcmFormat }
  var reservesOutputBuffers: Bool { converter.reservesOutputBuffers }
  private let lock = NSLock()
  private var blocks = [Block](), epoch = 0
  private var lastGeneration: UInt64 = 0
  var generation: UInt64 { lock.withLock { lastGeneration } }
  var resetCount: Int { lock.withLock { epoch } }
  var evidence: [Block] { lock.withLock { blocks } }
  func clear() { lock.withLock { blocks.removeAll() } }
  func configure(stream: YlAudioStreamConfiguration) throws {
    try converter.configure(stream: stream)
    lock.withLock { epoch += 1; blocks.removeAll(); lastGeneration = stream.generation }
  }
  func estimateOutput(for packet: YlCompressedAudioPacket) -> YlAudioBufferEstimate { converter.estimateOutput(for: packet) }
  func convert(packet: YlCompressedAudioPacket) throws -> YlScheduledAudioBuffer? {
    let output = try converter.convert(packet: packet)
    if let output, expectedScope != nil, output.reservation == nil {
      throw NSError(domain: "P03BoundAV", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Observed PCM bypassed the product buffer ledger"])
    }
    if let output, let pcm = output.payload as? AVAudioPCMBuffer, let data = pcm.floatChannelData {
      let channels = Int(pcm.format.channelCount), frames = Int(pcm.frameLength)
      let samples = (0..<channels).map { channel in
        (0..<frames).map { frame in pcm.format.isInterleaved ? data[0][frame * channels + channel] : data[channel][frame] }
      }
      lock.withLock {
        lastGeneration = packet.generation
        if blocks.count < 4096 { blocks.append(.init(pts: output.ptsUs, rate: pcm.format.sampleRate, samples: samples)) }
      }
    }
    return output
  }
  func reset() { converter.reset(); lock.withLock { epoch += 1; blocks.removeAll() } }
}
private final class BoundAudioFactory: YlAudioRendererMaking {
  private(set) var pcm = BoundPCM()
  private(set) var renderer: YlAudioRenderer?
  var stamp: String { "\(ObjectIdentifier(pcm))-\(pcm.resetCount)" }
  func makeRenderer(bufferBudget: YlFallbackBufferBudget) -> YlAudioRenderer {
    pcm = BoundPCM(scope: bufferBudget.bufferScope)
    let created = YlAudioRenderer(bufferBudget: bufferBudget, converter: pcm)
    renderer = created; return created
  }
  var diagnosticClock: String {
    renderer.map { String(describing: $0.clockObservation(expectedGeneration: pcm.generation)) } ?? "missing"
  }
  func clock() -> Int64? {
    guard let renderer else { return nil }
    switch renderer.clockObservation(expectedGeneration: pcm.generation) {
    // pause() snapshots the real output node before stopping it. Readback is
    // supported only at zero render rate; never substitute a running estimate.
    case .paused(let position): return position
    case .ended(let position, _): return position
    default: return nil
    }
  }
}
#endif
