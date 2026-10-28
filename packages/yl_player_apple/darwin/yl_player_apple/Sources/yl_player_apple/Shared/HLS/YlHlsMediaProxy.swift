import yl_player_media_core
import Foundation
import Network

/// Owned by one loader/session. Bounded unresolved failures are removed when the
/// same resource succeeds; cancellation never replaces an upstream cause.
final class YlHlsUpstreamDiagnostics {
  private let lock = NSLock()
  private var failures: [(String, NativePlayerError)] = []
  private var active = true
  var latestFailure: NativePlayerError? { lock.withLock { failures.last?.1 } }

  func record(_ error: NativePlayerError, resource: String, httpStatus: Int? = nil) {
    guard error.code != "network.cancelled" else { return }
    let recorded = lock.withLock { () -> Bool in
      guard active else { return false }
      failures.removeAll { $0.0 == resource }
      failures.append((resource, error))
      if failures.count > 16 { failures.removeFirst() }
      return true
    }
    guard recorded else { return }
    let failure = YlAppleSafeDiagnostics.failure(error, scope: .session)
    let status = httpStatus ?? YlHTTPFailure.status(from: failure.code)
    NSLog("YlPlayer upstream httpStatus=%@ code=%@ reason=%@ diagnosticId=%@",
      status.map(String.init) ?? "none", failure.code, failure.message, failure.diagnosticId)
  }

  func succeeded(resource: String) { lock.withLock { failures.removeAll { $0.0 == resource } } }
  func clear() { lock.withLock { active = false; failures.removeAll() } }
}

final class YlHlsMediaProxy: NSObject, URLSessionDataDelegate {
  enum CompletionAction: Equatable {
    case badGateway
    case finishChunked
    case close
  }

  private final class TaskRecord {
    var opaqueRetention: YlManagedBufferLedger.OpaqueHlsRetention?
    let connection: NWConnection
    let method: String
    let range: String?
    var requestContext: YlManagedRequestContext?
    var redirectCount: Int { requestContext?.redirectsFollowed ?? 0 }
    var credentialsStripped: Bool { requestContext?.credentialsAllowed != true }
    var resourceKey = ""
    var responseStarted = false
    var usesChunkedTransfer = false
    var pendingSends = 0
    var upstreamFinished = false
    var upstreamError: Error?
    var reportedFailure: NativePlayerError?
    var httpStatus: Int?

    init(connection: NWConnection, method: String, range: String?, opaqueRetention: YlManagedBufferLedger.OpaqueHlsRetention? = nil) {
      self.opaqueRetention = opaqueRetention
      self.connection = connection
      self.method = method
      self.range = range
    }
  }

  #if DEBUG
  // Numeric, per-proxy debug observations only. No resource/credential identity,
  // no retained event history and no change to transport or admission decisions.
  private var diagnosticCounters: [String: Double] = [
    "acceptedConnections": 0, "admittedRequests": 0,
    "upstreamCompletions": 0, "receivedBodyBytes": 0, "closedWithActiveTask": 0,
    "cancelledCompletions": 0, "failedCompletions": 0,
    "lastAdmissionUptime": 0, "lastCompletionUptime": 0]
  var diagnosticSnapshot: [String: Double] {
    lock.withLock {
      var result = diagnosticCounters
      result["activeConnections"] = Double(connections.count)
      result["activeTasks"] = Double(taskRecords.count)
      result["pendingSends"] = Double(taskRecords.values.reduce(0) { $0 + $1.pendingSends })
      result["suspendedTasks"] = Double(connectionTasks.values.filter { $0.state == .suspended }.count)
      result["cancelled"] = cancelled ? 1 : 0
      return result
    }
  }
  #endif

  let upstreamDiagnostics: YlHlsUpstreamDiagnostics

