import Foundation

struct YlHlsHeaderPolicy {
  private static let sensitive = Set([
    "authorization",
    "cookie",
    "proxy-authorization",
  ])

  private let origin: Origin?
  private let configuredHeaders: [String: String]

  init(originURL: URL, headers: [String: String]) {
    origin = Origin(url: originURL)
    configuredHeaders = headers
  }

  func headers(for destinationURL: URL) -> [String: String] {
    let isSameOrigin = origin != nil && origin == Origin(url: destinationURL)
    return configuredHeaders.filter { name, _ in
      isSameOrigin || !Self.sensitive.contains(name.lowercased())
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
