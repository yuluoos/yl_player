// Included only in the isolated qualification example, never in the plugin.
// The plugin is the same separately signed image in capture and final packaging.
@testable import yl_player_apple
import yl_player_media_core
import CoreVideo

private enum YlAV1Capture {
  // Set from FlutterPluginRegistry.valuePublished immediately after registration.
  // Reflection is confined to this diagnostic host, against its frozen SDK layout.
  static weak var plugin: NSObject?
  static let pool = YlSoftwareDecodePool(measuring: true)
  static let run = UUID().uuidString
  static var timer: Timer?
  static weak var output: YlMacosTextureOutput?
  static var decodedBeforeContinuous = 0
  static var continuousStarted = false

  static func startContinuous() {
    decodedBeforeContinuous = pool.measured!.decodedFrames
    continuousStarted = true
    print("QUAL_CONTINUOUS_START \(decodedBeforeContinuous)")
  }

  static func reportClock() {
    guard continuousStarted, let plugin,
      let players = Mirror(reflecting: plugin).descendant("registry", "players") as? [String: YlApplePlayerHost],
      let host = players.values.first,
      let coordinator = Mirror(reflecting: host).descendant("coordinator") as? YlAppleSessionCoordinator,
      let slot = Mirror(reflecting: coordinator).descendant("slot") as? YlBackendSlot,
      let session = Mirror(reflecting: slot.current).descendant("session") as? YlManagedPlaybackSession,
      let clock = session.isolatedAudioClockStatistics,
      let worker = session.timedVideoStatistics else { return }
    let values: [String: Any] = ["hostNs": DispatchTime.now().uptimeNanoseconds,
      "samples": clock.samples, "staleEvents": clock.staleEvents,
      "maximumReadSeconds": clock.maximumReadSeconds, "maximumAgeSeconds": clock.maximumAgeSeconds,
      "maximumWorkerGapSeconds": worker.maxWorkerGapSeconds]
    print("QUAL_CLOCK", String(data: try! JSONSerialization.data(withJSONObject: values,
      options: [.sortedKeys]), encoding: .utf8)!)
  }

  static func configure(_ services: inout YlPlatformServices) {
    let original = services
    services = YlPlatformServices(platform: original.platform, textureOutput: original.textureOutput,
      makeDisplayDriver: { tick in YlAV1DiagnosticDriver(make: original.makeDisplayDriver, onTick: tick) },
      activateAudioSession: original.activateAudioSession)
    services.nativeViewType = original.nativeViewType
    services.beforeAudioOutput = original.beforeAudioOutput
    services.externalAudioRouteIdentity = original.externalAudioRouteIdentity
    services.mediaDeliveryService = original.mediaDeliveryService
    services.softwareDecodeServices = original.softwareDecodeServices
    let identity = YlSoftwareDecodeIdentity.current!
    let phase = ProcessInfo.processInfo.environment["YL_AV1_PHASE"]!
    let frozen = phase == "verification"
    var software = YlSoftwareDecodeServices()
    software.pool = pool
    if phase == "baseline" || frozen {
      let limits: YlSoftwareDecodeLimits
      if frozen {
        limits = try! JSONDecoder().decode(YlSoftwareDecodeLimits.self,
          from: Data(ProcessInfo.processInfo.environment["YL_TRIAL_LIMITS"]!.utf8))
      } else {
        limits = .init(maxOwnedBytes: 33554432, maxFrames: 64, maxPacketBytes: 1048576,
          windowNs: 1000000000, maxCpuNs: 1000000000, maxDecodeWallNs: 42000000)
      }
      let key = YlSoftwareDecodeKey(model: identity.model, osBuild: identity.osBuild,
        decoderBuild: identity.decoderBuild, codec: 12, profile: 0, bitDepth: 8,
        chroma: 420, width: 320, height: 180, fpsNumerator: 24, fpsDenominator: 1,
        threads: 1, outputPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
      software.admission = .init(entries: [key: limits])
    }
    software.observe = { wall in
      let observation = YlSoftwareVideoDecoder.processObservation(wall: wall)
      if observation.thermalNominal != true || ProcessInfo.processInfo.isLowPowerModeEnabled {
        print("QUAL_BAD thermal-or-power")
      }
      return observation
    }
    services.softwareDecodeServices = software
    output = services.textureOutput as? YlMacosTextureOutput
    output?.collectTimedDiagnostics = true
    print("QUAL_ID \(identity.model) \(identity.osBuild) \(identity.decoderBuild) \(frozen)")
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in report(final: false) }
  }

