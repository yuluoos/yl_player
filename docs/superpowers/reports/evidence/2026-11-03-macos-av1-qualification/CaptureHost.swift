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

  static func reportClock() {
    guard let plugin,
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
          windowNs: 1000000000, maxCpuNs: 1000000000, maxDecodeWallNs: 100000000)
      }
      let key = YlSoftwareDecodeKey(model: identity.model, osBuild: identity.osBuild,
        decoderBuild: identity.decoderBuild, codec: 12, profile: 0, bitDepth: 8,
        chroma: 420, width: 320, height: 180, fpsNumerator: 24, fpsDenominator: 1,
        threads: 2, outputPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
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
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in report(final: false) }
  }

  static func diagnose() {
    reportClock()
    if let values = output?.timedDiagnostics {
      print("QUAL_TIMED_DIAGNOSTICS", String(data: try! JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), encoding: .utf8)!)
    }
  }

  static func report(final: Bool) {
    reportClock()
    let m = pool.measured!
    let peaks = "\(m.maxOwnedBytes) \(m.maxFrames) \(m.maxPacketBytes) \(m.maxCpuNs) \(m.maxDecodeWallNs)"
    if final {
      timer?.invalidate()
      print("QUAL_END \(run) \(peaks)")
      print("QUAL_DECODED \(m.decodedFrames)")
    } else {
      print("QUAL_SAMPLE \(run) \(DispatchTime.now().uptimeNanoseconds) \(peaks)")
    }
    fflush(stdout)
  }
}
