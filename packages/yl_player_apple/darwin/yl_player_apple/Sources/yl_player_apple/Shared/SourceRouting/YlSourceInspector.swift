import Foundation

/// Signature inspection consumes at most 4 KiB through package-owned I/O.
/// It does not establish codec support: fallback preparation still opens and
/// validates streams before the existing transaction may commit a candidate.
enum YlSourceInspector {
  static let maximumBytes = 4096

  static func inspect(_ source: YlAppleSourceDescriptor,
                      configuration: YlNetworkConfiguration,
                      token: YlOpenCancellationToken,
                      sessionConfiguration: URLSessionConfiguration = .ephemeral) throws -> YlAppleSourceDescriptor {
    try token.throwIfCancelled()
    guard let url = source.url else { throw unsupported() }
    var prefix = Data()
    if source.kind == .file {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      prefix = try handle.read(upToCount: maximumBytes) ?? Data()
    } else {
      let bytes = YlNetworkByteSource(recipe: YlNetworkRequestRecipe(url: url,
        headers: source.headers, credentials: source.credentials,
        credentialContext: source.credentialContext, configuration: configuration,
        mode: .sequentialLive), capacity: maximumBytes, sessionConfiguration: sessionConfiguration)
      token.onCancel { bytes.cancel() }
      defer { bytes.cancel() }
      var buffer = [UInt8](repeating: 0, count: maximumBytes)
      while prefix.count < maximumBytes {
        let count = try buffer.withUnsafeMutableBytes {
          try bytes.read(into: UnsafeMutableRawBufferPointer(rebasing: $0[..<(maximumBytes - prefix.count)]))
        }
        if count == 0 { break }
        prefix.append(contentsOf: buffer.prefix(count))
        // Supported signatures fit this prefix; don't wait for a live body.
        if format(prefix) != .automatic { break }
      }
    }
    try token.throwIfCancelled()
    let resolved = format(prefix)
    guard resolved != .automatic else { throw unsupported() }
    var inspected = source
    inspected.formatHint = resolved
    return inspected
  }

  static func format(_ prefix: Data) -> YlSourceFormat {
    let bytes = [UInt8](prefix)
    if bytes.starts(with: [0x46, 0x4c, 0x56]) { return .flv }
    if bytes.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) {
      // EBML alone is insufficient to identify its DocType.
      if prefix.range(of: Data("webm".utf8)) != nil { return .webm }
      if prefix.range(of: Data("matroska".utf8)) != nil { return .matroska }
    }
    if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) {
      return Array(bytes[8..<12]) == Array("qt  ".utf8) ? .mov : .mp4
    }
    if let text = String(data: prefix, encoding: .utf8),
       text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") { return .hls }
    if bytes.count >= 12, Array(bytes.prefix(4)) == Array("RIFF".utf8),
       Array(bytes[8..<12]) == Array("AVI ".utf8) { return .avi }
    return .automatic
  }

  private static func unsupported() -> NativePlayerError {
    NativePlayerError(category: "container", code: "container.unsupported",
      message: "Bounded inspection could not identify a supported container.")
  }
}
