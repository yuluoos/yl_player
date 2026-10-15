import Foundation

/// Exact measurement identity; frame rate is a positive rational, dimensions are pixels.
/// Build/OS/model changes require new evidence, never nearest-profile matching.
struct YlSoftwareDecodeKey: Hashable, Codable {
  let model: String; let osBuild: String; let decoderBuild: String
  let codec: Int32; let profile: Int32; let bitDepth: Int; let chroma: Int
  let width: Int; let height: Int; let fpsNumerator: Int; let fpsDenominator: Int
  let threads: Int; let outputPixelFormat: UInt32
}

/// All sizes are owned bytes, counts are frames, time values are nanoseconds.
struct YlSoftwareDecodeLimits: Codable, Equatable {
  let maxOwnedBytes: Int; let maxFrames: Int; let maxPacketBytes: Int
  let windowNs: UInt64; let maxCpuNs: UInt64; let maxDecodeWallNs: UInt64
}

/// Internal measured allowlist. Production starts empty; tests inject synthetic records.
struct YlSoftwareDecodeAdmission {
  let entries: [YlSoftwareDecodeKey: YlSoftwareDecodeLimits]
  init(entries: [YlSoftwareDecodeKey: YlSoftwareDecodeLimits] = [:]) { self.entries = entries }
  func limits(for key: YlSoftwareDecodeKey) -> YlSoftwareDecodeLimits? {
    guard key.isValid, let limits = entries[key], limits.isValid else { return nil }
    return limits
  }
}

private extension YlSoftwareDecodeKey {
  var isValid: Bool {
    guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !osBuild.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !decoderBuild.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      codec > 0, profile >= 0, [8, 10, 12].contains(bitDepth),
      [400, 420, 422, 444].contains(chroma), width > 0, height > 0,
      fpsNumerator > 0, fpsDenominator > 0, threads > 0, outputPixelFormat > 0
    else { return false }
    let pixels = width.multipliedReportingOverflow(by: height)
    let bytes = pixels.partialValue.multipliedReportingOverflow(by: 8)
    return !pixels.overflow && !bytes.overflow
  }
}

extension YlSoftwareDecodeLimits {
  var isValid: Bool {
    maxOwnedBytes > 0 && maxFrames > 0 && maxPacketBytes > 0
      && maxPacketBytes <= maxOwnedBytes && windowNs > 0
      && maxCpuNs > 0 && maxDecodeWallNs > 0
  }
}
