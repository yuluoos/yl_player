import CFNetwork
import Foundation
import Network
import Security

/// A single HTTP/1.1 hop. TCP/TLS and trust stay with Network.framework;
/// HTTP framing exposes final headers independently of MIME/body delivery.
final class YlManagedHTTPTransport {
  enum Event { case headers(HTTPURLResponse), body(Data), complete(Error?) }
  typealias Factory = (URLRequest, @escaping (Event) -> Void) throws -> YlManagedHTTPTransport
  static let maximumReceiveBytes = 16 * 1024
  static let make: Factory = { try YlManagedHTTPTransport(request: $0, receive: $1) }
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "dev.ylplayer.managed-http")
  private let lock = NSLock()
  private var cancelled = false
  private let parser: YlHTTPResponseParser
  // Covers the outstanding receive plus parser COW input and emitted event
  // backing. Admission happens before NW receive/queued delivery. Conservative
  // assigned workspace survives cancellation until the actual hop owner dies.
  private var payloadWorkspace: YlManagedBufferLedger.Token?
  func assignBufferScope(_ scope: YlManagedBufferScope?) throws {
    payloadWorkspace = try scope?.require(category: .networkCache,
      bytes: 3 * (YlHTTPResponseParser.maximumHeaderBytes + Self.maximumReceiveBytes))
  }
  private let requestBytes: Data
  private let receiveEvent: (Event) -> Void

  init(request: URLRequest, receive: @escaping (Event) -> Void,
       configureTLS: ((NWProtocolTLS.Options) -> Void)? = nil) throws {
    guard let url = request.url, let origin = YlRequestOrigin(url: url),
          origin.effectivePort > 0, origin.effectivePort <= 65535,
          let port = NWEndpoint.Port(rawValue: UInt16(exactly: origin.effectivePort) ?? 0),
          url.user == nil, url.password == nil else { throw Self.unsupported() }
    try YlManagedTransportRestrictions.validate(url: url)
    let host = origin.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let parameters: NWParameters
    if origin.scheme == "https" {
      let tls = NWProtocolTLS.Options()
      sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
      sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
      sec_protocol_options_append_tls_ciphersuite_group(tls.securityProtocolOptions, .ats)
      sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
      sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
      configureTLS?(tls) // Internal test seam; production never changes trust evaluation.
      parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    } else { parameters = .tcp }
    connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
    parser = YlHTTPResponseParser(url: url, method: request.httpMethod ?? "GET")
    requestBytes = try Self.serialize(request)
    receiveEvent = receive
  }

  func start() {
    guard !isCancelled else { return }
    connection.stateUpdateHandler = { [weak self] state in
      guard let self, !self.isCancelled else { return }
      switch state {
      case .ready:
        self.connection.send(content: self.requestBytes, completion: .contentProcessed { [weak self] error in
          guard let self, !self.isCancelled else { return }
          if let error { self.finish(Self.transportError(error)) }
          else { self.readNext() }
        })
      case .failed(let error): self.finish(Self.transportError(error))
      case .waiting(let error):
        // Network.framework can surface certificate failures as waiting. They
        // cannot recover by waiting for a path change or spending retries.
        if case .tls = error { self.finish(Self.transportError(error)) }
      default: break
      }
    }
    connection.start(queue: queue)
  }

  func cancel() {
    lock.lock(); cancelled = true; lock.unlock()
    // Does not enqueue behind a delegate blocked on the consumer's ring buffer.
    connection.cancel()
    retireWorkspace()
  }
  private func retireWorkspace() {
    // This queue also owns parser mutations. A body callback blocked in ring
    // write completes before this receipt frees its parser/delivery workspace.
    queue.async { [self] in parser.discard(); payloadWorkspace = nil }
  }

  private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

  private func readNext() {
    guard !isCancelled else { return }
    connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumReceiveBytes) { [weak self] data, _, complete, error in
      guard let self, !self.isCancelled else { return }
      do {
        if let data, !data.isEmpty { self.deliver(try self.parser.receive(data)) }
        guard !self.isCancelled else { return }
        if let error { self.finish(Self.transportError(error)) }
        else if complete { self.deliver(try self.parser.endOfStream()) }
        else { self.readNext() }
      } catch { self.finish(error) }
    }
  }

  private func deliver(_ events: [YlHTTPResponseParser.Event]) {
    for event in events {
      guard !isCancelled else { return }
      switch event {
      case .headers(let response): receiveEvent(.headers(response))
      case .body(let data): receiveEvent(.body(data))
      case .complete: finish(nil)
      }
    }
  }

  private func finish(_ error: Error?) {
    lock.lock()
    guard !cancelled else { lock.unlock(); return }
    cancelled = true
    lock.unlock()
    connection.cancel()
    receiveEvent(.complete(error))
    retireWorkspace()
  }

  static func serialize(_ request: URLRequest) throws -> Data {
    guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let host = components.host, ["GET", "HEAD"].contains(request.httpMethod ?? "GET"),
          request.httpBody == nil, request.httpBodyStream == nil else { throw unsupported() }
    var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    if let query = components.percentEncodedQuery { target += "?" + query }
    var text = "\(request.httpMethod ?? "GET") \(target) HTTP/1.1\r\n"
    let wireHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    text += "Host: \(wireHost)\(components.port.map { ":\($0)" } ?? "")\r\nConnection: close\r\nAccept-Encoding: identity\r\n"
    for (name, value) in request.allHTTPHeaderFields ?? [:] {
      try YlHTTPResponseParser.validateHeader(name: name, value: value)
      let key = name.lowercased()
      if ["host", "connection", "accept-encoding"].contains(key) { continue }
      guard !["transfer-encoding", "content-length", "upgrade", "te", "trailer"].contains(key) else { throw unsupported() }
      text += "\(name): \(value)\r\n"
    }
    guard let data = (text + "\r\n").data(using: .isoLatin1), data.count <= YlHTTPResponseParser.maximumHeaderBytes else { throw unsupported() }
    return data
  }

  private static func transportError(_ error: NWError) -> Error {
    switch error {
    case .tls: return URLError(.serverCertificateUntrusted)
    case .dns: return URLError(.cannotFindHost)
    case .posix(let code):
      switch code {
      case .ECONNRESET, .EPIPE: return URLError(.networkConnectionLost)
      case .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH: return URLError(.cannotConnectToHost)
      case .ETIMEDOUT: return URLError(.timedOut)
      case .ECANCELED: return URLError(.cancelled)
      default: return URLError(.unknown)
      }
    @unknown default: return URLError(.unknown)
    }
  }

  static func unsupported() -> NativePlayerError {
    NativePlayerError(category: "unsupported", code: "policy.unsupported",
      message: "The managed HTTP configuration is unsupported.", diagnostic: "network.configuration")
  }
}

