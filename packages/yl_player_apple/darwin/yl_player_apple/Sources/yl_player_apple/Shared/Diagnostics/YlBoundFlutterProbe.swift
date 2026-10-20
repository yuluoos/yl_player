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

/// Binds the actual public source to the owned fixture, transport and run.
enum YlBoundSourceIdentity {
  static func matches(_ source: AppleSourceMessage, path: String, locator: String,
                      transport: String, run: String) -> Bool {
    guard source.drm == nil && source.locator == locator else { return false }
    if transport == "file" { return source.kind == .file && locator == path }
    guard transport == "http", source.kind == .network, source.networkPolicy?.kind == .managed,
      source.request?.headers["x-yl-bound-run"] == run,
      let url = URLComponents(string: locator) else { return false }
    return url.scheme == "http" && url.host == "127.0.0.1" && (url.port ?? 0) > 0 &&
      url.user == nil && url.password == nil && url.query == nil && url.fragment == nil &&
      url.path == "/" + URL(fileURLWithPath: path).lastPathComponent
  }
}

/// Temporarily stops an already-paused clear surface's renderer clock for readback.
/// The immediate renderer otherwise retains a host-clock rate of one even when
/// the public player is paused. No frame, surface, or media timestamp is replaced.
final class YlBoundDisplayReadback {
  let layer: AVSampleBufferDisplayLayer
  private let original: CMTimebase?
  private let frozen: CMTimebase
  private var active = true
  init(layer: AVSampleBufferDisplayLayer) throws {
    precondition(Thread.isMainThread)
    guard #available(macOS 14.4, iOS 17.4, *) else {
      throw NSError(domain: "P03BoundAV", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Renderer clock readback is unavailable"])
    }
    guard layer.isReadyForDisplay else {
      throw NSError(domain: "P03BoundAV", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Wait for the first displayed frame before freezing"])
    }
    self.layer = layer
    original = layer.controlTimebase
    if let original, CMTimebaseGetEffectiveRate(original) != 0 {
      throw NSError(domain: "P03BoundAV", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Readback requires a paused presentation timeline"])
    }
    var created: CMTimebase?
    let result = CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(), timebaseOut: &created)
    guard result == noErr, let created else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
    frozen = created
    let time = CMTimebaseGetTime(original ?? layer.sampleBufferRenderer.timebase)
    let status = CMTimebaseSetTime(frozen, time: time)
    guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    layer.controlTimebase = frozen // A new timebase starts stopped, at the same time.
  }
  /// Freezes the owned host clock again after the next public pause.
  func freeze() throws {
    precondition(Thread.isMainThread)
    if active { return }
    guard layer.controlTimebase === (original ?? frozen) else {
      throw NSError(domain: "P03BoundAV", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Display clock ownership changed"])
    }
    if let original, CMTimebaseGetEffectiveRate(original) != 0 {
      throw NSError(domain: "P03BoundAV", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Readback requires a paused presentation timeline"])
    }
    guard CMTimebaseSetRate(frozen, rate: 0) == noErr,
      CMTimebaseSetTime(frozen, time: original.map(CMTimebaseGetTime)
        ?? CMClockGetTime(CMClockGetHostTimeClock())) == noErr else {
      throw NSError(domain: "P03BoundAV", code: 3)
    }
    layer.controlTimebase = frozen
    active = true
  }
  /// Reads the owned surface only at actual rate zero. An unavailable image lets
  /// queued presentation progress between retries, without resuming player/audio.
  /// Readiness alone does not prove the first image has reached the display target.
  @available(macOS 14.4, iOS 17.4, *)
  func pixelBuffer() throws -> CVPixelBuffer? {
    var pixel: CVPixelBuffer?
    if layer.isReadyForDisplay {
      try freeze()
      // Allow an asynchronous stop to settle before attempting a read.
      guard CMTimebaseGetEffectiveRate(layer.sampleBufferRenderer.timebase) == 0 else { return nil }
      pixel = layer.sampleBufferRenderer.displayedPixelBuffer()
    }
    if pixel == nil && !restore() {
      throw NSError(domain: "P03BoundAV", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Display clock ownership changed during recovery"])
    }
    return pixel
  }
  /// Returns the original custom clock, or restores explicit host-clock semantics.
  /// Clearing a temporary clock to nil leaves AVFoundation's renderer stopped.
  /// For an originally implicit host clock, retain the owned clock at rate one
  /// until this acceptance surface is disposed. Never replace another owner's clock.
  @discardableResult func restore() -> Bool {
    precondition(Thread.isMainThread)
    if !active { return layer.controlTimebase === (original ?? frozen) }
    guard layer.controlTimebase === frozen else { return false }
    if let original {
      layer.controlTimebase = original
    } else {
      guard CMTimebaseSetTime(frozen, time: CMClockGetTime(CMClockGetHostTimeClock())) == noErr,
        CMTimebaseSetRate(frozen, rate: 1) == noErr else { return false }
    }
    active = false
    return true
  }
  deinit { restore() }
}

#if os(macOS)
/// Owns only the acceptance app's window settings for a bounded GUI run.
final class YlBoundWindowVisibility {
  let window: NSWindow
  private let frame: NSRect
  private let minimum: NSSize
  private let level: NSWindow.Level
  private let behavior: NSWindow.CollectionBehavior
  private let autosave: NSWindow.FrameAutosaveName
  private let wasVisible: Bool
  private var restored = false
  init(window: NSWindow) {
    precondition(Thread.isMainThread)
    self.window = window; frame = window.frame; minimum = window.minSize
    level = window.level; behavior = window.collectionBehavior
    autosave = window.frameAutosaveName; wasVisible = window.isVisible
    window.setFrameAutosaveName("") // Do not persist acceptance-only geometry.
    window.minSize = .zero
    window.setContentSize(NSSize(width: 400, height: 260))
    var visibleBehavior = behavior.subtracting([.moveToActiveSpace, .fullScreenPrimary, .fullScreenNone])
    visibleBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
    if #available(macOS 13.0, *) {
      visibleBehavior.subtract([.primary, .auxiliary])
      visibleBehavior.insert(.canJoinAllApplications)
    }
    window.collectionBehavior = visibleBehavior
    window.level = .floating
    if let screen = window.screen ?? NSScreen.main {
      let available = screen.visibleFrame
      window.setFrameOrigin(NSPoint(x: max(available.minX, available.maxX - window.frame.width - 24),
        y: max(available.minY, available.maxY - window.frame.height - 24)))
    }
    window.orderFrontRegardless() // Keep the user's active app/Space unchanged.
  }
  var isVisible: Bool {
    window.isVisible && !window.isMiniaturized && window.isOnActiveSpace &&
      window.occlusionState.contains(.visible) && !NSApplication.shared.isHidden
  }
  /// Restores this window only; no activation, Space switch, or other app control.
  func restore() {
    precondition(Thread.isMainThread)
    guard !restored else { return }; restored = true
    window.level = level; window.collectionBehavior = behavior
    window.setFrame(frame, display: true); window.minSize = minimum
    window.setFrameAutosaveName(autosave)
    if !wasVisible { window.orderOut(nil) }
  }
  deinit { restore() }
}
#endif

/// Explicit acceptance-build observer. Public Flutter commands own all playback;
/// this bridge never creates a player, swaps a surface, or admits a decoder.
/// Paused pixel sampling temporarily controls the same layer clock and restores
/// it before public playback resumes; this is a controlled snapshot protocol.
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
  #if os(macOS)
  private var windowVisibility: YlBoundWindowVisibility?
  #endif
  private let channel: FlutterMethodChannel
  #if os(macOS)
  private let platform = "macos"
  #else
  private let platform = "ios"
  #endif

  static func register(messenger: FlutterBinaryMessenger) {
    let encoded: String
    do {
      guard let input = try YlBoundLaunchPlan.consume(environment: ProcessInfo.processInfo.environment,
        directory: FileManager.default.temporaryDirectory) else { return }
      encoded = input
    } catch { print("YL_BOUND_PLAN_INVALID"); return }
    let probe = YlBoundFlutterProbe(messenger: messenger, encoded: encoded)
    current = probe

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
    #if os(macOS)
    defer { windowVisibility?.restore() }
    #endif
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
  /// Observe the already chosen AVPlayer route; never select a different backend.
  func observeAvPlayer(_ player: AVPlayer, item: AVPlayerItem) -> YlBoundAvPlayerAudio? {
    guard identityVerified, let capture, capture.sourceVerified else { return nil }
    let observer = YlBoundAvPlayerAudio(player: player, item: item)
    capture.avAudio = observer
    return observer
  }
  func observe(_ host: YlApplePlayerHost) { if capture?.host == nil { capture?.host = host } }
  func verifySource(_ source: AppleSourceMessage, host: YlApplePlayerHost) throws {
    guard let capture else { throw error("unplanned public load") }
    try require(capture.host === host && YlBoundSourceIdentity.matches(source, path: capture.path, locator: capture.locator, transport: capture.item["transport"] as? String ?? "file", run: plan["runId"] as? String ?? ""), "actual source/session mismatch")
    try require(try Self.fileHash(URL(fileURLWithPath: capture.path)) == capture.item["mediaHash"] as? String, "actual media hash mismatch")
    capture.sourceVerified = true
  }

  /// Main-thread readback of the display layer attached by the product output.
  /// No process-wide view search and no decoder callback can satisfy this probe.
  static func displayedPixel(in container: CALayer?) -> CVPixelBuffer? {
    guard Thread.isMainThread, let container, container.bounds.width > 0, container.bounds.height > 0 else {
      current?.readbackState = "missing/empty container: \(String(describing: container?.bounds))"
      return nil
    }
    #if os(macOS)
    guard current?.windowVisibility?.isVisible == true else {
      _ = current?.capture?.readback?.restore()
      current?.readbackState = "acceptance window is not visible on the active Space"
      return nil
    }
    #endif
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
    guard let capture = current?.capture else { return nil }
    guard layer.isReadyForDisplay || capture.readback?.layer === layer else {
      current?.readbackState = "waiting for first display: \(ObjectIdentifier(layer))"
      return nil
    }
    if capture.readback?.layer !== layer {
      guard capture.readback?.restore() != false else { return nil }
      do { capture.readback = try YlBoundDisplayReadback(layer: layer) }
      catch { current?.readbackState = "readback clock: \(error)"; return nil }
    }
    let pixel: CVPixelBuffer?
    do { pixel = try capture.readback?.pixelBuffer() }
    catch { current?.readbackState = "readback clock: \(error)"; return nil }
    let rate = CMTimebaseGetEffectiveRate(layer.sampleBufferRenderer.timebase)
    current?.readbackState = "layer=\(ObjectIdentifier(layer)) control=\(layer.controlTimebase != nil) rate=\(rate) effectiveRate=\(CMTimebaseGetEffectiveRate(layer.sampleBufferRenderer.timebase)) ready=\(layer.isReadyForDisplay) status=\(layer.status.rawValue) pixel=\(pixel != nil) bounds=\(layer.bounds) error=\(String(describing: layer.error))"
    #if os(macOS)
    let windows = NSApplication.shared.windows.map {
      "\($0.windowNumber):visible=\($0.isVisible),occlusion=\($0.occlusionState.contains(.visible)),mini=\($0.isMiniaturized),space=\($0.isOnActiveSpace),level=\($0.level.rawValue)"
    }.joined(separator: ";")
    current?.readbackState += " appActive=\(NSApplication.shared.isActive) hidden=\(NSApplication.shared.isHidden) windows=\(windows)"
    #endif
    return pixel
  }
  private func handle(_ call: FlutterMethodCall, reply: @escaping FlutterResult) throws {
    precondition(Thread.isMainThread)
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "plan" {
      #if os(macOS)
      if windowVisibility == nil {
        let windows = NSApplication.shared.windows.filter { $0.contentViewController is FlutterViewController }
        try require(windows.count == 1, "expected one owned Flutter acceptance window")
        windowVisibility = YlBoundWindowVisibility(window: windows[0])
      }
      #endif
      reply(plan); return
    }
    if call.method == "begin" {
      let planned = plan["planned"] as? [[String: Any]] ?? []
      try require(capture == nil && rows.count < planned.count, "unexpected begin")
      let item = planned[rows.count]
      guard let path = args["path"] as? String else { throw error("missing media path") }
      try require(args["caseId"] as? String == item["caseId"] as? String, "case order changed")
      try require(try Self.fileHash(URL(fileURLWithPath: path)) == item["mediaHash"] as? String, "fixture hash mismatch")
      capture = Capture(item: item, path: path, locator: args["locator"] as? String ?? path); reply(nil); return
    }
    guard let c = capture else { throw error("native capture missing") }
    let host = c.host
    let session = args["sessionId"] as? String
    if call.method == "bind" {
      try require(session != nil && session == host?.sessionId, "public/native identity mismatch")
      c.session = session!; reply(nil); return
    }
    try require(session == c.session && !c.session.isEmpty, "stale public session")
    switch call.method {
    case "observationKind":
      reply(c.avAudio == nil ? "rendererConsumption" : "avplayerSourcePull")
    case "releaseReady":
      // The observer must stop owning the host after actual public disposal.
      // Otherwise its coordinator keeps AVPlayer alive and prevents tap finalize.
      if host?.disposed == true { c.nativeDisposed = true; c.host = nil }
      reply(c.nativeDisposed && (c.avAudio?.released ?? (c.factory?.renderer?.scheduledBytes == 0)))
    case "endReadback":
      try require(c.readback?.restore() != false, "display clock ownership changed during readback")
      reply(nil)
    case "diagnostics":
      var details = origin(c)
      details.merge(["phase": c.phase, "state": String(describing: host?.initialState),
        "clock": c.avAudio?.diagnostic ?? c.factory?.diagnosticClock ?? "no renderer", "pixels": c.pixels,
        "readback": readbackState,
        "readbackTrace": c.readbackTrace,
        "pcmBlocks": c.avAudio?.evidence.count ?? c.factory?.pcm.evidence.count ?? 0, "phases": c.phases, "stamp": c.factory?.stamp ?? "none"]) { _, rhs in rhs }
      try write("unfinished.json", details)
      reply(details)
    case "consumptionReady":
      let ready = c.avAudio?.ready ?? (c.factory?.consumptionReady(completed: host?.initialState.status == .completed) == true)
      if !ready && c.readbackTrace.count < 100 {
        c.readbackTrace.append(["waitingForConsumption": c.factory?.diagnosticClock ?? "missing",
          "hostStatus": String(describing: host?.initialState.status)])
      }
      reply(ready)
    case "capture":
      try require(c.avAudio != nil || host?.initialState.status == .paused || host?.initialState.status == .completed,
        "readback requires public pause/completion")
      let pull = c.avAudio?.currentPull
      guard let clock = c.avAudio == nil ? c.factory?.clock() : pull?["pullStartUs"] as? Int64 else {
        if c.readbackTrace.count < 100 {
          c.readbackTrace.append(["clockUnavailable": c.factory?.diagnosticClock ?? "missing", "hostStatus": String(describing: host?.initialState.status)])
        }
        reply(nil); return
      }
      let before = ProcessInfo.processInfo.systemUptime
      let pixel: CVPixelBuffer?
      #if os(macOS)
      pixel = (c.output as? YlMacosTextureOutput)?.boundDisplayedPixelBuffer()
      #else
      pixel = (c.output as? YlIosTextureOutput)?.boundDisplayedPixelBuffer()
      #endif
      if c.readbackTrace.count < 100 {
        c.readbackTrace.append(["clock": clock, "hostStatus": String(describing: host?.initialState.status), "readback": readbackState])
      }
      if let pixel, c.pixels.count < 1000, ProcessInfo.processInfo.systemUptime - before <= 0.2 {
        let image = CIImage(cvPixelBuffer: pixel)
        var rgba = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &rgba, rowBytes: 4,
          bounds: CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        var observed: [String: Any] = ["value": rgba.prefix(3).map(Int.init), "format": "rgb8", "audioClockUs": clock, "displayRate": 0,
          "hostTimeUs": Int64(before * 1_000_000)]
        #if os(macOS)
        observed["windowVisible"] = windowVisibility?.isVisible == true
        #endif
        if let pull { observed.merge(pull) { _, rhs in rhs } }
        c.pixels.append(observed)
        c.viewAttached = true
        reply(clock); return
      }
      reply(nil)
    case "seekPhase":
      let target = (args["targetMs"] as? NSNumber)?.intValue ?? -1
      let phases = plan["phases"] as? [[String: Any]] ?? []
      try require(c.phases.count < phases.count && phases[c.phases.count]["phase"] as? String == "seek-\(target)", "seek order changed")
      c.phase = "seek-\(target)"; c.pixels.removeAll(); c.readbackTrace.removeAll()
      c.beforeSeek = c.avAudio.map { String($0.epoch) } ?? c.factory?.stamp; c.factory?.pcm.clear(); reply(nil)
    case "awaitPhase":
      // Public network seek acknowledges intent before its worker commits reset.
      // The Dart observer polls this actual generation effect with a deadline.
      reply(c.beforeSeek != nil && (c.avAudio.map { String($0.epoch) } ?? c.factory?.stamp) != c.beforeSeek)
    case "retain":
      try require(args["phase"] as? String == c.phase, "phase mismatch")
      if c.phase == "play" { c.completed = host?.initialState.status == .completed }
      c.phases.append(capturePhase(c)); reply(nil)
    case "finishCase":
      let lifecycle = args["lifecycle"] as? [String: Bool] ?? [:]
      try require(c.nativeDisposed && c.completed && (c.avAudio?.released ?? (c.factory?.renderer?.scheduledBytes == 0)), "native completion/release missing")
      try require(["created", "ready", "firstFrame", "completed", "disposed"].allSatisfy { lifecycle[$0] == true }, "public lifecycle missing")
      var row = origin(c)
      row.merge(["schema": 1, "platform": platform, "testSha256": plan["testSha256"]!,
        "caseId": c.item["caseId"]!, "mediaHash": c.item["mediaHash"]!, "identityVerified": identityVerified,
        "loadedImages": loadedImages, "outcome": "passed", "completed": c.completed, "disposed": c.nativeDisposed,
        "releasedAudioBytes": c.factory?.renderer?.scheduledBytes ?? 0, "phases": c.phases,
        "publicSessionId": c.session, "publicApi": "YlPlayerController/YlPlayerView", "publicLifecycle": lifecycle,
        "pixelSource": "flutter-native-view-display-layer", "nativeViewAttached": c.viewAttached]) { _, rhs in rhs }
      row["transport"] = c.item["transport"] ?? "file"
      row["sourceVerified"] = c.sourceVerified
      if c.item["transport"] as? String == "http" {
        row["networkPolicy"] = "managed"; row["networkReceipt"] = args["networkReceipt"]
      }
      row["audioClockMethod"] = c.avAudio == nil ? "renderer-paused-consumption" : "avplayer-preeffects-source-pull"
      if let av = c.avAudio {
        row["audioEvidenceBoundary"] = "audio-queue-source-pull"
        row["audioReadbackProtocol"] = "continuous-source-pull-v1"
        row["avPlayerTapReleased"] = av.released
        row.removeValue(forKey: "releasedAudioBytes")
      }
      row["displayReadbackProtocol"] = "paused-layer-timebase-v1"
      #if os(macOS)
      row["windowVisibilityMethod"] = "owned-all-spaces-window-v1"
      #endif
      rows.append(row); capture = nil; try write("rows.json", rows); reply(nil)
    default: reply(FlutterMethodNotImplemented)
    }
  }
  private func origin(_ c: Capture) -> [String: Any] { ["runId": plan["runId"]!, "sessionId": c.session, "buildSha256": plan["buildSha256"]!] }
  private func capturePhase(_ c: Capture) -> [String: Any] {
    let phases = plan["phases"] as? [[String: Any]] ?? []
    let markers = phases.first { $0["phase"] as? String == c.phase }?["markers"] as? [Int] ?? []
    var windows = [[String: Any]]()
    let blocks = c.avAudio?.evidence.map { BoundPCM.Block(pts: $0.pts, rate: $0.rate, samples: $0.samples, sourceStepUs: Double($0.end - $0.pts) / Double($0.samples.first?.count ?? 1)) } ?? c.factory?.pcm.evidence ?? []
    for marker in markers {
      let start = c.phase == "play" ? Int64(marker) * 1_000_000 + 250_000 : (Int64(c.phase.dropFirst(5)) ?? -1) * 1000 + 100_000
      var samples = [Float](), first: Int64?, channels = 0, rate = 0
      var lastPTS: Int64 = -1
      for row in blocks {
        channels = row.samples.count; rate = Int(row.rate)
        for frame in 0..<(row.samples.first?.count ?? 0) {
          let pts = row.pts + (row.sourceStepUs.map { Int64(Double(frame) * $0) }
            ?? Int64(Double(frame) * 1_000_000 / row.rate))
          if pts >= start && (c.avAudio == nil || pts > lastPTS) && pts < start + 500_000 && samples.count < 8192 * channels {
            lastPTS = pts
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
    var row = origin(c); row.merge(["phase": c.phase, "pixels": c.pixels, "pcmWindows": windows,
      "readbackTrace": c.readbackTrace]) { _, rhs in rhs }
    if let av = c.avAudio { row["tapEpoch"] = av.epoch; row["tapDiagnostic"] = av.diagnostic }
    return row
  }
  private final class Capture {
    let item: [String: Any]; let path: String; let locator: String
    var sourceVerified = false
    var nativeDisposed = false
    var avAudio: YlBoundAvPlayerAudio?
    var factory: BoundAudioFactory?; var output: YlTextureOutput?; var host: YlApplePlayerHost?
    var session = "", phase = "play", completed = false, viewAttached = false
    var beforeSeek: String?
    var pixels = [[String: Any]](), phases = [[String: Any]]()
    var readbackTrace = [[String: Any]]()
    var readback: YlBoundDisplayReadback?
    init(item: [String: Any], path: String, locator: String) { self.item = item; self.path = path; self.locator = locator }
  }
}

/// Decorates the actual converter, retaining post-trim samples without replacing
/// AVAudioEngine output or its consumed-sample clock. Each reset drops old PCM.
private final class BoundPCM: YlAudioPacketConverting {
  struct Block { let pts: Int64; let rate: Double; let samples: [[Float]]; var sourceStepUs: Double? = nil }
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
  /// Eligibility only: observe real output consumption before public pause.
  /// Never freeze a newly reset/unstarted renderer or use this running sample
  /// as paired pixel evidence; capture() reads its later paused clock separately.
  func consumptionReady(completed: Bool) -> Bool {
    guard let renderer else { return false }
    switch renderer.clockObservation(expectedGeneration: pcm.generation) {
    case .running, .ended: return true
    case .paused: return completed
    default: return false
    }
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
