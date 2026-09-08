import AVFoundation
import Foundation
import UniformTypeIdentifiers
#if os(iOS)
import MobileCoreServices
#endif

protocol YlHlsLoadingRequest: AnyObject {
  var url: URL { get }
  var requestedOffset: Int64 { get }
  var currentOffset: Int64 { get }
  var requestedLength: Int { get }
  var requestsAllDataToEnd: Bool { get }

  func setContentInformation(
    contentType: String?,
    contentLength: Int64,
    byteRangeAccessSupported: Bool
  )
  func redirect(to request: URLRequest)
  func respond(with data: Data)
  func finishLoading()
  func finishLoading(with error: NativePlayerError)
}

private final class YlAVAssetLoadingRequestAdapter: YlHlsLoadingRequest {
  let loadingRequest: AVAssetResourceLoadingRequest
  let url: URL

  init?(_ loadingRequest: AVAssetResourceLoadingRequest) {
    guard let url = loadingRequest.request.url else { return nil }
    self.loadingRequest = loadingRequest
    self.url = url
  }

  var requestedOffset: Int64 {
    loadingRequest.dataRequest?.requestedOffset ?? 0
  }

  var currentOffset: Int64 {
    loadingRequest.dataRequest?.currentOffset ?? requestedOffset
  }

  var requestedLength: Int {
    loadingRequest.dataRequest?.requestedLength ?? 0
  }

  var requestsAllDataToEnd: Bool {
    loadingRequest.dataRequest?.requestsAllDataToEndOfResource ?? true
  }

  func setContentInformation(
    contentType: String?,
    contentLength: Int64,
    byteRangeAccessSupported: Bool
  ) {
    loadingRequest.contentInformationRequest?.contentType = contentType
    loadingRequest.contentInformationRequest?.contentLength = contentLength
    loadingRequest.contentInformationRequest?.isByteRangeAccessSupported =
      byteRangeAccessSupported
  }

  func respond(with data: Data) {
    loadingRequest.dataRequest?.respond(with: data)
  }

  func redirect(to request: URLRequest) {
    loadingRequest.redirect = request
    loadingRequest.response = HTTPURLResponse(
      url: request.url ?? url,
      statusCode: 302,
      httpVersion: "HTTP/1.1",
      headerFields: ["Location": request.url?.absoluteString ?? ""]
    )
  }

  func finishLoading() {
    loadingRequest.finishLoading()
  }

  func finishLoading(with error: NativePlayerError) {
    loadingRequest.finishLoading(with: error)
  }
}

