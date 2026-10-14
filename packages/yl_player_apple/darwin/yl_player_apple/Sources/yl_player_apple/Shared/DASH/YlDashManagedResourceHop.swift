import Foundation

/// Adapter to the existing managed transport: no URLSession, hidden redirects,
/// native credential store, or independent retry budget is introduced here.
final class YlDashManagedResourceHop: YlDashResourceHop {
  private let transport: YlManagedHTTPTransport
  init(request: URLRequest, scope: YlManagedBufferScope,
       receive: @escaping (YlDashResourceEvent) -> Void) throws {
    transport = try YlManagedHTTPTransport(request: request) { event in
      switch event {
      case .headers(let response): receive(.headers(response))
      case .body(let bytes): receive(.body(bytes))
      case .complete(let error): receive(.complete(error))
      }
    }
    try transport.assignBufferScope(scope)
  }
  func start() { transport.start() }
  func cancel() { transport.cancel() }
  deinit { cancel() }
}

extension YlDashProgramResources {
  /// The host-owned scope accounts for both hop workspace and payload lifetime.
  convenience init(source: URL, headers: [String: String], credentials: [String: String],
                   configuration: YlNetworkConfiguration, scope: YlManagedBufferScope) {
    self.init(source: source, headers: headers, credentials: credentials,
      configuration: configuration, factory: { request, receive in
        try YlDashManagedResourceHop(request: request, scope: scope, receive: receive)
      }, reserve: { try scope.require(category: .networkCache, bytes: $0) })
  }
}