/// Direct connections must not silently bypass HTTP proxy/PAC or explicit ATS
/// restrictions. Unsupported restrictions reject; this is not a proxy stack.
enum YlManagedTransportRestrictions {
  static func validate(url: URL, ats: [String: Any]? = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any],
                       proxySettings: [String: Any]? = nil) throws {
    let settings = proxySettings.map { $0 as CFDictionary } ?? CFNetworkCopySystemProxySettings()?.takeRetainedValue()
    if let settings {
      let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as NSArray
      for case let proxy as NSDictionary in proxies {
        guard proxy[kCFProxyTypeKey] as? String == kCFProxyTypeNone as String else { throw YlManagedHTTPTransport.unsupported() }
      }
    }
    let ats = ats ?? [:]
    guard ats["NSPinnedDomains"] == nil, ats["NSRequiresCertificateTransparency"] as? Bool != true else { throw YlManagedHTTPTransport.unsupported() }
    let host = url.host?.lowercased() ?? ""
    let exceptions = ats["NSExceptionDomains"] as? [String: [String: Any]] ?? [:]
    let domain = exceptions.keys.sorted { $0.count > $1.count }.first {
      host == $0.lowercased() || ((exceptions[$0]?["NSIncludesSubdomains"] as? Bool == true) && host.hasSuffix("." + $0.lowercased()))
    }
    let rule = domain.flatMap { exceptions[$0] } ?? [:]
    guard rule["NSRequiresCertificateTransparency"] as? Bool != true,
          rule["NSExceptionRequiresNIAPTLSPackageVersion"] == nil,
          (rule["NSExceptionMinimumTLSVersion"] as? String).map({ ["TLSv1.0", "TLSv1.1", "TLSv1.2"].contains($0) }) ?? true else {
      throw YlManagedHTTPTransport.unsupported()
    }
    guard url.scheme?.lowercased() == "http" else { return }
    if domain != nil {
      guard rule["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true else { throw YlManagedHTTPTransport.unsupported() }
      return
    }
    let local = host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host == "::1" || host.hasSuffix(".local") || !host.contains(".")
    if local, ats["NSAllowsLocalNetworking"] as? Bool == true { return }
    // On modern platforms a present scoped exception suppresses the global
    // arbitrary-loads key. Media exemption applies to these media byte routes.
    if ats["NSAllowsArbitraryLoadsForMedia"] as? Bool == true { return }
    if ats["NSAllowsLocalNetworking"] == nil, ats["NSAllowsArbitraryLoadsForMedia"] == nil,
       ats["NSAllowsArbitraryLoadsInWebContent"] == nil, ats["NSAllowsArbitraryLoads"] as? Bool == true { return }
    throw YlManagedHTTPTransport.unsupported()
  }
}
