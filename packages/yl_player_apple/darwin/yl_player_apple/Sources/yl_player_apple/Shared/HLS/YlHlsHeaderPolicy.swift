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
