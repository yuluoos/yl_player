import yl_player_media_core
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import YlFFmpegBridge

/// Measurement identity uses the loaded Swift decoder image and codec bridge.
/// Any unavailable field denies admission; no device-family or OS-version fallback.
struct YlSoftwareDecodeIdentity {
  let model: String
  let osBuild: String
  let decoderBuild: String
  static let current: Self? = {
    func sysctl(_ name: String) -> String? {
      var size = 0
      guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1, size < 4096 else { return nil }
      var bytes = [CChar](repeating: 0, count: size)
      guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
      return String(cString: bytes)
    }
    func hash(_ url: URL) -> String? {
      guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
      defer { try? file.close() }
      var digest = SHA256()
      do {
        while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty { digest.update(data: bytes) }
      } catch { return nil }
      return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func imageHash(_ address: UnsafeRawPointer) -> String? {
      var image = Dl_info()
      guard dladdr(address, &image) != 0, let path = image.dli_fname else { return nil }
      return hash(URL(fileURLWithPath: String(cString: path)))
    }
    // In a split Xcode build the decoder lives in the debug dylib, not the launcher.
    let decoder = unsafeBitCast(YlSoftwareVideoDecoder.self, to: UnsafeRawPointer.self)
    let symbol = unsafeBitCast(ylf_ffmpeg_version as @convention(c) () -> UnsafePointer<CChar>?, to: UnsafeRawPointer.self)
    guard let model = sysctl("hw.model") ?? sysctl("hw.machine"), let os = sysctl("kern.osversion"),
      let swiftHash = imageHash(decoder), let codecHash = imageHash(symbol) else { return nil }
    return .init(model: model, osBuild: os, decoderBuild: swiftHash + ":" + codecHash)
  }()
}

/// A signed host profile can admit its exact measured identity. Controlled tests
/// inject entries and observations separately.
struct YlSoftwareDecodeServices {
  var admission = YlSoftwareDecodeAdmission.production
  var pool = YlSoftwareDecodePool.shared
  var identity: () -> YlSoftwareDecodeIdentity? = { .current }
  var threads = 1
  var monitorProcess = true
  var observe: YlSoftwareVideoDecoder.Observe = YlSoftwareVideoDecoder.processObservation

  func make(configuration: YlSoftwareVideoConfiguration?, format: CMVideoFormatDescription,
      budget: YlFallbackBufferBudget, onFrame: @escaping (YlVideoFrame) -> Void,
      onError: @escaping (NativePlayerError) -> Void) throws -> any YlVideoDecoderResource {
    guard let configuration, let identity = identity() else {
      throw YlHardwareDecoderEvidence.unavailable()
    }
    let d = configuration.descriptor
    let full: Bool
    if d.full_range >= 0 { full = d.full_range == 1 }
    else if let range = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool { full = range }
    else { throw YlHardwareDecoderEvidence.unavailable() }
    let pixel: OSType
    if d.bit_depth == 8 { pixel = full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange }
    else if d.bit_depth == 10 { pixel = full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange }
    else { throw YlHardwareDecoderEvidence.unavailable() }
    let key = configuration.key(model: identity.model, osBuild: identity.osBuild,
      decoderBuild: identity.decoderBuild, threads: threads, outputPixelFormat: pixel)
    
    guard key.codec == YLFCodecAV1, key.profile == 0, key.bitDepth == 8,
      key.chroma == 420, key.width == 320, key.height == 180,
      key.fpsNumerator == 24, key.fpsDenominator == 1 else {
      throw YlHardwareDecoderEvidence.unavailable()
    }
    let frozen = ProcessInfo.processInfo.environment["YL_TRIAL_LIMITS"]
    let limits = try frozen.map { try JSONDecoder().decode(YlSoftwareDecodeLimits.self, from: Data($0.utf8)) }
      ?? YlSoftwareDecodeLimits(maxOwnedBytes: 33554432, maxFrames: 64, maxPacketBytes: 1048576,
        windowNs: 1000000000, maxCpuNs: 1000000000, maxDecodeWallNs: 100000000)
    let admission = YlSoftwareDecodeAdmission(entries: [key: limits])
    print("QUAL_ID \(identity.model) \(identity.osBuild) \(identity.decoderBuild) \(frozen != nil)")

    let interval = min(250_000_000, max(1, limits.windowNs / 4))
    return try YlSoftwareVideoDecoder(configuration: configuration, key: key, admission: admission,
      pool: pool, maxInFlightBytes: budget.inFlightPacketBytes, bufferScope: budget.bufferScope,
      observe: observe, monitoringIntervalNs: monitorProcess ? interval : nil, onFrame: onFrame, onError: onError)
  }
}
