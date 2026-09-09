import Foundation

struct YlHlsHeaderPolicy {
  private static let sensitive = Set([
    "authorization",
    "cookie",
    "proxy-authorization",
  ])

  private let origin: Origin?
  private let credentialNames: Set<String>
  private let configuredHeaders: [String: String]

  init(originURL: URL, headers: [String: String], credentials: [String: String] = [:]) {
    origin = Origin(url: originURL)
    configuredHeaders = headers.merging(credentials) { _, credential in credential }
    credentialNames = Self.sensitive.union(credentials.keys.map { $0.lowercased() })
  }

  func isSourceOrigin(_ url: URL) -> Bool { origin != nil && origin == Origin(url: url) }

  func headers(for destinationURL: URL, credentialsStripped: Bool = false) -> [String: String] {
    let isSameOrigin = !credentialsStripped && isSourceOrigin(destinationURL)
    return configuredHeaders.filter { name, _ in
      isSameOrigin || !credentialNames.contains(name.lowercased())
    }
  }

  private struct Origin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
      guard let scheme = url.scheme?.lowercased(),
            let host = url.host?.lowercased(),
            !host.isEmpty else { return nil }
      let defaultPort: Int
      switch scheme {
      case "http": defaultPort = 80
      case "https": defaultPort = 443
      default: return nil
      }
      self.scheme = scheme
      self.host = host
      port = url.port ?? defaultPort
    }
  }
}

/// Credential provenance belongs to a user Load, not to a loader or proxy.
/// Retained only by its committed session and genuinely in-flight requests.
final class YlHlsCredentialContext {
  private let lock = NSLock()
  private var strippedResources = Set<String>()

  func isStripped(_ resource: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return strippedResources.contains(resource)
  }

  func strip(_ resource: String) {
    lock.lock()
    defer { lock.unlock() }
    strippedResources.insert(resource)
  }
}