final class YlHlsResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
  static let manifestByteLimit = 2 * 1024 * 1024

  private struct CachedResponse {
    let data: Data
    let contentType: String?
    let contentLength: Int64
    let byteRangeAccessSupported: Bool
  }

  private final class TaskRecord {
    let request: YlHlsLoadingRequest
    let cacheKey: String
    let rangeHeader: String?
    let requestedStart: Int64
    let requestedLength: Int?
    var destinationURL: URL
    var isManifest: Bool
    var response: HTTPURLResponse?
    var manifestData = Data()
    var redirectCount = 0
    var credentialsStripped = false
    var bytesToSkip: Int64 = 0
    var bytesDelivered = 0
    var task: URLSessionDataTask?

    init(
      request: YlHlsLoadingRequest,
      destinationURL: URL,
      rangeHeader: String?,
      isManifest: Bool
    ) {
      self.request = request
      self.destinationURL = destinationURL
      cacheKey = destinationURL.absoluteString
      self.rangeHeader = rangeHeader
      requestedStart = max(0, request.currentOffset == 0
        ? request.requestedOffset : request.currentOffset)
      requestedLength = request.requestsAllDataToEnd || request.requestedLength <= 0
        ? nil : request.requestedLength
      self.isManifest = isManifest
    }
  }

  private final class PreflightRequest: YlHlsLoadingRequest {
    let url: URL
    let requestedOffset: Int64 = 0
    let currentOffset: Int64 = 0
    let requestedLength: Int = 0
    let requestsAllDataToEnd = true
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private(set) var data = Data()
    private(set) var error: NativePlayerError?
    private var finished = false

    init(url: URL) {
      self.url = url
    }

    func setContentInformation(
      contentType: String?,
      contentLength: Int64,
      byteRangeAccessSupported: Bool
    ) {}

    func respond(with data: Data) {
      lock.withLock { self.data.append(data) }
    }

    func redirect(to request: URLRequest) {
      finish(error: NativePlayerError(
        category: "internal",
        code: "\(YlApplePlatform.current.rawValue).hls_loader_failed",
        message: "A manifest preflight unexpectedly requested a redirect."
      ))
    }

    func finishLoading() { finish(error: nil) }
    func finishLoading(with error: NativePlayerError) { finish(error: error) }

    private func finish(error: NativePlayerError?) {
      let shouldSignal = lock.withLock { () -> Bool in
        guard !finished else { return false }
        finished = true
        self.error = error
        return true
      }
      if shouldSignal { semaphore.signal() }
    }
  }

  let resourceLoaderQueue = DispatchQueue(
    label: "dev.ylplayer.hls.resource-loader",
    qos: .userInitiated
  )

  private let originURL: URL
  private var strippedResources = Set<String>()
  private let hasExplicitCredentials: Bool
  private let headerPolicy: YlHlsHeaderPolicy
  private let configuration: YlNetworkConfiguration
  private let mediaProxy: YlHlsMediaProxy
  private let stateLock = NSLock()
  private var records: [Int: TaskRecord] = [:]
  private var cachedResponses: [String: CachedResponse] = [:]
  private var cancelled = false
  private var session: URLSession!

  init(
    originURL: URL,
    headers: [String: String],
    credentials: [String: String] = [:],
    configuration: YlNetworkConfiguration,
    sessionConfiguration: URLSessionConfiguration = .ephemeral
  ) throws {
    self.originURL = originURL
    self.hasExplicitCredentials = !credentials.isEmpty
    self.headerPolicy = YlHlsHeaderPolicy(originURL: originURL, headers: headers, credentials: credentials)
    self.configuration = configuration
    self.mediaProxy = try YlHlsMediaProxy(
      originURL: originURL,
      headers: headers,
      credentials: credentials,
      configuration: configuration
    )
    super.init()

    let sessionConfiguration = sessionConfiguration.copy()
      as? URLSessionConfiguration ?? sessionConfiguration
    sessionConfiguration.httpShouldSetCookies = false
    sessionConfiguration.httpCookieStorage = nil
    sessionConfiguration.timeoutIntervalForRequest = TimeInterval(
      max(1, configuration.readTimeoutMs)
    ) / 1_000
    sessionConfiguration.timeoutIntervalForResource = TimeInterval(
      max(1, configuration.connectTimeoutMs + configuration.readTimeoutMs)
    ) / 1_000
    let delegateQueue = OperationQueue()
    delegateQueue.name = "dev.ylplayer.hls.url-session"
    delegateQueue.maxConcurrentOperationCount = 1
    delegateQueue.qualityOfService = .userInitiated
    session = URLSession(
      configuration: sessionConfiguration,
      delegate: self,
      delegateQueue: delegateQueue
    )
  }

  func encodedAssetURL() throws -> URL {
    try YlHlsURLCodec.encode(originURL, kind: .manifest)
  }

  @discardableResult
  func startLoading(_ loadingRequest: YlHlsLoadingRequest) -> Bool {
    let destination: URL
    let resourceKind: YlHlsResourceKind
    do {
      destination = try YlHlsURLCodec.decode(loadingRequest.url)
      resourceKind = try YlHlsURLCodec.resourceKind(loadingRequest.url)
    } catch let error as NativePlayerError {
      loadingRequest.finishLoading(with: error)
      return true
    } catch {
      loadingRequest.finishLoading(with: Self.internalError(error))
      return true
    }

    let cacheKey = destination.absoluteString
    let credentialsStripped = YlHlsURLCodec.credentialsStripped(loadingRequest.url) || !headerPolicy.isSourceOrigin(destination) || stateLock.withLock { strippedResources.contains(cacheKey) }
    let loaderState = stateLock.withLock {
      (cancelled: cancelled, cached: cachedResponses["\(credentialsStripped):\(cacheKey)"])
    }
    if loaderState.cancelled {
      loadingRequest.finishLoading(with: Self.cancelledError())
      return true
    }
    if let cached = loaderState.cached {
      respond(cached, to: loadingRequest)
      return true
    }

    let isManifest = resourceKind == .manifest
    let rangeHeader = isManifest ? nil : Self.rangeHeader(for: loadingRequest)
    if resourceKind == .media {
      do {
        if hasExplicitCredentials {
          var proxyRequest = URLRequest(url: try mediaProxy.proxyURL(for: destination, credentialsStripped: credentialsStripped))
          if let rangeHeader { proxyRequest.setValue(rangeHeader, forHTTPHeaderField: "Range") }
          loadingRequest.redirect(to: proxyRequest)
        } else {
          // Preserve the absent-metadata v1 route. V2 credential sources always
          // use the controlled proxy so AVFoundation cannot restore credentials.
          loadingRequest.redirect(to: makeRequest(url: destination, rangeHeader: rangeHeader, credentialsStripped: credentialsStripped))
        }
      } catch {
        loadingRequest.finishLoading(with: Self.internalError(error))
        return true
      }
      loadingRequest.finishLoading()
      return true
    }
    let request = makeRequest(url: destination, rangeHeader: rangeHeader, credentialsStripped: credentialsStripped)
    let record = TaskRecord(
      request: loadingRequest,
      destinationURL: destination,
      rangeHeader: rangeHeader,
      isManifest: isManifest
    )
    record.credentialsStripped = credentialsStripped
    let task = session.dataTask(with: request)
    record.task = task
    let accepted = stateLock.withLock { () -> Bool in
      guard !cancelled else { return false }
      records[task.taskIdentifier] = record
      return true
    }
    guard accepted else {
      loadingRequest.finishLoading(with: Self.cancelledError())
      return true
    }
    task.resume()
    return true
  }

  func preflight(cancellationToken: YlOpenCancellationToken) throws {
    try cancellationToken.throwIfCancelled()
    cancellationToken.onCancel { [weak self] in self?.cancelAll() }
    let request = PreflightRequest(url: try encodedAssetURL())
    _ = startLoading(request)
    let maximumWaitMs = max(
      1_000,
      configuration.connectTimeoutMs + configuration.readTimeoutMs + 1_000
    )
    if request.semaphore.wait(
      timeout: .now() + .milliseconds(Int(maximumWaitMs))
    ) == .timedOut {
      cancelAll()
      throw NativePlayerError(
        category: "network",
        code: "network.read_timeout",
        message: "The HLS manifest preflight timed out."
      )
    }
    try cancellationToken.throwIfCancelled()
    if let error = request.error { throw error }
  }

  func cancelAll() {
    let pending = stateLock.withLock { () -> [TaskRecord] in
      guard !cancelled else { return [] }
      cancelled = true
      let pending = Array(records.values)
      records.removeAll()
      cachedResponses.removeAll()
      return pending
    }
    for record in pending {
      record.task?.cancel()
      record.request.finishLoading(with: Self.cancelledError())
    }
    session.invalidateAndCancel()
    mediaProxy.cancelAll()
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    guard let adapter = YlAVAssetLoadingRequestAdapter(loadingRequest) else {
      loadingRequest.finishLoading(with: NativePlayerError(
        category: "container",
        code: "container.hls_url_invalid",
        message: "The HLS resource request URL is missing."
      ))
      return true
    }
    return startLoading(adapter)
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    let matching = stateLock.withLock { () -> TaskRecord? in
      guard let pair = records.first(where: {
        ($0.value.request as? YlAVAssetLoadingRequestAdapter)?.loadingRequest
          === loadingRequest
      }) else { return nil }
      records.removeValue(forKey: pair.key)
      return pair.value
    }
    matching?.task?.cancel()
  }

  deinit {
    cancelAll()
  }

  private func makeRequest(url: URL, rangeHeader: String?, credentialsStripped: Bool = false) -> URLRequest {
    var request = URLRequest(url: url)
    request.timeoutInterval = TimeInterval(max(1, configuration.readTimeoutMs)) / 1_000
    let ownedHeaders = Set(["range", "if-range", "host", "content-length"])
    for (name, value) in headerPolicy.headers(for: url, credentialsStripped: credentialsStripped)
      where !ownedHeaders.contains(name.lowercased()) {
      request.setValue(value, forHTTPHeaderField: name)
    }
    if let rangeHeader {
      request.setValue(rangeHeader, forHTTPHeaderField: "Range")
    }
    return request
  }

  private func respond(_ cached: CachedResponse, to request: YlHlsLoadingRequest) {
    request.setContentInformation(
      contentType: cached.contentType,
      contentLength: cached.contentLength,
      byteRangeAccessSupported: cached.byteRangeAccessSupported
    )
    request.respond(with: Self.requestedSlice(of: cached.data, for: request))
    request.finishLoading()
  }

  private func finish(
    task: URLSessionTask,
    result: Result<CachedResponse?, NativePlayerError>
  ) {
    let record = stateLock.withLock { () -> TaskRecord? in
      guard let record = records.removeValue(forKey: task.taskIdentifier) else {
        return nil
      }
      if !cancelled,
         case let .success(cached?) = result,
         record.cacheKey == originURL.absoluteString {
        cachedResponses["\(record.credentialsStripped):\(record.cacheKey)"] = cached
      }
      return record
    }
    guard let record else { return }
    switch result {
    case let .success(cached):
      if let cached {
        respond(cached, to: record.request)
      } else {
        record.request.finishLoading()
      }
    case let .failure(error):
      task.cancel()
      record.request.finishLoading(with: error)
    }
  }

  private func record(for task: URLSessionTask) -> TaskRecord? {
    stateLock.withLock { records[task.taskIdentifier] }
  }

  private func isCurrent(_ record: TaskRecord, task: URLSessionTask) -> Bool {
    stateLock.withLock { records[task.taskIdentifier] === record }
  }

  private static func requestedSlice(
    of data: Data,
    for request: YlHlsLoadingRequest
  ) -> Data {
    let offset = max(0, request.currentOffset == 0
      ? request.requestedOffset : request.currentOffset)
    guard offset < data.count else { return Data() }
    let start = Int(offset)
    let end: Int
    if request.requestsAllDataToEnd || request.requestedLength <= 0 {
      end = data.count
    } else {
      end = min(data.count, start + request.requestedLength)
    }
    return data.subdata(in: start..<end)
  }

  private static func rangeHeader(for request: YlHlsLoadingRequest) -> String? {
    let offset = max(0, request.currentOffset == 0
      ? request.requestedOffset : request.currentOffset)
    if request.requestsAllDataToEnd {
      return offset > 0 ? "bytes=\(offset)-" : nil
    }
    guard request.requestedLength > 0 else { return nil }
    let addition = Int64(request.requestedLength - 1)
    let end = offset.addingReportingOverflow(addition)
    guard !end.overflow else { return "bytes=\(offset)-" }
    return "bytes=\(offset)-\(end.partialValue)"
  }

  private static func isManifestResponse(_ response: HTTPURLResponse) -> Bool {
    guard let mime = response.mimeType?.lowercased() else { return false }
    return mime.contains("mpegurl") || mime.contains("m3u")
  }

  private static func contentType(_ response: HTTPURLResponse) -> String? {
    guard let mime = response.mimeType else { return nil }
    if #available(iOS 14.0, macOS 14.0, *) {
      return UTType(mimeType: mime)?.identifier ?? mime
    }
    return UTTypeCreatePreferredIdentifierForTag(
      kUTTagClassMIMEType,
      mime as CFString,
      nil
    )?.takeRetainedValue() as String? ?? mime
  }

  private static func responseContentLength(_ response: HTTPURLResponse) -> Int64 {
    if response.statusCode == 206,
       let range = parsedContentRange(response) {
      return range.total
    }
    return max(0, response.expectedContentLength)
  }

  private static func parsedContentRange(
    _ response: HTTPURLResponse
  ) -> (start: Int64, total: Int64)? {
    guard let value = response.value(forHTTPHeaderField: "Content-Range"),
          value.lowercased().hasPrefix("bytes "),
          let space = value.firstIndex(of: " "),
          let dash = value[value.index(after: space)...].firstIndex(of: "-"),
          let slash = value[dash...].firstIndex(of: "/"),
          let start = Int64(value[value.index(after: space)..<dash]),
          let total = Int64(value[value.index(after: slash)...]) else { return nil }
    return (start, total)
  }

  private static func supportsByteRanges(_ response: HTTPURLResponse) -> Bool {
    response.statusCode == 206
      || response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
  }

  private static func transportError(_ error: Error) -> NativePlayerError {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
      return NativePlayerError(
        category: "network",
        code: "network.read_timeout",
        message: "The HLS resource request timed out."
      )
    }
    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
      return cancelledError()
    }
    return NativePlayerError(
      category: "network",
      code: "network.http_status",
      message: "The HLS resource request failed.",
      diagnostic: "\(nsError.domain) \(nsError.code)"
    )
  }

  private static func cancelledError() -> NativePlayerError {
    NativePlayerError(
      category: "cancelled",
      code: "network.cancelled",
      message: "The HLS resource request was cancelled."
    )
  }

  private static func internalError(_ error: Error) -> NativePlayerError {
    NativePlayerError(
      category: "internal",
      code: "\(YlApplePlatform.current.rawValue).hls_loader_failed",
      message: "The HLS resource loader failed.",
      diagnostic: String(describing: error)
    )
  }
}

