@testable import yl_player_ios
import Foundation
import XCTest

private final class ScriptedURLProtocol: URLProtocol {
  struct ResponseScript {
    let status: Int?
    let headers: [String: String]
    let chunks: [(delay: TimeInterval, data: Data)]
    let failure: URLError.Code?
    let finishes: Bool

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
  private func makeSource(
    scripts: [ScriptedURLProtocol.ResponseScript],
    capacity: Int = 32,
    configuration: [String: Any?] = [:],
    headers: [String: String] = [:],
    retries: ((Int, Int64, NativePlayerError) -> Void)? = nil
  ) -> YlNetworkByteSource {
    let url = ScriptedURLProtocol.configure(scripts)
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [ScriptedURLProtocol.self]
    return YlNetworkByteSource(
      recipe: YlNetworkRequestRecipe(
        url: url,
        headers: headers,
        configuration: YlNetworkConfiguration(map: configuration)
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
}
