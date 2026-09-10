@testable import yl_player_apple
import Foundation
import Network
import Security
import XCTest

private final class ScriptedURLProtocol: URLProtocol {
  struct ResponseScript {
    let status: Int?
    let headers: [String: String]
    let chunks: [(delay: TimeInterval, data: Data)]
    let failure: URLError.Code?
    let finishes: Bool
    var redirect: URL? = nil

    static func response(
      status: Int,
      headers: [String: String] = [:],
      chunks: [(TimeInterval, Data)] = [],
      failure: URLError.Code? = nil,
      finishes: Bool = true
    ) -> Self {
      Self(
        status: status,
        headers: headers,
        chunks: chunks,
        failure: failure,
        finishes: finishes
      )
    }

    static func failure(_ code: URLError.Code) -> Self {
      Self(status: nil, headers: [:], chunks: [], failure: code, finishes: false)
    }

    static func redirect(to url: URL) -> Self {
      Self(status: nil, headers: [:], chunks: [], failure: nil, finishes: false, redirect: url)
    }

    static func stall() -> Self {
      Self(status: nil, headers: [:], chunks: [], failure: nil, finishes: false)
    }
  }

  private static let stateLock = NSLock()
  private static var nextIdentifier = 0
  private static var scriptsByHost = [String: [ResponseScript]]()
  private static var requestsByHost = [String: [URLRequest]]()
  private static var latestHost = ""

  private let stopLock = NSLock()
  private var stopped = false

  static func configure(_ values: [ResponseScript]) -> URL {
    stateLock.lock()
    nextIdentifier += 1
    let host = "test-\(nextIdentifier).media.test"
    scriptsByHost[host] = values
    requestsByHost[host] = []
    latestHost = host
    stateLock.unlock()
    return URL(string: "https://\(host)/movie.mkv?token=secret")!
  }

  static func append(_ scripts: [ResponseScript], to url: URL) {
    stateLock.lock()
    scriptsByHost[url.host!, default: []].append(contentsOf: scripts)
    stateLock.unlock()
  }
  static func recordedRequests(at url: URL) -> [URLRequest] {
    stateLock.lock()
    defer { stateLock.unlock() }
    return requestsByHost[url.host!] ?? []
  }

  static var recordedRequests: [URLRequest] {
    stateLock.lock()
    defer { stateLock.unlock() }
    return requestsByHost[latestHost] ?? []
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    Self.stateLock.lock()
    let host = request.url?.host ?? ""
    Self.requestsByHost[host, default: []].append(request)
    var scripts = Self.scriptsByHost[host] ?? []
    let script = scripts.isEmpty
      ? ResponseScript.failure(.resourceUnavailable)
      : scripts.removeFirst()
    Self.scriptsByHost[host] = scripts
    Self.stateLock.unlock()

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self, !self.isStopped else { return }
      if let destination = script.redirect {
        let response = HTTPURLResponse(url: self.request.url!, statusCode: 302,
          httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString])!
        self.client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
        return
      }
      if let status = script.status {
        let response = HTTPURLResponse(
          url: self.request.url!,
          statusCode: status,
          httpVersion: "HTTP/1.1",
          headerFields: script.headers
        )!
        self.client?.urlProtocol(
          self,
          didReceive: response,
          cacheStoragePolicy: .notAllowed
        )
        Thread.sleep(forTimeInterval: 0.002)
      }
      for chunk in script.chunks {
        if chunk.delay > 0 { Thread.sleep(forTimeInterval: chunk.delay) }
        guard !self.isStopped else { return }
        self.client?.urlProtocol(self, didLoad: chunk.data)
        Thread.sleep(forTimeInterval: 0.002)
      }
      guard !self.isStopped else { return }
      if let failure = script.failure {
        // Preserve real URLSession ordering: the final data delegate callback
        // must be delivered before the transport completion callback.
        Thread.sleep(forTimeInterval: 0.05)
        guard !self.isStopped else { return }
        self.client?.urlProtocol(
          self,
          didFailWithError: URLError(failure)
        )
      } else {
        guard script.finishes else { return }
        self.client?.urlProtocolDidFinishLoading(self)
      }
    }
  }

  override func stopLoading() {
    stopLock.lock()
    stopped = true
    stopLock.unlock()
  }

  private var isStopped: Bool {
    stopLock.lock()
    defer { stopLock.unlock() }
    return stopped
  }
}

final class YlNetworkByteSourceTests: XCTestCase {
  func testActualRequestsKeepExplicitCredentialsStrippedAcrossRedirectRetryAndReopen() throws {
    let original = ScriptedURLProtocol.configure([])
    let other = ScriptedURLProtocol.configure([.redirect(to: original)])
    ScriptedURLProtocol.append([.redirect(to: other), .response(status: 503),
      .response(status: 200, headers: ["Content-Length": "1"], chunks: [(0, Data([7]))]),
      .response(status: 200, headers: ["Content-Length": "1"], chunks: [(0, Data([8]))]),
      .response(status: 200, headers: ["Content-Length": "1"], chunks: [(0, Data([9]))])], to: original)
    let configuration = YlNetworkConfiguration(map: ["maxRetries": 1, "baseRetryDelayMs": 0])
    let recipe = YlNetworkRequestRecipe(url: original, headers: ["X-Display": "visible"],
      credentials: ["X-Private-Identity": "private", "aUtHoRiZaTiOn": "secret"], configuration: configuration)
    let session = URLSessionConfiguration.ephemeral
    session.protocolClasses = [ScriptedURLProtocol.self]
    func reader(_ request: YlNetworkRequestRecipe) -> YlNetworkByteSource {
      YlNetworkByteSource(recipe: request, capacity: 32, sessionConfiguration: session)
    }
    let initial = reader(recipe)
    defer { initial.cancel() }
    XCTAssertEqual(try readToEnd(initial), [7])
    let firstRequests = ScriptedURLProtocol.recordedRequests(at: original)
    XCTAssertEqual(firstRequests.count, 3, "Initial, returned-origin and retry requests must all execute")
    XCTAssertEqual(firstRequests.first?.value(forHTTPHeaderField: "X-Private-Identity"), "private")
    for request in Array(firstRequests.dropFirst()) + ScriptedURLProtocol.recordedRequests(at: other) {
      XCTAssertNil(request.value(forHTTPHeaderField: "X-Private-Identity"))
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-Display"), "visible")
    }
    let reopened = reader(recipe)
    defer { reopened.cancel() }
    XCTAssertEqual(try readToEnd(reopened), [8])
    XCTAssertNil(ScriptedURLProtocol.recordedRequests(at: original).last?.value(forHTTPHeaderField: "X-Private-Identity"))
    let newIntent = reader(YlNetworkRequestRecipe(url: original, headers: recipe.headers,
      credentials: recipe.credentials, configuration: configuration))
    defer { newIntent.cancel() }
    XCTAssertEqual(try readToEnd(newIntent), [9])
    XCTAssertEqual(ScriptedURLProtocol.recordedRequests(at: original).last?.value(forHTTPHeaderField: "X-Private-Identity"), "private")
  }