extension YlHlsResourceLoader: URLSessionDataDelegate, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let record = record(for: dataTask),
          let response = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      if record(for: dataTask) != nil {
        finish(task: dataTask, result: .failure(NativePlayerError(
          category: "network",
          code: "network.http_status",
          message: "The HLS server returned an invalid response."
        )))
      }
      return
    }
    guard (200...299).contains(response.statusCode) else {
      completionHandler(.cancel)
      finish(task: dataTask, result: .failure(NativePlayerError(
        category: "network",
        code: "network.http_status",
        message: "The HLS server rejected the resource request.",
        diagnostic: "HTTP \(response.statusCode)"
      )))
      return
    }
    record.response = response
    record.destinationURL = response.url ?? record.destinationURL
    record.isManifest = record.isManifest || Self.isManifestResponse(response)
    if response.statusCode == 206 {
      guard let range = Self.parsedContentRange(response),
            range.start == record.requestedStart else {
        completionHandler(.cancel)
        finish(task: dataTask, result: .failure(NativePlayerError(
          category: "network",
          code: "network.range_invalid",
          message: "The HLS byte-range response is invalid."
        )))
        return
      }
    } else if !record.isManifest {
      record.bytesToSkip = record.requestedStart
    }
    if record.isManifest,
       response.expectedContentLength > Self.manifestByteLimit {
      completionHandler(.cancel)
      finish(task: dataTask, result: .failure(NativePlayerError(
        category: "resource",
        code: "resource.hls_manifest_too_large",
        message: "The HLS manifest exceeds the 2 MiB limit."
      )))
      return
    }
    if !record.isManifest {
      record.request.setContentInformation(
        contentType: Self.contentType(response),
        contentLength: Self.responseContentLength(response),
        byteRangeAccessSupported: Self.supportsByteRanges(response)
      )
    }
    completionHandler(.allow)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    guard let record = record(for: dataTask), isCurrent(record, task: dataTask)
    else { return }
    if record.isManifest {
      guard record.manifestData.count + data.count <= Self.manifestByteLimit else {
        finish(task: dataTask, result: .failure(NativePlayerError(
          category: "resource",
          code: "resource.hls_manifest_too_large",
          message: "The HLS manifest exceeds the 2 MiB limit."
        )))
        return
      }
      record.manifestData.append(data)
    } else {
      var payload = data
      if record.bytesToSkip > 0 {
        let skipped = min(Int64(payload.count), record.bytesToSkip)
        payload.removeFirst(Int(skipped))
        record.bytesToSkip -= skipped
      }
      if let requestedLength = record.requestedLength {
        let remaining = max(0, requestedLength - record.bytesDelivered)
        if payload.count > remaining { payload = Data(payload.prefix(remaining)) }
      }
      guard !payload.isEmpty else { return }
      record.bytesDelivered += payload.count
      record.request.respond(with: payload)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    guard let record = record(for: task) else { return }
    if let error {
      finish(task: task, result: .failure(Self.transportError(error)))
      return
    }
    guard record.isManifest else {
      finish(task: task, result: .success(nil))
      return
    }
    do {
      let rewritten = try YlHlsManifestRewriter.rewrite(
        data: record.manifestData,
        baseURL: record.destinationURL,
        credentialsStripped: record.credentialsStripped,
        mediaURL: { [mediaProxy] in try mediaProxy.proxyURL(for: $0, credentialsStripped: record.credentialsStripped) }
      )
      let response = record.response
      finish(task: task, result: .success(CachedResponse(
        data: rewritten,
        contentType: response.flatMap(Self.contentType),
        contentLength: Int64(rewritten.count),
        byteRangeAccessSupported: false
      )))
    } catch let error as NativePlayerError {
      finish(task: task, result: .failure(error))
    } catch {
      finish(task: task, result: .failure(Self.internalError(error)))
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let record = record(for: task), let destination = request.url else {
      completionHandler(nil)
      return
    }
    record.credentialsStripped = record.credentialsStripped || !headerPolicy.isSourceOrigin(destination)
    if record.credentialsStripped { _ = stateLock.withLock { strippedResources.insert(record.cacheKey) } }
    record.redirectCount += 1
    guard record.redirectCount <= configuration.maxRedirects else {
      completionHandler(nil)
      finish(task: task, result: .failure(NativePlayerError(
        category: "network",
        code: "network.redirect_limit",
        message: "The HLS redirect limit was exceeded."
      )))
      return
    }
    do {
      _ = try YlHlsURLCodec.encode(destination)
    } catch {
      completionHandler(nil)
      finish(task: task, result: .failure(NativePlayerError(
        category: "network",
        code: "network.redirect_invalid",
        message: "The HLS redirect target is invalid."
      )))
      return
    }
    record.destinationURL = destination
    completionHandler(makeRequest(url: destination, rangeHeader: record.rangeHeader, credentialsStripped: record.credentialsStripped))
  }
}