  private let queue = DispatchQueue(
    label: "dev.ylplayer.hls.media-proxy",
    qos: .userInitiated
  )
  private let lock = NSLock()
  private let opaqueRetention: YlManagedBufferLedger.OpaqueHlsRetention?
  private let headerPolicy: YlHlsHeaderPolicy
  private let configuration: YlNetworkConfiguration
  private let listener: NWListener
  private let accessToken = UUID().uuidString.lowercased()
  private var session: URLSession!
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private let trafficScope: YlManagedBufferScope?
  private let credentialContext: YlHlsCredentialContext
  private var taskRecords: [Int: TaskRecord] = [:]
  private var connectionTasks: [ObjectIdentifier: URLSessionDataTask] = [:]
  private var cancelled = false
  private var listeningPort: NWEndpoint.Port?

  init(
    originURL: URL,
    upstreamDiagnostics: YlHlsUpstreamDiagnostics = YlHlsUpstreamDiagnostics(),
    headers: [String: String],
    credentials: [String: String] = [:],
    configuration: YlNetworkConfiguration,
    credentialContext: YlHlsCredentialContext = YlHlsCredentialContext(),
    opaqueRetention: YlManagedBufferLedger.OpaqueHlsRetention? = nil,
    trafficScope: YlManagedBufferScope? = nil,
    sessionFactory: (URLSessionConfiguration, URLSessionDelegate, OperationQueue) -> URLSession = {
      URLSession(configuration: $0, delegate: $1, delegateQueue: $2)
    }
  ) throws {
    self.upstreamDiagnostics = upstreamDiagnostics
    self.trafficScope = trafficScope
    self.opaqueRetention = opaqueRetention
    self.credentialContext = credentialContext
    headerPolicy = YlHlsHeaderPolicy(originURL: originURL, headers: headers, credentials: credentials)
    self.configuration = configuration
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(
      host: NWEndpoint.Host("127.0.0.1"),
      port: .any
    )
    listener = try NWListener(using: parameters)
    super.init()

    let delegateQueue = OperationQueue()
    delegateQueue.name = "dev.ylplayer.hls.media-proxy.url-session"
    delegateQueue.maxConcurrentOperationCount = 1
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.httpShouldSetCookies = false
    sessionConfiguration.httpCookieStorage = nil
    sessionConfiguration.urlCredentialStorage = nil
    sessionConfiguration.timeoutIntervalForRequest = TimeInterval(
      max(1, configuration.readTimeoutMs)
    ) / 1_000
    sessionConfiguration.timeoutIntervalForResource = TimeInterval(
      max(1, configuration.connectTimeoutMs + configuration.readTimeoutMs)
    ) / 1_000
    session = sessionFactory(sessionConfiguration, self, delegateQueue)

    let ready = DispatchSemaphore(value: 0)
    var startupError: NWError?
    listener.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        self?.lock.withLock { self?.listeningPort = self?.listener.port }
        ready.signal()
      case let .failed(error):
        startupError = error
        ready.signal()
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 2) == .success,
          startupError == nil,
          listeningPort != nil else {
      listener.cancel()
      session.invalidateAndCancel()
      throw NativePlayerError(
        category: "network",
        code: "network.local_proxy_unavailable",
        message: "The local HLS media proxy could not start.",
        diagnostic: startupError.map(YlAppleSafeDiagnostics.diagnostic)
      )
    }
  }

  func proxyURL(for destination: URL, credentialsStripped: Bool = false) throws -> URL {
    guard let scheme = destination.scheme?.lowercased(),
          (scheme == "http" || scheme == "https"),
          destination.host?.isEmpty == false else {
      throw NativePlayerError(
        category: "container",
        code: "container.hls_url_invalid",
        message: "HLS media resources must use HTTP or HTTPS URLs."
      )
    }
    let port = try lock.withLock { () -> NWEndpoint.Port in
      guard !cancelled, let listeningPort else {
        throw NativePlayerError(
          category: "cancelled",
          code: "network.cancelled",
          message: "The HLS media proxy is no longer active."
        )
      }
      return listeningPort
    }
    var components = URLComponents()
    components.scheme = "http"
    components.host = "127.0.0.1"
    components.port = Int(port.rawValue)
    if credentialsStripped { components.queryItems = [URLQueryItem(name: "credentialsStripped", value: "1")] }
    components.path = "/\(accessToken)/\(Self.encode(destination))/\(resourceName(for: destination))"
    guard let url = components.url else {
      throw NativePlayerError(
        category: "internal",
        code: "\(YlApplePlatform.current.rawValue).hls_loader_failed",
        message: "The local HLS media URL could not be created."
      )
    }
    return url
  }

  func cancelAll() {
    let activeConnections = lock.withLock { () -> [NWConnection] in
      guard !cancelled else { return [] }
      cancelled = true
      taskRecords.removeAll()
      connectionTasks.removeAll()
      let values = Array(connections.values)
      connections.removeAll()
      return values
    }
    upstreamDiagnostics.clear()
    listener.cancel()
    session.invalidateAndCancel()
    activeConnections.forEach { $0.cancel() }
  }

  deinit {
    cancelAll()
  }

  private func accept(_ connection: NWConnection) {
    let identifier = ObjectIdentifier(connection)
    let accepted = lock.withLock { () -> Bool in
      guard !cancelled else { return false }
      connections[identifier] = connection
      #if DEBUG
      diagnosticCounters["acceptedConnections", default: 0] += 1
      #endif
      return true
    }
    guard accepted else {
      connection.cancel()
      return
    }
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection else { return }
      if case .failed = state { self.close(connection) }
      if case .cancelled = state { self.close(connection) }
    }
    connection.start(queue: queue)
    receiveRequest(from: connection, accumulated: Data())
  }

  private func receiveRequest(from connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
      [weak self, weak connection] data, _, isComplete, error in
      guard let self, let connection else { return }
      if error != nil {
        self.close(connection)
        return
      }
      var requestData = accumulated
      if let data { requestData.append(data) }
      guard requestData.count <= 64 * 1024 else {
        self.send(status: 431, body: Data(), headers: [:], to: connection)
        return
      }
      if requestData.range(of: Data("\r\n\r\n".utf8)) != nil {
        guard self.handle(requestData, on: connection) else { return }
        if isComplete {
          self.close(connection)
        } else {
          self.monitorDisconnect(connection)
        }
      } else if isComplete {
        self.close(connection)
      } else {
        self.receiveRequest(from: connection, accumulated: requestData)
      }
    }
  }

  private func handle(_ data: Data, on connection: NWConnection) -> Bool {
    guard let text = String(data: data, encoding: .utf8),
          let headerEnd = text.range(of: "\r\n\r\n") else {
      send(status: 400, body: Data(), headers: [:], to: connection)
      return false
    }
    let lines = text[..<headerEnd.lowerBound].components(separatedBy: "\r\n")
    guard let first = lines.first else {
      send(status: 400, body: Data(), headers: [:], to: connection)
      return false
    }
    let requestParts = first.split(separator: " ")
    guard requestParts.count >= 2,
          requestParts[0] == "GET" || requestParts[0] == "HEAD" else {
      send(status: 405, body: Data(), headers: [:], to: connection)
      return false
    }
    let requestTarget = String(requestParts[1])
    let path = requestTarget.split(separator: "?", maxSplits: 1).first ?? ""
    guard let destination = destination(forRequestPath: String(path)) else {
      send(status: 404, body: Data(), headers: [:], to: connection)
      return false
    }
    let incomingHeaders = Self.headers(from: lines.dropFirst())
    let range = incomingHeaders["range"]
    let method = String(requestParts[0])
    let resourceKey = destination.absoluteString
    let stripped = Self.inheritsCredentialStripping(fromRequestTarget: requestTarget) || !headerPolicy.isSourceOrigin(destination) || credentialContext.isStripped(resourceKey)
    if stripped { credentialContext.strip(resourceKey) }
    let request = makeRequest(destination: destination, range: range, method: method, credentialsStripped: stripped)
    let admitted = lock.withLock { () -> Bool in
      // Cancellation and disconnect remove ownership under this same lock.
      // Creating a task after URLSession invalidation raises an ObjC exception;
      // even the task factory and resume must belong to this admission fence.
      guard !cancelled, connections[ObjectIdentifier(connection)] === connection else { return false }
      let task = session.dataTask(with: request)
      taskRecords[task.taskIdentifier] = TaskRecord(
        connection: connection,
        method: method,
        range: range, opaqueRetention: opaqueRetention
      )
      taskRecords[task.taskIdentifier]?.requestContext = headerPolicy.requestContext(for: destination, credentialsStripped: stripped)
      taskRecords[task.taskIdentifier]?.resourceKey = resourceKey
      connectionTasks[ObjectIdentifier(connection)] = task
      #if DEBUG
      diagnosticCounters["admittedRequests", default: 0] += 1
      diagnosticCounters["lastAdmissionUptime"] = ProcessInfo.processInfo.systemUptime
      #endif
      task.resume()
      return true
    }
    if !admitted { close(connection) }
    return admitted
  }

  private func monitorDisconnect(_ connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) {
      [weak self, weak connection] _, _, isComplete, error in
      guard let self, let connection else { return }
      if error != nil || isComplete {
        self.close(connection)
      } else {
        self.monitorDisconnect(connection)
      }
    }
  }

  private func makeRequest(
    destination: URL,
    range: String?,
    method: String = "GET",
    credentialsStripped: Bool = false
  ) -> URLRequest {
    var request = URLRequest(url: destination)
    request.httpMethod = method
    let ownedHeaders = Set(["range", "if-range", "host", "content-length"])
    for (name, value) in headerPolicy.headers(for: destination, credentialsStripped: credentialsStripped)
      where !ownedHeaders.contains(name.lowercased()) {
      request.setValue(value, forHTTPHeaderField: name)
    }
    if let range { request.setValue(range, forHTTPHeaderField: "Range") }
    return request
  }

  /// Completion ownership is independent of proxy cancellation and weak self.
  /// Kept as one seam so all response body/header/chunk-tail sends obey R18.
  func retainingPayloadCompletion(_ completion: @escaping (NWError?) -> Void) -> (NWError?) -> Void {
    { [opaqueRetention] error in
      defer { withExtendedLifetime(opaqueRetention) {} }; completion(error)
    }
  }

  private func send(
    status: Int,
    body: Data,
    headers: [String: String],
    to connection: NWConnection
  ) {
    var response = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
    for (name, value) in headers { response += "\(name): \(value)\r\n" }
    response += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    var payload = Data(response.utf8)
    payload.append(body)
    connection.send(content: payload, completion: .contentProcessed(retainingPayloadCompletion { [weak self] _ in
      self?.close(connection)
    }))
  }

  private func close(_ connection: NWConnection) {
    let task = lock.withLock { () -> URLSessionDataTask? in
      let identifier = ObjectIdentifier(connection)
      connections.removeValue(forKey: identifier)
      let task = connectionTasks.removeValue(forKey: identifier)
      if let task {
        #if DEBUG
        diagnosticCounters["closedWithActiveTask", default: 0] += 1
        #endif
        taskRecords.removeValue(forKey: task.taskIdentifier)
      }
      return task
    }
    task?.cancel()
    connection.cancel()
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let record = lock.withLock({ taskRecords[dataTask.taskIdentifier] }) else {
      completionHandler(.cancel)
      return
    }
    guard let response = response as? HTTPURLResponse else {
      let failure = NativePlayerError(category: "network", code: "network.response_invalid",
        message: "The media server returned an invalid response.")
      record.reportedFailure = failure
      upstreamDiagnostics.record(failure, resource: record.resourceKey)
      completionHandler(.cancel)
      return
    }
    record.httpStatus = response.statusCode
    if !(200...299).contains(response.statusCode), record.reportedFailure == nil {
      let failure = YlHTTPFailure.error(status: response.statusCode)
      record.reportedFailure = failure
      upstreamDiagnostics.record(failure, resource: record.resourceKey, httpStatus: record.httpStatus)
    } else if (200...299).contains(response.statusCode) {
      upstreamDiagnostics.succeeded(resource: record.resourceKey)
    }
    let declaredContentLength = response
      .value(forHTTPHeaderField: "Content-Length")
      .flatMap(Int64.init)
    let contentLength = declaredContentLength ?? response.expectedContentLength
    lock.withLock {
      record.responseStarted = true
      record.usesChunkedTransfer = contentLength < 0
      record.pendingSends += 1
    }
    var headers = [String: String]()
    for name in ["Content-Type", "Content-Range", "Accept-Ranges", "ETag"] {
      if let value = response.value(forHTTPHeaderField: name) {
        headers[name] = value
      }
    }
    if contentLength >= 0 {
      headers["Content-Length"] = String(contentLength)
    } else {
      headers["Transfer-Encoding"] = "chunked"
    }
    sendHead(
      status: response.statusCode,
      headers: headers,
      to: record.connection
    ) { [weak self, weak dataTask] error in
      guard let self, let dataTask else { return }
      self.responseSendDidComplete(
        error,
        task: dataTask,
        record: record,
        resumeTask: false
      )
    }
    completionHandler(.allow)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    guard let record = lock.withLock({ taskRecords[dataTask.taskIdentifier] }),
          record.method != "HEAD" else { return }
    #if DEBUG
    lock.withLock { diagnosticCounters["receivedBodyBytes", default: 0] += Double(data.count) }
    #endif
    trafficScope?.recordNetworkBytes(data.count)
    let payload: Data
    if record.usesChunkedTransfer {
      var chunk = Data(String(data.count, radix: 16).utf8)
      chunk.append(Data("\r\n".utf8))
      chunk.append(data)
      chunk.append(Data("\r\n".utf8))
      payload = chunk
    } else {
      payload = data
    }
    dataTask.suspend()
    lock.withLock { record.pendingSends += 1 }
    record.connection.send(
      content: payload,
      completion: .contentProcessed(retainingPayloadCompletion { [weak self, weak dataTask] error in
        guard let self, let dataTask else { return }
        self.responseSendDidComplete(
          error,
          task: dataTask,
          record: record,
          resumeTask: true
        )
      })
    )
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let destination = request.url else {
      completionHandler(nil)
      return
    }
    guard let record = lock.withLock({ taskRecords[task.taskIdentifier] }) else {
      completionHandler(nil)
      return
    }
    record.httpStatus = response.statusCode
    record.requestContext = record.requestContext?.child(at: destination, redirect: true)
    if record.credentialsStripped { credentialContext.strip(record.resourceKey) }
    guard record.redirectCount <= configuration.maxRedirects else {
      let failure = NativePlayerError(category: "network", code: "network.redirect_limit",
        message: "The media request exceeded the configured redirect limit.")
      record.reportedFailure = failure
      upstreamDiagnostics.record(failure, resource: record.resourceKey, httpStatus: record.httpStatus)
      completionHandler(nil)
      return
    }
    completionHandler(makeRequest(
      destination: destination,
      range: record.range,
      method: record.method,
      credentialsStripped: record.credentialsStripped
    ))
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    let outcome = lock.withLock { () -> (TaskRecord, Error?)? in
      #if DEBUG
      diagnosticCounters["upstreamCompletions", default: 0] += 1
      diagnosticCounters["lastCompletionUptime"] = ProcessInfo.processInfo.systemUptime
      if let error {
        let cancelled = (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
        diagnosticCounters[cancelled ? "cancelledCompletions" : "failedCompletions", default: 0] += 1
      }
      #endif
      guard let record = taskRecords[task.taskIdentifier] else { return nil }
      record.upstreamFinished = true
      record.upstreamError = error
      if let error, record.reportedFailure == nil {
        let failure = YlNetworkByteSource.transportError(error)
        upstreamDiagnostics.record(failure, resource: record.resourceKey, httpStatus: record.httpStatus)
      }
      guard record.pendingSends == 0 else { return nil }
      taskRecords.removeValue(forKey: task.taskIdentifier)
      connectionTasks.removeValue(forKey: ObjectIdentifier(record.connection))
      return (record, record.upstreamError)
    }
    guard let (record, error) = outcome else { return }
    finishProxyResponse(record, error: error)
  }

  static func inheritsCredentialStripping(fromRequestTarget target: String) -> Bool {
    URLComponents(string: target)?.queryItems?.contains {
      $0.name == "credentialsStripped" && $0.value == "1"
    } == true
  }

  static func completionAction(
    responseStarted: Bool,
    usesChunkedTransfer: Bool,
    method: String,
    error: Error?
  ) -> CompletionAction {
    guard responseStarted else { return .badGateway }
    guard error == nil else { return .close }
    return usesChunkedTransfer && method != "HEAD" ? .finishChunked : .close
  }

  static func badGatewayBody(_ error: Error?) -> Data {
    guard let error else { return Data() }
    let failure = YlAppleSafeDiagnostics.failure(YlNetworkByteSource.transportError(error), scope: .session)
    return Data("\(failure.code): \(failure.message)".utf8)
  }

  private func finishProxyResponse(_ record: TaskRecord, error: Error?) {
    switch Self.completionAction(
      responseStarted: record.responseStarted,
      usesChunkedTransfer: record.usesChunkedTransfer,
      method: record.method,
      error: error
    ) {
    case .badGateway:
      send(
        status: 502,
        body: Self.badGatewayBody(record.reportedFailure ?? error),
        headers: ["Content-Type": "text/plain; charset=utf-8"],
        to: record.connection
      )
    case .finishChunked:
      record.connection.send(
        content: Data("0\r\n\r\n".utf8),
        completion: .contentProcessed(retainingPayloadCompletion { [weak self] _ in
          self?.close(record.connection)
        })
      )
    case .close:
      close(record.connection)
    }
  }

  private func responseSendDidComplete(
    _ error: NWError?,
    task: URLSessionDataTask,
    record: TaskRecord,
    resumeTask: Bool
  ) {
    if error != nil {
      close(record.connection)
      return
    }
    let state = lock.withLock { () -> (current: Bool, finished: Bool, error: Error?) in
      guard taskRecords[task.taskIdentifier] === record else {
        return (false, false, nil)
      }
      record.pendingSends = max(0, record.pendingSends - 1)
      guard record.upstreamFinished, record.pendingSends == 0 else {
        return (true, false, nil)
      }
      taskRecords.removeValue(forKey: task.taskIdentifier)
      connectionTasks.removeValue(forKey: ObjectIdentifier(record.connection))
      return (true, true, record.upstreamError)
    }
    guard state.current else { return }
    if state.finished {
      finishProxyResponse(record, error: state.error)
    } else if resumeTask {
      task.resume()
    }
  }

  private func sendHead(
    status: Int,
    headers: [String: String],
    to connection: NWConnection,
    completion: @escaping (NWError?) -> Void
  ) {
    var response = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
    for (name, value) in headers { response += "\(name): \(value)\r\n" }
    response += "Connection: close\r\n\r\n"
    connection.send(
      content: Data(response.utf8),
      completion: .contentProcessed(retainingPayloadCompletion(completion))
    )
  }

  private static func headers<S: Sequence>(from lines: S) -> [String: String]
  where S.Element == String {
    var result = [String: String]()
    for line in lines {
      guard let separator = line.firstIndex(of: ":") else { continue }
      let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: separator)...]
        .trimmingCharacters(in: .whitespaces)
      result[name] = value
    }
    return result
  }

  private static func reason(_ status: Int) -> String {
    switch status {
    case 200: "OK"
    case 206: "Partial Content"
    case 400: "Bad Request"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 416: "Range Not Satisfiable"
    case 431: "Request Header Fields Too Large"
    default: status >= 500 ? "Bad Gateway" : "Response"
    }
  }

  private static func encode(_ destination: URL) -> String {
    Data(destination.absoluteString.utf8)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private func destination(forRequestPath path: String) -> URL? {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count >= 2, components[0] == Substring(accessToken) else {
      return nil
    }
    var payload = String(components[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = payload.count % 4
    if remainder != 0 {
      payload += String(repeating: "=", count: 4 - remainder)
    }
    guard let data = Data(base64Encoded: payload),
          let value = String(data: data, encoding: .utf8),
          let destination = URL(string: value),
          let scheme = destination.scheme?.lowercased(),
          (scheme == "http" || scheme == "https"),
          destination.host?.isEmpty == false else { return nil }
    return destination
  }

  private func resourceName(for destination: URL) -> String {
    destination.lastPathComponent.isEmpty ? "media" : destination.lastPathComponent
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