  func testUnknownInspectionUsesOwnedRedirectCredentialRulesAndPreservesContext() throws {
    let body = Data("#EXTM3U\n#EXT-X-ENDLIST\n".utf8)
    let other = ScriptedURLProtocol.configure([.response(status: 200, chunks: [(0, body)])])
    let original = ScriptedURLProtocol.configure([.redirect(to: other)])
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScriptedURLProtocol.self]
    let source = YlAppleSourceDescriptor(uri: original.absoluteString, kind: .network,
      headers: ["X-Display": "ordinary"], credentials: ["X-Private-Identity": "private"])
    let inspected = try YlSourceInspector.inspect(source, configuration: .init(map: [:]),
      token: .init(), sessionConfiguration: configuration)
    XCTAssertEqual(inspected.formatHint, .hls)
    XCTAssertTrue(inspected.credentialContext === source.credentialContext)
    XCTAssertEqual(ScriptedURLProtocol.recordedRequests(at: original).first?.value(forHTTPHeaderField: "X-Private-Identity"), "private")
    let redirected = try XCTUnwrap(ScriptedURLProtocol.recordedRequests(at: other).first)
    XCTAssertNil(redirected.value(forHTTPHeaderField: "X-Private-Identity"))
    XCTAssertEqual(redirected.value(forHTTPHeaderField: "X-Display"), "ordinary")
    XCTAssertEqual(YlEngineRouter.assess(inspected).candidate, .headeredHls)
  }

  private func makeSource(
    scripts: [ScriptedURLProtocol.ResponseScript],
    capacity: Int = 32,
    configuration: [String: Any?] = [:],
    headers: [String: String] = [:],
    mode: YlNetworkInputMode = .randomAccessVOD,
    retries: ((Int, Int64, NativePlayerError) -> Void)? = nil
  ) -> YlNetworkByteSource {
    let url = ScriptedURLProtocol.configure(scripts)
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [ScriptedURLProtocol.self]
    return YlNetworkByteSource(
      recipe: YlNetworkRequestRecipe(
        url: url,
        headers: headers,
        configuration: YlNetworkConfiguration(map: configuration),
        mode: mode
      ),
      capacity: capacity,
      sessionConfiguration: sessionConfiguration,
      onRetry: retries
    )
  }

  private func readToEnd(
    _ source: YlNetworkByteSource,
    chunkSize: Int = 32
  ) throws -> [UInt8] {
    var output = [UInt8]()
    var scratch = [UInt8](repeating: 0, count: chunkSize)
    while true {
      let count = try scratch.withUnsafeMutableBytes { try source.read(into: $0) }
      if count == 0 { return output }
      output.append(contentsOf: scratch.prefix(count))
    }
  }

  private func nativeError(_ body: () throws -> Any) -> NativePlayerError {
    do {
      _ = try body()
      XCTFail("Expected byte source failure")
    } catch let YlByteSourceError.failed(error) {
      return error
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    return NativePlayerError(category: "test", code: "test.missing", message: "")
  }

  private func activeTask(
    _ source: YlNetworkByteSource,
    requestCount: Int = 1
  ) throws -> URLSessionDataTask {
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
      if ScriptedURLProtocol.recordedRequests.count >= requestCount,
         let task = source.debugActiveTask {
        return task
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.002))
    }
    return try XCTUnwrap(source.debugActiveTask, "Network task did not start")
  }

  private func deliver(
    to source: YlNetworkByteSource,
    task: URLSessionDataTask,
    status: Int,
    headers: [String: String],
    data: Data
  ) {
    let response = HTTPURLResponse(
      url: task.currentRequest!.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
    source.urlSession(
      URLSession.shared,
      dataTask: task,
      didReceive: response,
      completionHandler: { disposition in
        XCTAssertEqual(disposition, .allow)
      }
    )
    source.urlSession(URLSession.shared, dataTask: task, didReceive: data)
  }

  func testPartialFailureResumesAtExactOffsetWhenRangeWasConfirmed() throws {
    let source = makeSource(scripts: [
      .stall(),
      .response(
        status: 206,
        headers: ["Content-Range": "bytes 6-11/12", "ETag": "\"v1\""],
        chunks: [(0, Data([6, 7, 8, 9, 10, 11]))]
      ),
    ], configuration: ["readTimeoutMs": 5_000, "baseRetryDelayMs": 0])
    defer { source.cancel() }

    let firstTask = try activeTask(source)
    deliver(
      to: source,
      task: firstTask,
      status: 206,
      headers: ["Content-Range": "bytes 0-5/12", "ETag": "\"v1\""],
      data: Data([0, 1, 2, 3, 4, 5])
    )
    source.urlSession(
      URLSession.shared,
      task: firstTask,
      didCompleteWithError: URLError(.networkConnectionLost)
    )

    XCTAssertEqual(try readToEnd(source), Array(0...11))
    let requests = ScriptedURLProtocol.recordedRequests
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Range"), "bytes=6-")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-Range"), "\"v1\"")
    XCTAssertEqual(source.length, 12)
    XCTAssertTrue(source.supportsRandomAccess)
  }

  func testSequential200DrainsToEOFWithoutRetry() throws {
    let source = makeSource(scripts: [
      .response(
        status: 200,
        headers: ["Content-Length": "4"],
        chunks: [(0, Data([1, 2])), (0, Data([3, 4]))]
      ),
    ])
    defer { source.cancel() }

    XCTAssertEqual(try readToEnd(source, chunkSize: 2), [1, 2, 3, 4])
    XCTAssertEqual(source.length, 4)
    XCTAssertFalse(source.supportsRandomAccess)
    XCTAssertEqual(ScriptedURLProtocol.recordedRequests.count, 1)
  }

  func testSequentialLiveChunkedResponseWaitsForTaskCompletion() throws {
    let source = makeSource(
      scripts: [
        .response(
          status: 200,
          chunks: [(0, Data([1, 2])), (0.02, Data([3, 4]))]
        ),
      ],
      mode: .sequentialLive
    )
    defer { source.cancel() }

    XCTAssertEqual(try readToEnd(source, chunkSize: 2), [1, 2, 3, 4])
    XCTAssertNil(source.length)
    XCTAssertFalse(source.supportsRandomAccess)
    XCTAssertNil(ScriptedURLProtocol.recordedRequests[0]
      .value(forHTTPHeaderField: "Range"))
  }

  func testSequentialLiveRejectsNonzeroSeek() {
    let source = makeSource(
      scripts: [.stall()],
      mode: .sequentialLive
    )
    defer { source.cancel() }

    let received = nativeError { try source.seek(to: 1) }
    XCTAssertEqual(received.code, "network.range_not_supported")
  }

  func testPartialSequentialLiveFailureSurfacesWithoutInContextRetry() throws {
    let source = makeSource(
      scripts: [
        .stall(),
        .response(status: 200, chunks: [(0, Data([3, 4]))]),
      ],
      configuration: ["readTimeoutMs": 5_000, "baseRetryDelayMs": 0],
      mode: .sequentialLive
    )
    defer { source.cancel() }

    let task = try activeTask(source)
    deliver(
      to: source,
      task: task,
      status: 200,
      headers: [:],
      data: Data([1, 2])
    )
    source.urlSession(
      URLSession.shared,
      task: task,
      didCompleteWithError: URLError(.networkConnectionLost)
    )

    var first = [UInt8](repeating: 0, count: 2)
    XCTAssertEqual(
      try first.withUnsafeMutableBytes { try source.read(into: $0) },
      2
    )
    XCTAssertEqual(first, [1, 2])
    let received = nativeError {
      var next = [UInt8](repeating: 0, count: 1)
      return try next.withUnsafeMutableBytes { try source.read(into: $0) }
    }
    XCTAssertEqual(received.code, "network.http_status")
    XCTAssertEqual(ScriptedURLProtocol.recordedRequests.count, 1)
  }

  func testSeekOutsideRetainedWindowStartsExactRangeRequest() throws {
    let source = makeSource(
      scripts: [
        .response(
          status: 206,
          headers: ["Content-Range": "bytes 0-11/12", "ETag": "\"v1\""],
          chunks: [(0, Data(0...11))]
        ),
        .response(
          status: 206,
          headers: ["Content-Range": "bytes 6-11/12", "ETag": "\"v1\""],
          chunks: [(0, Data(6...11))]
        ),
      ],
      capacity: 4
    )
    defer { source.cancel() }

    XCTAssertEqual(try readToEnd(source, chunkSize: 4), Array(0...11))
    XCTAssertEqual(try source.seek(to: 6), 6)
    XCTAssertEqual(try readToEnd(source, chunkSize: 4), Array(6...11))

    let requests = ScriptedURLProtocol.recordedRequests
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Range"), "bytes=6-")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-Range"), "\"v1\"")
  }

  func testMemoryWarningShrinksLargeCacheToTwoMiB() {
    let source = makeSource(scripts: [.stall()], capacity: 8 * 1024 * 1024)
    defer { source.cancel() }

    source.handleMemoryWarning()

    XCTAssertEqual(source.bufferCapacity, 2 * 1024 * 1024)
  }

  func testPartialSequentialFailureDoesNotRetry() throws {
    let source = makeSource(scripts: [
      .stall(),
      .response(status: 200, chunks: [(0, Data([3, 4]))]),
    ], configuration: ["readTimeoutMs": 5_000, "baseRetryDelayMs": 0])
    defer { source.cancel() }

    let task = try activeTask(source)
    deliver(
      to: source,
      task: task,
      status: 200,
      headers: ["Content-Length": "4"],
      data: Data([1, 2])
    )
    source.urlSession(
      URLSession.shared,
      task: task,
      didCompleteWithError: URLError(.networkConnectionLost)
    )

    var first = [UInt8](repeating: 0, count: 2)
    XCTAssertEqual(
      try first.withUnsafeMutableBytes { try source.read(into: $0) },
      2
    )
    XCTAssertEqual(first, [1, 2])
    let received = nativeError {
      var next = [UInt8](repeating: 0, count: 2)
      return try next.withUnsafeMutableBytes { try source.read(into: $0) }
    }
    XCTAssertEqual(received.code, "network.retry_exhausted")
    XCTAssertEqual(ScriptedURLProtocol.recordedRequests.count, 1)
  }

  func testReadTimeoutRestartsAfterEveryChunk() throws {
    let source = makeSource(scripts: [
      .response(
        status: 200,
        headers: ["Content-Length": "3"],
        chunks: [
          (0.02, Data([1])),
          (0.02, Data([2])),
          (0.02, Data([3])),
        ]
      ),
    ], configuration: ["readTimeoutMs": 45, "maxRetries": 0])
    defer { source.cancel() }

    XCTAssertEqual(try readToEnd(source, chunkSize: 1), [1, 2, 3])
  }

  func testRetryExhaustionIsStableAndReportsAttempts() {
    let retryLock = NSLock()
    var attempts = [Int]()
    let source = makeSource(
      scripts: [
        .failure(.cannotConnectToHost),
        .failure(.networkConnectionLost),
        .failure(.timedOut),
      ],
      configuration: ["maxRetries": 2, "baseRetryDelayMs": 0],
      retries: { attempt, _, _ in
        retryLock.lock()
        attempts.append(attempt)
        retryLock.unlock()
      }
    )
    defer { source.cancel() }

    let received = nativeError {
      var byte = [UInt8](repeating: 0, count: 1)
      return try byte.withUnsafeMutableBytes { try source.read(into: $0) }
    }
    XCTAssertEqual(received.code, "network.retry_exhausted")
    retryLock.lock()
    XCTAssertEqual(attempts, [1, 2])
    retryLock.unlock()
    XCTAssertEqual(ScriptedURLProtocol.recordedRequests.count, 3)
  }

  func testRetryableHTTPStatusesReachSuccessfulAttempt() throws {
    let source = makeSource(scripts: [
      .response(status: 408),
      .response(status: 429),
      .response(status: 503),
      .response(
        status: 200,
        headers: ["Content-Length": "1"],
        chunks: [(0, Data([7]))]
      ),
    ], configuration: ["maxRetries": 3, "baseRetryDelayMs": 0])
    defer { source.cancel() }

    XCTAssertEqual(try readToEnd(source), [7])
    XCTAssertEqual(ScriptedURLProtocol.recordedRequests.count, 4)
  }

  func testCancellationWakesBlockedRead() {
    let source = makeSource(scripts: [
      .response(
        status: 200,
        chunks: [(5, Data([1]))]
      ),
    ], configuration: ["connectTimeoutMs": 5_000, "readTimeoutMs": 5_000])
    let started = expectation(description: "read started")
    let finished = expectation(description: "read cancelled")
    DispatchQueue.global().async {
      started.fulfill()
      var byte = [UInt8](repeating: 0, count: 1)
      do {
        _ = try byte.withUnsafeMutableBytes { try source.read(into: $0) }
        XCTFail("Expected cancellation")
      } catch {
        guard case YlByteSourceError.cancelled = error else {
          return XCTFail("Unexpected error: \(error)")
        }
      }
      finished.fulfill()
    }
    wait(for: [started], timeout: 1)

    source.cancel()

    wait(for: [finished], timeout: 1)
  }

  func testValidatorChangeFailsWithoutAppendingSecondRepresentation() throws {
    let source = makeSource(scripts: [
      .stall(),
      .response(
        status: 206,
        headers: ["Content-Range": "bytes 2-3/4", "ETag": "\"v2\""],
        chunks: [(0, Data([8, 9]))]
      ),
    ], configuration: ["readTimeoutMs": 5_000, "baseRetryDelayMs": 0])
    defer { source.cancel() }

    let task = try activeTask(source)
    deliver(
      to: source,
      task: task,
      status: 206,
      headers: ["Content-Range": "bytes 0-1/4", "ETag": "\"v1\""],
      data: Data([1, 2])
    )
    source.urlSession(
      URLSession.shared,
      task: task,
      didCompleteWithError: URLError(.networkConnectionLost)
    )

    var first = [UInt8](repeating: 0, count: 2)
    XCTAssertEqual(
      try first.withUnsafeMutableBytes { try source.read(into: $0) },
      2
    )
    XCTAssertEqual(first, [1, 2])
    let received = nativeError {
      var next = [UInt8](repeating: 0, count: 2)
      return try next.withUnsafeMutableBytes { try source.read(into: $0) }
    }
    XCTAssertEqual(received.code, "network.content_changed")
  }

  func testRingCapacityIsNeverExceededUnderBackpressure() throws {
    let bytes = Data((0..<128).map { UInt8($0) })
    let source = makeSource(scripts: [
      .response(
        status: 200,
        headers: ["Content-Length": "128"],
        chunks: [(0, bytes)]
      ),
    ], capacity: 7)
    defer { source.cancel() }

    XCTAssertEqual(try readToEnd(source, chunkSize: 3), Array(0..<128))
    XCTAssertLessThanOrEqual(source.debugBufferedBytes, 7)
    XCTAssertEqual(source.bufferCapacity, 7)
  }

  func testDiagnosticsNeverContainQueryOrCredentialValues() {
    let source = makeSource(
      scripts: [.response(status: 403)],
      configuration: ["maxRetries": 0],
      headers: ["Authorization": "Bearer header-secret"]
    )
    defer { source.cancel() }

    let received = nativeError {
      var byte = [UInt8](repeating: 0, count: 1)
      return try byte.withUnsafeMutableBytes { try source.read(into: $0) }
    }
    XCTAssertEqual(received.code, "network.http_status")
    XCTAssertFalse(received.diagnostic?.contains("secret") ?? true)
    XCTAssertFalse(received.diagnostic?.contains("token") ?? true)
  }
  private func managedReader(url: URL, mode: YlNetworkInputMode = .randomAccessVOD,
    intent: YlManagedRequestIntent = YlManagedRequestIntent(),
    options: YlAppleNetworkOptions = .init(connectTimeoutMs: 1000, readTimeoutMs: 1000,
      maxRetries: 1, baseRetryDelayMs: 0, maxRetryDelayMs: 10, maxRedirects: 5),
    policy: YlManagedRequestPolicy = YlManagedRequestPolicy(),
    retry: YlNetworkByteSource.RetryCallback? = nil) -> YlNetworkByteSource {
    let session = URLSessionConfiguration.ephemeral
    session.protocolClasses = [ScriptedURLProtocol.self]
    return YlNetworkByteSource(recipe: YlNetworkRequestRecipe(url: url,
      headers: ["X-Display": "visible"], credentials: ["X-Private": "secret"],
      configuration: YlNetworkConfiguration(options: options), mode: mode, managedIntent: intent),
      capacity: 4096, sessionConfiguration: session, onRetry: retry, managedPolicy: policy, managedTransportFactory: nil)
  }

  func testManagedLiveRetriesInitialFailureButDoesNotReopenExhaustedIntent() throws {
    let url = ScriptedURLProtocol.configure([.response(status: 503),
      .response(status: 200, chunks: [(0, Data([1, 2, 3]))])])
    let source = managedReader(url: url, mode: .sequentialLive)
    defer { source.cancel() }
    XCTAssertEqual(try readToEnd(source), [1, 2, 3])
    XCTAssertEqual(ScriptedURLProtocol.recordedRequests(at: url).count, 2)
    let failedURL = ScriptedURLProtocol.configure([.response(status: 503), .response(status: 503)])
    let intent = YlManagedRequestIntent()
    let failed = managedReader(url: failedURL, mode: .sequentialLive, intent: intent)
    defer { failed.cancel() }
    XCTAssertEqual(nativeError { try readToEnd(failed) }.code, "network.retry_exhausted")
    let reopened = managedReader(url: failedURL, mode: .sequentialLive, intent: intent)
    defer { reopened.cancel() }
    XCTAssertEqual(nativeError { try readToEnd(reopened) }.code, "network.retry_exhausted")
    XCTAssertEqual(ScriptedURLProtocol.recordedRequests(at: failedURL).count, 2)
  }

  func testManagedRetryAfterExceedingCapDoesNotRetryEarly() {
    let url = ScriptedURLProtocol.configure([.response(status: 429, headers: ["Retry-After": "1"]),
      .response(status: 200, chunks: [(0, Data([9]))])])
    let source = managedReader(url: url)
    defer { source.cancel() }
    XCTAssertEqual(nativeError { try readToEnd(source) }.code, "network.retry_exhausted")
    XCTAssertEqual(ScriptedURLProtocol.recordedRequests(at: url).count, 1)
  }

  func testManagedPermanentAndCertificateFailuresNeverRetry() {
    for script in [ScriptedURLProtocol.ResponseScript.response(status: 501), .response(status: 401),
                   .failure(.serverCertificateUntrusted), .failure(.cancelled)] {
      let url = ScriptedURLProtocol.configure([script, .response(status: 200)])
      let source = managedReader(url: url)
      _ = nativeError { try readToEnd(source) }
      source.cancel()
      XCTAssertEqual(ScriptedURLProtocol.recordedRequests(at: url).count, 1)
    }
  }

  func testManagedConnectDeadlineAndReadInactivityAreIndependent() throws {
    let options = YlAppleNetworkOptions(connectTimeoutMs: 200, readTimeoutMs: 500,
      maxRetries: 0, baseRetryDelayMs: 0, maxRetryDelayMs: 0, maxRedirects: 5)
    let url = ScriptedURLProtocol.configure([.response(status: 200, headers: ["Content-Type": "application/octet-stream"],
      chunks: [(0.3, Data([1])), (0.3, Data([2])), (0.3, Data([3]))])])
    let source = managedReader(url: url, options: options)
    defer { source.cancel() }
    XCTAssertEqual(try readToEnd(source), [1, 2, 3], "Body may exceed connect and total read deadlines when progress continues")
    let stallURL = ScriptedURLProtocol.configure([.stall()])
    let stalled = managedReader(url: stallURL, options: options)
    defer { stalled.cancel() }
    XCTAssertEqual(nativeError { try readToEnd(stalled) }.code, "network.retry_exhausted")
    XCTAssertEqual(ScriptedURLProtocol.recordedRequests(at: stallURL).count, 1)
  }

  func testManagedRedirectHopRearmsConnectAndCancelsOldTimer() throws {
    let lock = NSLock()
    var callbacks = [() -> Void]()
    var delays = [Int64]()
    let policy = YlManagedRequestPolicy(schedule: { delay, callback in
      lock.lock(); callbacks.append(callback); delays.append(delay); lock.unlock()
      return {}
    })
    let url = ScriptedURLProtocol.configure([.stall()])
    let source = managedReader(url: url, policy: policy)
    defer { source.cancel() }
    let task = try activeTask(source)
    let destination = url.appendingPathComponent("hop")
    source.urlSession(URLSession.shared, task: task,
      willPerformHTTPRedirection: HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!,
      newRequest: URLRequest(url: destination)) { XCTAssertNotNil($0) }
    lock.lock(); let old = callbacks[0]; let captured = delays; lock.unlock()
    old()
    XCTAssertEqual(captured, [1000, 1000])
    XCTAssertNotNil(source.debugActiveTask)
    source.cancel()
    lock.lock(); let remaining = callbacks; lock.unlock()
    remaining.forEach { $0() }
    XCTAssertEqual(ScriptedURLProtocol.recordedRequests(at: url).count, 1)
  }

  func testManagedCancellationCancelsScheduledRetryAndStaleCallbacks() throws {
    let retryScheduled = expectation(description: "Retry scheduled")
    let lock = NSLock()
    var retryCallback: (() -> Void)?
    let policy = YlManagedRequestPolicy(schedule: { delay, callback in
      if delay == 0 { lock.lock(); retryCallback = callback; lock.unlock(); retryScheduled.fulfill() }
      return {}
    })
    let url = ScriptedURLProtocol.configure([.response(status: 503), .response(status: 200)])
    let source = managedReader(url: url, policy: policy)
    wait(for: [retryScheduled], timeout: 2)
    source.cancel()
    lock.lock(); let callback = retryCallback; lock.unlock()
    callback?()
    XCTAssertEqual(ScriptedURLProtocol.recordedRequests(at: url).count, 1)
  }

  func testManagedUnknownInspectionUsesExactOptionsAndOriginalIntent() {
    let url = ScriptedURLProtocol.configure([.response(status: 503), .response(status: 503)])
    let session = URLSessionConfiguration.ephemeral
    session.protocolClasses = [ScriptedURLProtocol.self]
    let source = YlAppleSourceDescriptor(uri: url.absoluteString, kind: .network,
      networkPolicy: .managed, networkConfiguration: .init(connectTimeoutMs: 25, readTimeoutMs: 25,
        maxRetries: 1, baseRetryDelayMs: 0, maxRetryDelayMs: 0, maxRedirects: 0))
    XCTAssertEqual(nativeError {
      try YlSourceInspector.inspect(source, configuration: .init(map: ["maxRetries": 0]),
        token: .init(), sessionConfiguration: session, managedTransportFactory: nil)
    }.code, "network.retry_exhausted")
    XCTAssertEqual(ScriptedURLProtocol.recordedRequests(at: url).count, 2)
    XCTAssertNotNil(source.managedRequestIntent.terminalFailure)
  }

  func testManagedAuthenticatedMatroskaAndFlvPrepareThroughOwnedByteSources() throws {
    for (name, fileExtension, format) in [("h264_aac", "mkv", YlSourceFormat.matroska),
                                       ("h264_mp3", "flv", YlSourceFormat.flv)] {
      let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: fileExtension))
      let lock = NSLock()
      var requests = [String]()
      let server = try ReactivationMediaServer(data: Data(contentsOf: fixture),
        requiredHeaders: ["X-Private": "secret", "X-Display": "visible"], onRequest: { request in
          lock.lock(); requests.append(request); lock.unlock()
        })
      defer { server.close() }
      let source = YlAppleSourceDescriptor(uri: server.url.absoluteString, kind: .network,
        formatHint: format, headers: ["X-Display": "visible"], credentials: ["X-Private": "secret"],
        networkPolicy: .managed, networkConfiguration: .init(connectTimeoutMs: 90000, readTimeoutMs: 120000,
          maxRetries: 25, baseRetryDelayMs: 0, maxRetryDelayMs: 90000, maxRedirects: 25))
      let assessment = YlEngineRouter.assess(source)
      XCTAssertEqual(assessment.candidate, format == .flv ? .networkFlv : .networkMatroska)
      let prepared = try YlPreparedFallback(source: source, requireHardwareProbe: false)
      guard case let .network(recipe, _) = prepared.sourceRecipe else { XCTFail("Expected package network input"); continue }
      XCTAssertTrue(recipe.managedIntent === source.managedRequestIntent)
      XCTAssertEqual(recipe.configuration.connectTimeoutMs, 90000)
      XCTAssertEqual(recipe.configuration.readTimeoutMs, 120000)
      XCTAssertEqual(recipe.configuration.maxRetries, 25)
      XCTAssertEqual(prepared.container, format == .flv ? .flv : .matroska)
      lock.lock(); let captured = requests; lock.unlock()
      XCTAssertFalse(captured.isEmpty)
      XCTAssertTrue(captured.allSatisfy { $0.contains("x-private: secret") && $0.contains("x-display: visible") })
    }
  }

  func testManagedUnknownInspectionPreparesFallbackWithStickyCredentialLineage() throws {
    for (name, ext, format) in [("h264_aac", "mkv", YlSourceFormat.matroska), ("h264_mp3", "flv", .flv)] {
      let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
      let lock = NSLock(); var downstream = [String]()
      let media = try ReactivationMediaServer(data: Data(contentsOf: fixture), requiredHeaders: ["X-Display": "visible"],
        onRequest: { request in lock.lock(); downstream.append(request); lock.unlock() })
      defer { media.close() }
      let redirect = try ManagedScriptServer { _ in
        "HTTP/1.1 302 Found\r\nLocation: \(media.url.absoluteString)\r\nContent-Length: 0\r\n\r\n"
      }
      defer { redirect.close() }
      let source = YlAppleSourceDescriptor(uri: redirect.url.absoluteString, kind: .network,
        headers: ["X-Display": "visible"], credentials: ["X-Private": "secret"], networkPolicy: .managed,
        networkConfiguration: .init(connectTimeoutMs: 3000, readTimeoutMs: 3000, maxRetries: 1,
          baseRetryDelayMs: 0, maxRetryDelayMs: 0, maxRedirects: 8))
      XCTAssertEqual(YlEngineRouter.assess(source).candidate, .inspect)
      let inspected = try YlSourceInspector.inspect(source, configuration: .init(map: [:]), token: .init())
      XCTAssertEqual(inspected.formatHint, format)
      XCTAssertTrue(inspected.managedRequestIntent === source.managedRequestIntent)
      let prepared = try YlPreparedFallback(source: inspected, requireHardwareProbe: false)
      XCTAssertEqual(prepared.container, format == .flv ? .flv : .matroska)
      XCTAssertNil(source.managedRequestIntent.terminalFailure)
      let roots = redirect.requests
      XCTAssertGreaterThanOrEqual(roots.count, 2)
      XCTAssertTrue(roots.first?.raw.contains("x-private: secret") ?? false)
      XCTAssertTrue(roots.dropFirst().allSatisfy { !$0.raw.contains("x-private:") })
      lock.lock(); let captured = downstream; lock.unlock()
      XCTAssertGreaterThanOrEqual(captured.count, 2)
      XCTAssertTrue(captured.allSatisfy { !$0.contains("x-private:") && $0.contains("x-display: visible") })
    }
  }

  func testManagedFailedRealInspectionCannotReopenWithFreshRetryBudget() throws {
    let server = try ManagedScriptServer { _ in "HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\n\r\n" }
    defer { server.close() }
    var source = YlAppleSourceDescriptor(uri: server.url.absoluteString, kind: .network,
      networkPolicy: .managed, networkConfiguration: .init(connectTimeoutMs: 1000, readTimeoutMs: 1000,
        maxRetries: 1, baseRetryDelayMs: 0, maxRetryDelayMs: 0, maxRedirects: 0))
    XCTAssertEqual(nativeError { try YlSourceInspector.inspect(source, configuration: .init(map: [:]), token: .init()) }.code,
      "network.retry_exhausted")
    XCTAssertEqual(server.requests.count, 2)
    source.formatHint = .matroska
    XCTAssertThrowsError(try YlPreparedFallback(source: source, requireHardwareProbe: false))
    XCTAssertEqual(server.requests.count, 2, "Preparation cannot bypass exhausted original inspection intent")
  }

  func testManagedUnsupportedFormatsRejectBeforeOpeningLoopback() throws {
    let lock = NSLock()
    var requests = 0
    let server = try ReactivationMediaServer(data: Data([1]), onRequest: { _ in
      lock.lock(); requests += 1; lock.unlock()
    })
    defer { server.close() }
    for format in [YlSourceFormat.hls, .mp4, .mov, .avi, .mpegTs, .mpegPs] {
      let source = YlAppleSourceDescriptor(uri: server.url.absoluteString, kind: .network,
        formatHint: format, credentials: ["X-Private": "secret"], networkPolicy: .managed)
      let result = YlEngineRouter.assess(source)
      XCTAssertEqual(result.rejection?.code, "policy.unsupported")
      XCTAssertNil(result.candidate)
      let failure = YlAppleFailureMapper.message(try XCTUnwrap(result.rejection), scope: .command)
      XCTAssertFalse(failure.diagnosticId.isEmpty)
      XCTAssertFalse(failure.message.contains(server.url.absoluteString))
      XCTAssertFalse(failure.message.contains("secret"))
    }
    lock.lock(); let count = requests; lock.unlock()
    XCTAssertEqual(count, 0)
  }

  func testManagedRedirectBudgetAndCredentialsSurviveActualRetry() {
    let original = ScriptedURLProtocol.configure([])
    let other = ScriptedURLProtocol.configure([.redirect(to: original)])
    ScriptedURLProtocol.append([.redirect(to: other), .response(status: 503), .redirect(to: other)], to: original)
    let source = managedReader(url: original, options: .init(connectTimeoutMs: 1000, readTimeoutMs: 1000,
      maxRetries: 2, baseRetryDelayMs: 0, maxRetryDelayMs: 0, maxRedirects: 2))
    defer { source.cancel() }
    XCTAssertEqual(nativeError { try readToEnd(source) }.code, "network.redirect_limit")
    let requests = ScriptedURLProtocol.recordedRequests(at: original)
    XCTAssertEqual(requests.count, 3)
    XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-Private"), "secret")
    XCTAssertTrue(requests.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "X-Private") == nil })
    XCTAssertEqual(ScriptedURLProtocol.recordedRequests(at: other).count, 1)
  }

  func testHlsProxyForwardsCredentialHeadersOnlyToAuthenticatedOrigin() throws {
    for name in ["Authorization", "Cookie"] {
      let body = Data([1, 2, 3])
      let server = try ReactivationMediaServer(data: body, requiredHeaders: [name: "secret"])
      defer { server.close() }
      let proxy = try YlHlsMediaProxy(originURL: server.url, headers: [name: "secret"],
        configuration: YlNetworkConfiguration(map: [:]))
      defer { proxy.cancelAll() }
      let done = expectation(description: name)
      let session = URLSession(configuration: .ephemeral)
      defer { session.invalidateAndCancel() }
      session.dataTask(with: try proxy.proxyURL(for: server.url)) { data, response, error in
        XCTAssertNil(error)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, body)
        done.fulfill()
      }.resume()
      wait(for: [done], timeout: 5)
    }
  }

  func testCompatibilityURLSessionHeaderVisibilityDependsOnMime() throws {
    for mime in [false, true] {
      let url = ScriptedURLProtocol.configure([.response(status: 200,
        headers: mime ? ["Content-Type": "application/octet-stream"] : [:],
        chunks: [(0.5, Data([1, 2, 3]))])])
      let lock = NSLock()
      var scheduled = [Int64]()
      let policy = YlManagedRequestPolicy(schedule: { delay, _ in
        lock.lock(); scheduled.append(delay); lock.unlock(); return {}
      })
      let source = managedReader(url: url, options: .init(connectTimeoutMs: 200, readTimeoutMs: 1000,
        maxRetries: 0, baseRetryDelayMs: 0, maxRetryDelayMs: 0, maxRedirects: 0), policy: policy)
      defer { source.cancel() }
      let task = try activeTask(source)
      let observed = expectation(description: "headers before first body")
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
        lock.lock(); let timers = scheduled; lock.unlock()
        let detail = "mime=\(mime), response=\(task.response != nil), received=\(task.countOfBytesReceived), timers=\(timers)"
        let attachment = XCTAttachment(string: detail)
        attachment.lifetime = .keepAlways
        self.add(attachment)
        XCTAssertEqual(task.response != nil, mime, detail)
        observed.fulfill()
      }
      wait(for: [observed], timeout: 2)
      XCTAssertEqual(try readToEnd(source), [1, 2, 3])
    }
  }

  func testLoopbackHeaderObservationBeforeBodyWithAndWithoutMime() throws {
    for mime in [false, true] {
      let server = try HeaderBoundaryServer(mime: mime, fragmented: true)
      defer { server.close() }
      let lock = NSLock()
      var scheduled = [Int64]()
      let policy = YlManagedRequestPolicy(schedule: { delay, action in
        lock.lock(); scheduled.append(delay); lock.unlock()
        let work = DispatchWorkItem(block: action)
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(delay) / 1000, execute: work)
        return { work.cancel() }
      })
      let source = YlNetworkByteSource(recipe: .init(url: server.url, headers: [:],
        configuration: .init(options: .init(connectTimeoutMs: 200, readTimeoutMs: 1000,
          maxRetries: 0, baseRetryDelayMs: 0, maxRetryDelayMs: 0, maxRedirects: 0)),
        managedIntent: .init()), capacity: 4096, managedPolicy: policy)
      defer { source.cancel() }
      XCTAssertEqual(server.headersSent.wait(timeout: .now() + 2), .success)
      let observed = expectation(description: "real headers before first body")
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
        lock.lock(); let timers = scheduled; lock.unlock()
        let detail = "loopback mime=\(mime), headerSendCompleted=true, timers=\(timers)"
        let attachment = XCTAttachment(string: detail); attachment.lifetime = .keepAlways; self.add(attachment)
        XCTAssertEqual(timers, [200, 1000], detail)
        observed.fulfill()
      }
      wait(for: [observed], timeout: 2)
      XCTAssertEqual(try readToEnd(source), [1, 2, 3])
    }
  }

  func testManagedTLSValidatesIsolatedAnchorAndRejectsUntrustedAndHostnameMismatch() throws {
    for (certificate, anchored, succeeds) in [(ManagedTLSFixture.localhost, true, true),
                                             (ManagedTLSFixture.localhost, false, false),
                                             (ManagedTLSFixture.mismatch, true, false)] {
      let server = try ManagedTLSTestServer(p12: certificate)
      defer { server.close() }
      let options = YlNetworkConfiguration(options: .init(connectTimeoutMs: 3000, readTimeoutMs: 1000,
        maxRetries: 2, baseRetryDelayMs: 0, maxRetryDelayMs: 0, maxRedirects: 0))
      var attempts = 0
      let source = YlNetworkByteSource(recipe: .init(url: server.url, headers: [:], configuration: options,
        managedIntent: .init()), capacity: 4096, managedTransportFactory: { request, callback in
          attempts += 1
          return try YlManagedHTTPTransport(request: request, receive: callback, configureTLS: anchored ? { tls in
            ManagedTLSFixture.anchor(tls, hostname: request.url!.host!)
          } : nil)
        })
      defer { source.cancel() }
      if succeeds { XCTAssertEqual(try readToEnd(source), [1, 2, 3]) }
      else {
        let error = nativeError { try readToEnd(source) }
        XCTAssertEqual(error.code, "network.http_status")
        XCTAssertEqual(error.diagnostic, "transport.-1202")
      }
      XCTAssertEqual(attempts, 1, "Certificate validation failures are never retryable")
    }
  }

  func testManagedRealRedirectRetryPreservesBudgetAndCredentialStripping() throws {
    var otherURL: URL!
    let original = try ManagedScriptServer { request in
      if request.path == "/returned" { return "HTTP/1.1 503 Retry\r\nRetry-After: 0\r\nContent-Length: 0\r\n\r\n" }
      return "HTTP/1.1 302 Found\r\nLocation: \(otherURL.absoluteString)\r\nContent-Length: 0\r\n\r\n"
    }
    defer { original.close() }
    let other = try ManagedScriptServer { _ in
      "HTTP/1.1 302 Found\r\nLocation: \(original.url.appendingPathComponent("returned").absoluteString)\r\nContent-Length: 0\r\n\r\n"
    }
    otherURL = other.url
    defer { other.close() }
    let source = YlNetworkByteSource(recipe: .init(url: original.url, headers: ["X-Display": "visible"],
      credentials: ["X-Private": "secret"], configuration: .init(options: .init(connectTimeoutMs: 1000,
        readTimeoutMs: 1000, maxRetries: 2, baseRetryDelayMs: 0, maxRetryDelayMs: 0, maxRedirects: 2)),
      managedIntent: .init()), capacity: 32)
    defer { source.cancel() }
    XCTAssertEqual(nativeError { try readToEnd(source) }.code, "network.redirect_limit")
    let local = original.requests
    XCTAssertEqual(local.count, 3)
    XCTAssertTrue(local.first?.raw.contains("x-private: secret") ?? false)
    XCTAssertTrue(local.dropFirst().allSatisfy { !$0.raw.contains("x-private:") })
    XCTAssertEqual(other.requests.count, 1)
    XCTAssertFalse(other.requests.first?.raw.contains("x-private:") ?? true)
    XCTAssertTrue((local + other.requests).allSatisfy { $0.raw.contains("x-display: visible") })
  }

  func testManagedRealPrematureEOFRetryUsesRangeAndRepresentationValidator() throws {
    let server = try ManagedScriptServer { request in
      if request.raw.contains("range: bytes=2-") {
        return "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 2-3/4\r\nContent-Length: 2\r\nETag: \"v1\"\r\n\r\ncd"
      }
      return "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-3/4\r\nContent-Length: 4\r\nETag: \"v1\"\r\n\r\nab"
    }
    defer { server.close() }
    let source = YlNetworkByteSource(recipe: .init(url: server.url, headers: [:],
      configuration: .init(map: ["baseRetryDelayMs": 0]), managedIntent: .init()), capacity: 32)
    defer { source.cancel() }
    XCTAssertEqual(try readToEnd(source), Array("abcd".utf8))
    XCTAssertEqual(server.requests.count, 2)
    XCTAssertTrue(server.requests.last?.raw.contains("if-range: \"v1\"") ?? false)
  }

  func testManagedRealChunkedAndConnectionCloseBodies() throws {
    for wire in ["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nab\r\n1\r\nc\r\n0\r\n\r\n",
                 "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nabc"] {
      let server = try ManagedScriptServer { _ in wire }; defer { server.close() }
      let source = YlNetworkByteSource(recipe: .init(url: server.url, headers: [:],
        configuration: .init(map: [:]), managedIntent: .init()), capacity: 32)
      defer { source.cancel() }
      XCTAssertEqual(try readToEnd(source), Array("abc".utf8))
    }
  }

  func testManagedRealInvalidFramingAndCustomProxyRejectWithoutRetry() throws {
    for wire in ["HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
                 "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nxyz\r\n",
                 "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-2/3\r\nContent-Length: 1\r\n\r\na"] {
      let server = try ManagedScriptServer { _ in wire }; defer { server.close() }
      let source = YlNetworkByteSource(recipe: .init(url: server.url, headers: [:],
        configuration: .init(map: [:]), managedIntent: .init()), capacity: 32)
      defer { source.cancel() }
      let error = nativeError { try readToEnd(source) }
      XCTAssertTrue(["network.response_invalid", "network.range_invalid"].contains(error.code))
      XCTAssertEqual(server.requests.count, 1)
    }
    let server = try ManagedScriptServer { _ in "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" }
    defer { server.close() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 9]
    let source = YlNetworkByteSource(recipe: .init(url: server.url, headers: [:],
      configuration: .init(map: [:]), managedIntent: .init()), capacity: 32, sessionConfiguration: configuration)
    defer { source.cancel() }
    XCTAssertEqual(nativeError { try readToEnd(source) }.code, "policy.unsupported")
    XCTAssertEqual(server.requests.count, 0)
  }

  func testManagedRealReadTimeoutAndBackpressureCancellation() throws {
    let delayed = try HeaderBoundaryServer(mime: false); defer { delayed.close() }
    let source = YlNetworkByteSource(recipe: .init(url: delayed.url, headers: [:],
      configuration: .init(options: .init(connectTimeoutMs: 1000, readTimeoutMs: 100,
        maxRetries: 0, baseRetryDelayMs: 0, maxRetryDelayMs: 0, maxRedirects: 0)), managedIntent: .init()), capacity: 32)
    defer { source.cancel() }
    let error = nativeError { try readToEnd(source) }
    XCTAssertEqual(error.diagnostic, "network.read_timeout")
    let server = try ManagedScriptServer { _ in "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc" }
    defer { server.close() }
    let blocked = YlNetworkByteSource(recipe: .init(url: server.url, headers: [:],
      configuration: .init(map: [:]), managedIntent: .init()), capacity: 1)
    let deadline = Date().addingTimeInterval(2)
    while blocked.debugBufferedBytes == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
    XCTAssertEqual(blocked.debugBufferedBytes, 1)
    blocked.cancel()
    XCTAssertThrowsError(try readToEnd(blocked)) { error in
      guard case YlByteSourceError.cancelled = error else { XCTFail("Expected cancellation"); return }
    }
  }

}

