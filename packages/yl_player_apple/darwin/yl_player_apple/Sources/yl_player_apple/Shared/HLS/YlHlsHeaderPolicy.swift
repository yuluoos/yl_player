import Foundation

struct YlHlsHeaderPolicy {
  private let context: YlManagedRequestContext?

  init(originURL: URL, headers: [String: String], credentials: [String: String] = [:]) {
    context = YlRequestOrigin(url: originURL).map {
      YlManagedRequestContext(sourceOrigin: $0, ordinaryHeaders: headers,
        credentials: credentials, credentialsAllowed: true, redirectsFollowed: 0)
    }
  }

  func isSourceOrigin(_ url: URL) -> Bool {
    context != nil && context?.sourceOrigin == YlRequestOrigin(url: url)
  }

  func requestContext(for url: URL, credentialsStripped: Bool = false) -> YlManagedRequestContext? {
    context?.child(at: url, previouslyStripped: credentialsStripped)
  }

  func headers(for destinationURL: URL, credentialsStripped: Bool = false) -> [String: String] {
    requestContext(for: destinationURL, credentialsStripped: credentialsStripped)?.headers ?? [:]
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
