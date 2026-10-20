import Foundation

public func ylRtmpError(_ code: String) -> NativePlayerError {
  NativePlayerError(category: code.hasPrefix("container.") ? "container" : code.hasPrefix("policy.") ? "unsupported" : code.hasPrefix("resource.") ? "resource" : code.hasPrefix("source.") ? "source" : "network",
    code: code, message: "The RTMP operation could not complete.")
}
public func ylRtmpInvalid() -> NativePlayerError { ylRtmpError("network.protocol_unsupported") }
func ylRtmpLimit() -> NativePlayerError { ylRtmpError("resource.exhausted") }

public struct YlRtmpAddress {
  public let host: String
  public let port: UInt16
  public let app: String
  public let playpath: String
  public let tcURL: String
  public let secure: Bool

  public init(_ raw: String) throws {
    func invalid() -> NativePlayerError { ylRtmpError("source.invalid_uri") }
    guard raw.utf8.count <= 8192, let c = URLComponents(string: raw),
      let scheme = c.scheme?.lowercased(), ["rtmp", "rtmps"].contains(scheme),
      let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
      c.fragment == nil, c.port == nil || (1...65535).contains(c.port!),
      raw.range(of: "%($|[^0-9A-Fa-f]|[0-9A-Fa-f]($|[^0-9A-Fa-f]))", options: .regularExpression) == nil,
      !Self.containsControls(raw),
      !host.contains(" "), let schemeEnd = raw.range(of: "://") else { throw invalid() }
    let afterScheme = raw[schemeEnd.upperBound...]
    guard let slash = afterScheme.firstIndex(of: "/") else { throw invalid() }
    let authority = String(afterScheme[..<slash])
    // URLComponents treats an empty port as absent; the public lexical contract does not.
    guard !authority.hasSuffix(":"), !authority.contains("@") else { throw invalid() }
    let pathAndQuery = raw[raw.index(after: slash)...]
    let rawPath = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
    guard let split = rawPath.firstIndex(of: "/"), split != rawPath.startIndex,
      rawPath.index(after: split) != rawPath.endIndex else { throw invalid() }
    self.host = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
    port = UInt16(c.port ?? (scheme == "rtmps" ? 443 : 1935))
    app = String(rawPath[..<split])
    playpath = String(pathAndQuery[pathAndQuery.index(after: split)...])
    tcURL = "\(scheme)://\(authority)/\(app)"
    secure = scheme == "rtmps"
  }

  private static func containsControls(_ raw: String) -> Bool {
    // URI octets need not form UTF-8. Replacement decoding preserves opaque
    // bytes while still exposing ASCII and valid UTF-8 C1 controls for rejection.
    let bytes = Array(raw.utf8)
    var decoded: [UInt8] = []; decoded.reserveCapacity(bytes.count)
    var at = 0
    while at < bytes.count {
      if bytes[at] == 37 {
        guard at + 2 < bytes.count,
          let value = UInt8(String(decoding: bytes[(at+1)...(at+2)], as: UTF8.self), radix: 16) else { return true }
        decoded.append(value); at += 3
      } else { decoded.append(bytes[at]); at += 1 }
    }
    return String(decoding: decoded, as: UTF8.self).unicodeScalars.contains {
      $0.value < 32 || (127...159).contains($0.value)
    }
  }


}

/// Retained by the source descriptor and recipe across managed-session reconstruction.
public final class YlRtmpRecoveryBudget {
  public init() {}
  private let lock = NSLock()
  private var used = 0
  public var attempts: Int { lock.lock(); defer { lock.unlock() }; return used }
  public static func isTransient(_ error: NativePlayerError) -> Bool {
    ["network.rtmp_handshake_failed", "network.rtmp_disconnected"].contains(error.code)
  }
  /// The coordinator calls this only for a previously committed load. Its
  /// original open token/waiter owns the explicit attempt and every retry.
  public func prepareRestoration<T>(token: YlOpenCancellationToken, work: () throws -> T) throws -> T {
    let cancelled = DispatchSemaphore(value: 0)
    token.onCancel { cancelled.signal() }
    while true {
      try token.throwIfCancelled()
      do { return try work() }
      catch let error as NativePlayerError {
        try token.throwIfCancelled()
        guard Self.isTransient(error) else { throw error }
        guard let delay = nextDelay(after: error) else { throw ylRtmpError("network.retry_exhausted") }
        _ = cancelled.wait(timeout: .now() + .milliseconds(Int(delay)))
        try token.throwIfCancelled()
      }
    }
  }

  public func nextDelay(after error: NativePlayerError) -> Int64? {
    lock.lock(); defer { lock.unlock() }
    guard Self.isTransient(error), used < 3 else { return nil }
    let delay: Int64 = [500, 1000, 2000][used]; used += 1; return delay
  }
}

public struct YlRtmpRequestRecipe {
  public let address: YlRtmpAddress
  public let recovery: YlRtmpRecoveryBudget
  public let bufferScope: YlManagedBufferScope

  public init(address: YlRtmpAddress, recovery: YlRtmpRecoveryBudget, bufferScope: YlManagedBufferScope) {
    self.address = address
    self.recovery = recovery
    self.bufferScope = bufferScope
  }
}