private final class HeaderBoundaryServer {
  let headersSent = DispatchSemaphore(value: 0)
  let url: URL
  private let listener: NWListener
  init(mime: Bool, fragmented: Bool = false) throws {
    listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    let sent = headersSent
    listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
    listener.newConnectionHandler = { connection in
      connection.start(queue: .global())
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { bytes, _, _, _ in
        guard let bytes, !bytes.isEmpty else { connection.cancel(); return }
        let headers = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n"
          + (mime ? "Content-Type: application/octet-stream\r\n" : "") + "\r\n"
        let data = Data(headers.utf8)
        let boundary = fragmented ? data.count / 2 : 0
        let finishHeaders = {
          connection.send(content: data.dropFirst(boundary), completion: .contentProcessed { _ in
            sent.signal()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
              connection.send(content: Data([1, 2, 3]), completion: .contentProcessed { _ in connection.cancel() })
            }
          })
        }
        if fragmented {
          connection.send(content: data.prefix(boundary), completion: .contentProcessed { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05, execute: finishHeaders)
          })
        } else { finishHeaders() }
      }
    }
    listener.start(queue: .global())
    guard ready.wait(timeout: .now() + 3) == .success, let port = listener.port else {
      listener.cancel(); throw NSError(domain: "TestServer", code: 1)
    }
    url = URL(string: "http://127.0.0.1:\(port.rawValue)/bytes")!
  }
  func close() { listener.cancel() }
}