  static func diagnose() {
    reportClock()
    if let plugin,
      let players = Mirror(reflecting: plugin).descendant("registry", "players") as? [String: YlApplePlayerHost],
      let host = players.values.first,
      let coordinator = Mirror(reflecting: host).descendant("coordinator") as? YlAppleSessionCoordinator,
      let slot = Mirror(reflecting: coordinator).descendant("slot") as? YlBackendSlot,
      let session = Mirror(reflecting: slot.current).descendant("session") as? YlManagedPlaybackSession,
      let presentation = Mirror(reflecting: session).descendant("presentation") as? YlPresentationCoordinator,
      let scheduler = Mirror(reflecting: presentation).descendant("frameScheduler") as? YlFrameScheduler {
      let values: [String: Any] = ["hostNs": DispatchTime.now().uptimeNanoseconds,
        "drops": scheduler.lateFrameDropCount, "pendingPTS": scheduler.pendingPTS,
        "dropDiagnostics": String(describing: scheduler.dropDiagnostics)]
      print("QUAL_SCHEDULER", String(data: try! JSONSerialization.data(withJSONObject: values,
        options: [.sortedKeys]), encoding: .utf8)!)
    }
    if let values = output?.timedDiagnostics {
      print("QUAL_TIMED_DIAGNOSTICS", String(data: try! JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), encoding: .utf8)!)
    }
    if #available(macOS 14.0, *), let output,
      let lock = Mirror(reflecting: output).descendant("timedLock") as? NSLock {
      lock.lock()
      let endpoint = Mirror(reflecting: output).descendant("timedEndpoint") as? YlMacosTimedVideoEndpoint
      lock.unlock()
      if let endpoint, let queue = Mirror(reflecting: endpoint).descendant("queue") as? DispatchQueue {
        let values: [String: Any] = queue.sync {
          let mirror = Mirror(reflecting: endpoint)
          let renderer = mirror.descendant("renderer") as! AVSampleBufferVideoRenderer
          let timebase = mirror.descendant("timebase") as! CMTimebase
          var state: [String: Any] = ["hostNs": DispatchTime.now().uptimeNanoseconds,
            "status": renderer.status.rawValue, "ready": renderer.isReadyForMoreMediaData,
            "requiresFlush": renderer.requiresFlushToResumeDecoding,
            "timebaseSeconds": CMTimeGetSeconds(CMTimebaseGetTime(timebase)),
            "rate": CMTimebaseGetRate(timebase)]
          if let anchor = mirror.descendant("timebaseAnchor") as? YlPresentationClockSnapshot {
            state["anchorHostUs"] = anchor.hostTimeUs; state["anchorPositionUs"] = anchor.positionUs
            state["anchorPlaying"] = anchor.playing
          }
          if let error = renderer.error { state["error"] = String(describing: error) }
          return state
        }
        print("QUAL_RENDERER_STATE", String(data: try! JSONSerialization.data(withJSONObject: values,
          options: [.sortedKeys]), encoding: .utf8)!)
      }
    }
  }

  static func report(final: Bool) {
    reportClock()
    let m = pool.measured!
    let peaks = "\(m.maxOwnedBytes) \(m.maxFrames) \(m.maxPacketBytes) \(m.maxCpuNs) \(m.maxDecodeWallNs)"
    if final {
      timer?.invalidate()
      print("QUAL_END \(run) \(peaks)")
      print("QUAL_TOTAL_DECODED \(m.decodedFrames)")
      print("QUAL_DECODED \(m.decodedFrames - decodedBeforeContinuous)")
    } else {
      print("QUAL_SAMPLE \(run) \(DispatchTime.now().uptimeNanoseconds) \(peaks)")
    }
    fflush(stdout)
  }
}

// Diagnostic host only. Wrap the existing display driver without changing cadence.
private final class YlAV1DiagnosticDriver: YlDisplayDriving {
  private var driver: (any YlDisplayDriving)!
  private var history: [[String: Any]] = []
  private var previousDrops = 0
  private weak var presentation: YlPresentationCoordinator?
  private var mediaClock: YlMediaClock?
  private var scheduler: YlFrameScheduler?
  var isPaused: Bool {
    get { driver.isPaused }
    set { driver.isPaused = newValue }
  }
  init(make: (@escaping () -> Void) -> any YlDisplayDriving, onTick: @escaping () -> Void) {
    driver = make { [weak self] in
      guard let self else { return }
      if self.presentation == nil, let plugin = YlAV1Capture.plugin,
        let players = Mirror(reflecting: plugin).descendant("registry", "players") as? [String: YlApplePlayerHost],
        let host = players.values.first,
        let coordinator = Mirror(reflecting: host).descendant("coordinator") as? YlAppleSessionCoordinator,
        let slot = Mirror(reflecting: coordinator).descendant("slot") as? YlBackendSlot,
        let session = Mirror(reflecting: slot.current).descendant("session") as? YlManagedPlaybackSession,
        let presentation = Mirror(reflecting: session).descendant("presentation") as? YlPresentationCoordinator {
        self.presentation = presentation
        self.mediaClock = Mirror(reflecting: presentation).descendant("mediaClock") as? YlMediaClock
        self.scheduler = Mirror(reflecting: presentation).descendant("frameScheduler") as? YlFrameScheduler
      }
      let host = DispatchTime.now().uptimeNanoseconds
      var row: [String: Any] = ["hostNs": host, "paused": self.driver.isPaused]
      if let clock = self.mediaClock {
        row["positionUs"] = clock.position(atHostTimeUs: Int64(host / 1000))
      }
      row["pendingPTS"] = self.scheduler?.pendingPTS
      onTick()
      row["endNs"] = DispatchTime.now().uptimeNanoseconds
      if let clock = self.presentation?.isolatedAudioClockStatistics {
        row["clock"] = String(describing: clock)
      }
      let drops = self.scheduler?.lateFrameDropCount ?? 0
      row["drops"] = drops
      self.history.append(row)
      if self.history.count > 120 { self.history.removeFirst() }
      if drops > self.previousDrops {
        print("DIAGNOSTIC_DISPLAY_DROP", String(data: try! JSONSerialization.data(withJSONObject: self.history, options: [.sortedKeys]), encoding: .utf8)!)
      }
      self.previousDrops = drops
    }
  }
  func invalidate() { driver.invalidate() }
}
