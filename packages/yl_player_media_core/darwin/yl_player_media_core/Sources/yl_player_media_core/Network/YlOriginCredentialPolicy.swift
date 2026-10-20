import Foundation

public struct YlRequestOrigin: Equatable {
  public let scheme: String
  public let host: String
  public let effectivePort: Int

  public init?(url: URL) {
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
          let host = url.host?.lowercased(), !host.isEmpty else { return nil }
    self.scheme = scheme
    self.host = host
    effectivePort = url.port ?? (scheme == "https" ? 443 : 80)
  }
}

/// A value follows a request or HLS child. Origin stripping is monotonic;
/// per-Load history retains this decision across reader/loader reconstruction.
public struct YlManagedRequestContext {
  public let sourceOrigin: YlRequestOrigin
  public let ordinaryHeaders: [String: String]
  public let credentials: [String: String]
  public let credentialsAllowed: Bool
  public let redirectsFollowed: Int

  public func child(at url: URL, previouslyStripped: Bool = false, redirect: Bool = false) -> Self {
    Self(sourceOrigin: sourceOrigin, ordinaryHeaders: ordinaryHeaders,
      credentials: credentials,
      credentialsAllowed: credentialsAllowed && !previouslyStripped && sourceOrigin == YlRequestOrigin(url: url),
      redirectsFollowed: redirectsFollowed + (redirect ? 1 : 0))
  }

  public var headers: [String: String] {
    let sensitive = Set(["authorization", "cookie", "proxy-authorization"])
      .union(credentials.keys.map { $0.lowercased() })
    // Resolve collisions without depending on Dictionary iteration order.
    let explicitNames = Set(credentials.keys.map { $0.lowercased() })
    var result = ordinaryHeaders.filter {
      !explicitNames.contains($0.key.lowercased()) && (credentialsAllowed || !sensitive.contains($0.key.lowercased()))
    }
    if credentialsAllowed { for (name, value) in credentials { result[name] = value } }
    return result
  }

  public init(sourceOrigin: YlRequestOrigin, ordinaryHeaders: [String: String], credentials: [String: String], credentialsAllowed: Bool, redirectsFollowed: Int) {
    self.sourceOrigin = sourceOrigin
    self.ordinaryHeaders = ordinaryHeaders
    self.credentials = credentials
    self.credentialsAllowed = credentialsAllowed
    self.redirectsFollowed = redirectsFollowed
  }
}