/// Disposable test CA/leaf keys only. Never installed in a system trust store or
/// shipped in the plugin. Generated by the Task3 controller for local TLS proof.
private enum ManagedTLSFixture {
  static func anchor(_ tls: NWProtocolTLS.Options, hostname: String) {
    let certificate = SecCertificateCreateWithData(nil, ca as CFData)!
    sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
      let value = sec_trust_copy_ref(trust).takeRetainedValue()
      SecTrustSetAnchorCertificates(value, [certificate] as CFArray)
      SecTrustSetAnchorCertificatesOnly(value, true)
      SecTrustSetPolicies(value, SecPolicyCreateSSL(true, hostname as CFString))
      // Fixed date inside the disposable leaf validity; retains SSL validity,
      // chain and hostname checks without letting this fixture expire.
      SecTrustSetVerifyDate(value, Date(timeIntervalSince1970: 1788955009) as CFDate)
      complete(SecTrustEvaluateWithError(value, nil))
    }, .global())
  }
  static let ca = Data(base64Encoded: "MIIC1jCCAb4CCQCz3S7kD+sIpDANBgkqhkiG9w0BAQsFADAtMSswKQYDVQQDDCJZbCBNYW5hZ2VkIFRyYW5zcG9ydCBMb2NhbCBUZXN0IENBMB4XDTI2MDkwOTExMzUzN1oXDTM2MDkwNjExMzUzN1owLTErMCkGA1UEAwwiWWwgTWFuYWdlZCBUcmFuc3BvcnQgTG9jYWwgVGVzdCBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAKpQX1opVyzECzuNR7lVRCcye/4fhNn+Lw//NewHjocJMDx5JB+2eFVYBuaUXEv+OzLHKFQl9YNdeQbKJ4YGKcL2G7ex8LFQh4HbiXmdiwMPWUVFZND7iMN1jtyBc024rhkZQlyrYTOZBZmiE15dnRxtWdHff40C2v2oAY4/czZV0sDL1fs7+COaBJI+AgIMMAPjHBMjduFIPKT3aDXd3jc7zWOc7Gm1GCNnp8OFzbE+4g8RAEI8ttFE5mXoICltT0C+YuVGFJgF65ufe90L7x7utB7031sAYWvypRV9bECWdQorOWCfbHGuNwKgQkyiql9Od86NaPop2lJIxD0hFu0CAwEAATANBgkqhkiG9w0BAQsFAAOCAQEAJX/nvWyRBlsqomvdObBViHon8APn6Y2Nd1p/XkUCXeroY87kfVVazJZJc3KMrT1GJG/nyVlPEB4E1t07SIYuPDUGXLq1I76n97FQ91U818HKNGaLN7HoB0FZwFUdzDNxSfnF8Y3BuceOgTinBI7ixP2M+phx6ty929GPCBUjq69KS+cvzFoXU2Eu/oOWReJbrdU58BvPWKNlilmFebX4QPUVg2zc778qHSA8hrX+3nFiSwkCS/6a29cAYoTBGJR0Yh5lR2UlnZHBZiUHySKUKBoWjzFAcj39NQxjE/mK8s2dSlyvMVKPCyWvdYt6wMv2UpbNGO5SlAsBRR8FILV+Bg==")!
  static let localhost = Data(base64Encoded: "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")!
  static let mismatch = Data(base64Encoded: "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")!
}

