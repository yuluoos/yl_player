import Foundation

/// Signature inspection consumes at most 4 KiB through package-owned I/O.
/// It does not establish codec support: fallback preparation still opens and
/// validates streams before the existing transaction may commit a candidate.
enum YlSourceInspector {
  static let maximumBytes = 4096

  static func inspect(_ source: YlAppleSourceDescriptor,
                      configuration: YlNetworkConfiguration,
                      token: YlOpenCancellationToken,
                      sessionConfiguration: URLSessionConfiguration = .ephemeral,
                      managedTransportFactory: YlManagedHTTPTransport.Factory? = YlManagedHTTPTransport.make) throws -> YlAppleSourceDescriptor {
    try token.throwIfCancelled()
    guard let url = source.url else { throw unsupported() }
    // Prefix/read/byte-array and transient UTF-8/trim probe copies can coexist.
    // This assigned workspace is conservative, like the transport parser lease.
    let inspectionReservation = try source.bufferScope?.require(category: .networkCache, bytes: maximumBytes * 8)
    defer { withExtendedLifetime(inspectionReservation) {} }
    var prefix = Data()
    if source.kind == .file {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      prefix = try handle.read(upToCount: maximumBytes) ?? Data()
    } else {
      let bytes = YlNetworkByteSource(recipe: YlNetworkRequestRecipe(url: url,
        headers: source.headers, credentials: source.credentials,
        credentialContext: source.credentialContext,
        configuration: source.networkConfiguration.map(YlNetworkConfiguration.init(options:)) ?? configuration,
        mode: .sequentialLive,
        managedIntent: source.networkPolicy == .managed ? source.managedRequestIntent : nil,
        bufferScope: source.bufferScope), capacity: maximumBytes, sessionConfiguration: sessionConfiguration, managedTransportFactory: managedTransportFactory)
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
    if let movie = movieFormat(bytes) { return movie }
    if let text = String(data: prefix, encoding: .utf8),
       text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") { return .hls }
    if bytes.count >= 12, Array(bytes.prefix(4)) == Array("RIFF".utf8),
       Array(bytes[8..<12]) == Array("AVI ".utf8) { return .avi }
    if isProgramStreamPack(bytes) { return .mpegPs }
    // Three consecutive TS headers distinguish 188-byte packets, 192-byte
    // M2TS (four-byte prefix), and 204-byte packets within the bounded prefix.
    for (stride, offset) in [(188, 0), (192, 4), (204, 0)] {
      if bytes.count >= offset + 2 * stride + 4,
         (0..<3).allSatisfy({ index in
           let start = offset + index * stride
           return bytes[start] == 0x47 && bytes[start + 3] & 0x30 != 0
         }) { return .mpegTs }
    }
    return .automatic
  }

  /// QuickTime predates ftyp. Walk complete padding atoms in the bounded
  /// prefix; a validated movie/media atom header can identify legacy MOV.
  /// This establishes only the container family, never stream validity.
  private static func movieFormat(_ bytes: [UInt8]) -> YlSourceFormat? {
    func uint32(_ at: Int) -> UInt64 {
      bytes[at..<(at + 4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    var offset = 0
    while offset <= bytes.count - 8 {
      let kind = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii)
      var size = uint32(offset)
      var header = 8
      if size == 1 {
        guard bytes.count - offset >= 16 else { return nil }
        size = (uint32(offset + 8) << 32) | uint32(offset + 12)
        header = 16
      }
      guard size == 0 || size >= UInt64(header) else { return nil }
      if kind == "ftyp" {
        guard bytes.count - offset >= header + 4,
              size == 0 || size >= UInt64(header + 4) else { return nil }
        return Array(bytes[(offset + header)..<(offset + header + 4)]) == Array("qt  ".utf8) ? .mov : .mp4
      }
      if kind == "mdat" { return .mov }
      if kind == "moov" {
        guard bytes.count - offset >= header + 8,
              size == 0 || size >= UInt64(header + 8),
              uint32(offset + header) >= 8 else { return nil }
        let child = String(bytes: bytes[(offset + header + 4)..<(offset + header + 8)], encoding: .ascii)
        return ["mvhd", "trak", "cmov"].contains(child ?? "") ? .mov : nil
      }
      guard ["free", "skip", "wide"].contains(kind ?? ""), size > 0,
            size <= UInt64(bytes.count - offset) else { return nil }
      offset += Int(size)
    }
    return nil
  }

  /// Validate a complete MPEG-1/2 pack, including SCR/rate marker bits and
  /// MPEG-2 reserved/stuffing bytes. A start-code prefix alone is ambiguous.
  private static func isProgramStreamPack(_ bytes: [UInt8]) -> Bool {
    guard bytes.count >= 12, bytes.starts(with: [0, 0, 1, 0xba]) else { return false }
    if bytes[4] & 0xf1 == 0x21 {
      return bytes[6] & 1 == 1 && bytes[8] & 1 == 1 &&
        bytes[9] & 0x80 == 0x80 && bytes[11] & 1 == 1
    }
    guard bytes.count >= 14, bytes[4] & 0xc4 == 0x44,
          bytes[6] & 4 == 4, bytes[8] & 4 == 4, bytes[9] & 1 == 1,
          bytes[12] & 3 == 3, bytes[13] & 0xf8 == 0xf8 else { return false }
    let size = 14 + Int(bytes[13] & 7)
    guard bytes.count >= size else { return false }
    return bytes[14..<size].allSatisfy { $0 == 0xff }
  }

  private static func unsupported() -> NativePlayerError {
    NativePlayerError(category: "container", code: "container.unsupported",
      message: "Bounded inspection could not identify a supported container.")
  }
}