final class YlPreparedHlsAsset {
  let asset: AVURLAsset
  let loader: YlHlsResourceLoader
  private let ownershipLock = NSLock()
  private var ownsLoader = true

  init(
    originURL: URL,
    headers: [String: String],
    credentials: [String: String] = [:],
    configuration: YlNetworkConfiguration,
    cancellationToken: YlOpenCancellationToken,
    sessionConfiguration: URLSessionConfiguration = .ephemeral
  ) throws {
    let loader = try YlHlsResourceLoader(
      originURL: originURL,
      headers: headers,
      credentials: credentials,
      configuration: configuration,
      sessionConfiguration: sessionConfiguration
    )
    self.loader = loader
    do {
      try loader.preflight(cancellationToken: cancellationToken)
      let asset = AVURLAsset(url: try loader.encodedAssetURL())
      asset.resourceLoader.setDelegate(loader, queue: loader.resourceLoaderQueue)
      self.asset = asset
    } catch {
      loader.cancelAll()
      throw error
    }
  }

  func discard() {
    let shouldCancel = ownershipLock.withLock { () -> Bool in
      guard ownsLoader else { return false }
      ownsLoader = false
      return true
    }
    if shouldCancel { loader.cancelAll() }
  }

  func takeLoader() throws -> YlHlsResourceLoader {
    try ownershipLock.withLock {
      guard ownsLoader else {
        throw NativePlayerError(
          category: "internal",
          code: "internal.fallback_invariant",
          message: "The prepared HLS asset was already consumed."
        )
      }
      ownsLoader = false
      return loader
    }
  }

  deinit {
    discard()
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