private final class ManagedTLSTestServer {
  let url: URL
  private let listener: NWListener
  init(p12: Data) throws {
    var imported: CFArray?
    var importOptions: [String: Any] = [kSecImportExportPassphrase as String: "local-test-only"]
    if #available(macOS 15, iOS 18, *) { importOptions[kSecImportToMemoryOnly as String] = true }
    else {
      #if os(macOS)
      throw XCTSkip("Isolated TLS fixture requires macOS15 memory-only PKCS12 import")
      #endif
    }
    guard SecPKCS12Import(p12 as CFData, importOptions as CFDictionary,
      &imported) == errSecSuccess, let first = (imported as? [[String: Any]])?.first,
      let identity = first[kSecImportItemIdentity as String] else { throw NSError(domain: "TLSFixture", code: 1) }
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity as! SecIdentity)!)
    sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
    listener = try NWListener(using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()), on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { connection in
      connection.start(queue: .global())
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { bytes, _, _, _ in
        guard bytes?.isEmpty == false else { connection.cancel(); return }
        connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\n".utf8) + Data([1, 2, 3]),
          completion: .contentProcessed { _ in connection.cancel() })
      }
    }
    listener.start(queue: .global())
    guard ready.wait(timeout: .now() + 3) == .success, let port = listener.port else {
      listener.cancel(); throw NSError(domain: "TLSFixture", code: 2)
    }
    url = URL(string: "https://127.0.0.1:\(port.rawValue)/bytes")!
  }
  func close() { listener.cancel() }
}

private final class ManagedScriptServer {
  struct Request { let path: String; let raw: String }
  let url: URL
  private let listener: NWListener
  private let lock = NSLock()
  private var recorded = [Request]()
  var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }
  init(handler: @escaping (Request) -> String) throws {
    listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { $0.cancel() }
    listener.start(queue: .global())
    guard ready.wait(timeout: .now() + 3) == .success, let port = listener.port else {
      listener.cancel(); throw NSError(domain: "HTTPFixture", code: 1)
    }
    url = URL(string: "http://127.0.0.1:\(port.rawValue)")!
    listener.newConnectionHandler = { [weak self] connection in
      connection.start(queue: .global())
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
        guard let self, let data, !data.isEmpty else { connection.cancel(); return }
        let raw = String(decoding: data, as: UTF8.self).lowercased()
        let path = raw.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let request = Request(path: path, raw: raw)
        self.lock.lock(); self.recorded.append(request); self.lock.unlock()
        connection.send(content: Data(handler(request).utf8), completion: .contentProcessed { _ in connection.cancel() })
      }
    }
  }
  func close() { listener.cancel() }
}
