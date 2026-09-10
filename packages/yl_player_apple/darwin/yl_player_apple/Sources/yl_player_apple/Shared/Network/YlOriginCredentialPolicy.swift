import Foundation

struct YlRequestOrigin: Equatable {
  let scheme: String
  let host: String
  let effectivePort: Int

  init?(url: URL) {
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
          let host = url.host?.lowercased(), !host.isEmpty else { return nil }
    self.scheme = scheme
    self.host = host
    effectivePort = url.port ?? (scheme == "https" ? 443 : 80)
  }
}

/// A value follows a request or HLS child. Origin stripping is monotonic;
/// per-Load history retains this decision across reader/loader reconstruction.
struct YlManagedRequestContext {
  let sourceOrigin: YlRequestOrigin
  let ordinaryHeaders: [String: String]
  let credentials: [String: String]
  let credentialsAllowed: Bool
  let redirectsFollowed: Int

  func child(at url: URL, previouslyStripped: Bool = false, redirect: Bool = false) -> Self {
    Self(sourceOrigin: sourceOrigin, ordinaryHeaders: ordinaryHeaders,
      credentials: credentials,
      credentialsAllowed: credentialsAllowed && !previouslyStripped && sourceOrigin == YlRequestOrigin(url: url),
      redirectsFollowed: redirectsFollowed + (redirect ? 1 : 0))
  }

  var headers: [String: String] {
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
}
