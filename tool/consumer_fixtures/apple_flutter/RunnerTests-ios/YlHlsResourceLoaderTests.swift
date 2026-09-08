@testable import yl_player_apple
import XCTest

final class HlsLoaderURLProtocol: URLProtocol {
  typealias Handler = (URLRequest, HlsLoaderURLProtocol) -> Void
  private static let lock = NSLock()
  private static var handler: Handler?
  private static var requests = [URLRequest]()
  private static var latestProtocol: HlsLoaderURLProtocol?

  static func configuration(handler: @escaping Handler) -> URLSessionConfiguration {
    lock.lock()
    self.handler = handler
    requests = []
    latestProtocol = nil
    lock.unlock()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HlsLoaderURLProtocol.self]
    return configuration
  }

  static var capturedRequests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }

  static func sendLateCompletion() {
    lock.lock()
    let value = latestProtocol
    lock.unlock()
    if let value { value.client?.urlProtocolDidFinishLoading(value) }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    Self.requests.append(request)
    Self.latestProtocol = self
    let handler = Self.handler
    Self.lock.unlock()
    handler?(request, self)
  }

  override func stopLoading() {}

  func respond(
    status: Int = 200,
    headers: [String: String] = [:],
    data: Data,
    finish: Bool = true
  ) {
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    if finish { client?.urlProtocolDidFinishLoading(self) }
  }
}

private final class TestHlsLoadingRequest: YlHlsLoadingRequest {
  let url: URL
  let requestedOffset: Int64
  let currentOffset: Int64
  let requestedLength: Int
  let requestsAllDataToEnd: Bool
  private let lock = NSLock()
  private let finished: XCTestExpectation
  private(set) var contentType: String?
  private(set) var contentLength: Int64 = 0
  private(set) var byteRangeAccessSupported = false
  private(set) var received = Data()
  private(set) var finishCount = 0
  private(set) var error: NativePlayerError?
  private(set) var redirectRequest: URLRequest?

  init(
    url: URL,
    requestedOffset: Int64 = 0,
    currentOffset: Int64 = 0,
    requestedLength: Int = 0,
    requestsAllDataToEnd: Bool = true,
    finished: XCTestExpectation
  ) {
    self.url = url
    self.requestedOffset = requestedOffset
    self.currentOffset = currentOffset
    self.requestedLength = requestedLength
    self.requestsAllDataToEnd = requestsAllDataToEnd
    self.finished = finished
  }

  func setContentInformation(
    contentType: String?,
    contentLength: Int64,
    byteRangeAccessSupported: Bool
  ) {
    lock.lock()
    self.contentType = contentType
    self.contentLength = contentLength
    self.byteRangeAccessSupported = byteRangeAccessSupported
    lock.unlock()
  }

  func respond(with data: Data) {
    lock.lock()
    received.append(data)
    lock.unlock()
  }

  func redirect(to request: URLRequest) {
    lock.lock()
    redirectRequest = request
    lock.unlock()
  }

  func finishLoading() { complete(error: nil) }
  func finishLoading(with error: NativePlayerError) { complete(error: error) }

  private func complete(error: NativePlayerError?) {
    lock.lock()
    finishCount += 1
    self.error = error
    let shouldFulfill = finishCount == 1
    lock.unlock()
    if shouldFulfill { finished.fulfill() }
  }
}

final class YlHlsResourceLoaderTests: XCTestCase {
  func testEncodedAssetURLMarksExtensionlessExplicitHlsAsManifest() throws {
    let configuration = HlsLoaderURLProtocol.configuration { _, _ in }
    let loader = try makeLoader(
      session: configuration,
      originURL: URL(string: "https://media.test/play?id=42")!
    )

    XCTAssertEqual(
      try YlHlsURLCodec.resourceKind(loader.encodedAssetURL()),
      .manifest
    )
  }

  func testMediaProxyURLsRemainValidForLargeVodManifest() throws {
    let proxy = try YlHlsMediaProxy(
      originURL: URL(string: "https://media.test/master.m3u8")!,
      headers: [:],
      configuration: .init(map: [
        "connectTimeoutMs": 100,
        "readTimeoutMs": 100,
      ])
    )
    defer { proxy.cancelAll() }
    let first = try proxy.proxyURL(
      for: URL(string: "http://127.0.0.1:1/segment-0.ts")!
    )
    for index in 1...2_100 {
      _ = try proxy.proxyURL(
        for: URL(string: "http://127.0.0.1:1/segment-\(index).ts")!
      )
    }

    let completed = expectation(description: "proxy request completed")
    URLSession.shared.dataTask(with: first) { _, response, _ in
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
      completed.fulfill()
    }.resume()
    wait(for: [completed], timeout: 3)
  }

  func testChunkedTransportErrorIsNotReportedAsCleanCompletion() {
    XCTAssertEqual(
      YlHlsMediaProxy.completionAction(
        responseStarted: true,
        usesChunkedTransfer: true,
        method: "GET",
        error: URLError(.networkConnectionLost)
      ),
      .close
    )
    XCTAssertEqual(
      YlHlsMediaProxy.completionAction(
        responseStarted: true,
        usesChunkedTransfer: true,
        method: "GET",
        error: nil
      ),
      .finishChunked
    )
  }

  func testManifestUsesHeadersAndRewritesChildURL() throws {
    let configuration = HlsLoaderURLProtocol.configuration { request, source in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
      source.respond(
        headers: ["Content-Type": "application/vnd.apple.mpegurl"],
        data: Data("#EXTM3U\nchild.m3u8\n".utf8)
      )
    }
    let loader = try makeLoader(session: configuration)
    let finished = expectation(description: "manifest loaded")
    let request = TestHlsLoadingRequest(
      url: try loader.encodedAssetURL(),
      finished: finished
    )

    XCTAssertTrue(loader.startLoading(request))
    wait(for: [finished], timeout: 2)

    XCTAssertNil(request.error)
    let text = try XCTUnwrap(String(data: request.received, encoding: .utf8))
    let encodedChild = try XCTUnwrap(text.split(separator: "\n").last)
    XCTAssertEqual(
      try YlHlsURLCodec.decode(try XCTUnwrap(URL(string: String(encodedChild)))),
      URL(string: "https://media.test/live/child.m3u8")
    )
    XCTAssertGreaterThan(request.contentLength, 0)
  }

  func testMediaRangeRedirectOwnsRangeAndStripsCrossOriginCredential() throws {
    let configuration = HlsLoaderURLProtocol.configuration { _, _ in
      XCTFail("Media redirects must not start a package URLSession task.")
    }
    let loader = try makeLoader(session: configuration)
    let finished = expectation(description: "media loaded")
    let request = TestHlsLoadingRequest(
      url: try YlHlsURLCodec.encode(URL(string: "https://cdn.test/seg.ts")!),
      requestedOffset: 2,
      requestedLength: 3,
      requestsAllDataToEnd: false,
      finished: finished
    )

    XCTAssertTrue(loader.startLoading(request))
    wait(for: [finished], timeout: 2)

    XCTAssertEqual(request.redirectRequest?.url, URL(string: "https://cdn.test/seg.ts"))
    XCTAssertEqual(
      request.redirectRequest?.value(forHTTPHeaderField: "Range"),
      "bytes=2-4"
    )
    XCTAssertNil(request.redirectRequest?.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(
      request.redirectRequest?.value(forHTTPHeaderField: "X-Client"),
      "ios"
    )
    XCTAssertTrue(request.received.isEmpty)
  }

  func testSameOriginMediaRedirectRetainsCredentials() throws {
    let configuration = HlsLoaderURLProtocol.configuration { _, _ in
      XCTFail("Media redirects must not start a package URLSession task.")
    }
    let loader = try makeLoader(session: configuration)
    let finished = expectation(description: "full response sliced")
    let request = TestHlsLoadingRequest(
      url: try YlHlsURLCodec.encode(URL(string: "https://media.test/seg.ts")!),
      requestedOffset: 2,
      requestedLength: 2,
      requestsAllDataToEnd: false,
      finished: finished
    )

    XCTAssertTrue(loader.startLoading(request))
    wait(for: [finished], timeout: 2)

    XCTAssertEqual(
      request.redirectRequest?.value(forHTTPHeaderField: "Range"),
      "bytes=2-3"
    )
    XCTAssertEqual(
      request.redirectRequest?.value(forHTTPHeaderField: "Authorization"),
      "Bearer test"
    )
  }

  func testKeyUsesDirectLoaderDataAndRetainsCredentials() throws {
    let configuration = HlsLoaderURLProtocol.configuration { request, source in
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "Authorization"),
        "Bearer test"
      )
      source.respond(
        headers: ["Content-Type": "application/octet-stream"],
        data: Data(repeating: 7, count: 16)
      )
    }
    let loader = try makeLoader(session: configuration)
    let finished = expectation(description: "key loaded")
    let request = TestHlsLoadingRequest(
      url: try YlHlsURLCodec.encode(
        URL(string: "https://media.test/key-without-extension")!,
        kind: .key
      ),
      finished: finished
    )

    XCTAssertTrue(loader.startLoading(request))
    wait(for: [finished], timeout: 2)

    XCTAssertNil(request.redirectRequest)
    XCTAssertEqual(request.received, Data(repeating: 7, count: 16))
    XCTAssertNil(request.error)
  }

  func testHTTPAndMalformedManifestFailuresAreStable() throws {
    for scenario in ["http", "utf8"] {
      let configuration = HlsLoaderURLProtocol.configuration { _, source in
        if scenario == "http" {
          source.respond(status: 403, data: Data())
        } else {
          source.respond(
            headers: ["Content-Type": "application/x-mpegURL"],
            data: Data([0x23, 0xFF])
          )
        }
      }
      let loader = try makeLoader(session: configuration)
      let finished = expectation(description: scenario)
      let request = TestHlsLoadingRequest(
        url: try loader.encodedAssetURL(),
        finished: finished
      )
      XCTAssertTrue(loader.startLoading(request))
      wait(for: [finished], timeout: 2)
      XCTAssertEqual(
        request.error?.code,
        scenario == "http" ? "network.http_status" : "container.hls_manifest_invalid"
      )
      XCTAssertEqual(request.finishCount, 1)
    }
  }

  func testTimeoutAndManifestLimitFailuresAreStable() throws {
    let scenarios: [(String, String)] = [
      ("timeout", "network.read_timeout"),
      ("limit", "resource.hls_manifest_too_large"),
    ]
    for (scenario, expectedCode) in scenarios {
      let configuration = HlsLoaderURLProtocol.configuration { _, source in
        if scenario == "timeout" {
          source.client?.urlProtocol(source, didFailWithError: URLError(.timedOut))
        } else {
          source.respond(
            headers: [
              "Content-Type": "application/vnd.apple.mpegurl",
              "Content-Length": String(YlHlsResourceLoader.manifestByteLimit + 1),
            ],
            data: Data(),
            finish: false
          )
        }
      }
      let loader = try makeLoader(session: configuration)
      let finished = expectation(description: scenario)
      let request = TestHlsLoadingRequest(
        url: try loader.encodedAssetURL(),
        finished: finished
      )

      XCTAssertTrue(loader.startLoading(request))
      wait(for: [finished], timeout: 2)

      XCTAssertEqual(request.error?.code, expectedCode)
      XCTAssertEqual(request.finishCount, 1)
    }
  }

  func testCachedManifestDoesNotRestoreCredentialsAfterInheritedStripping() throws {
    let origin = URL(string: "https://media.test/master.m3u8")!
    let configuration = HlsLoaderURLProtocol.configuration { _, source in
      source.respond(headers: ["Content-Type": "application/vnd.apple.mpegurl"],
        data: Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nchild.m3u8\n".utf8))
    }
    let loader = try YlHlsResourceLoader(originURL: origin, headers: ["X-Client": "ordinary"], credentials: ["X-Session": "secret"], configuration: .init(map: [:]), sessionConfiguration: configuration)
    defer { loader.cancelAll() }
    try loader.preflight(cancellationToken: YlOpenCancellationToken())
    XCTAssertEqual(HlsLoaderURLProtocol.capturedRequests.first?.value(forHTTPHeaderField: "X-Session"), "secret")
    let finished = expectation(description: "stripped root reload")
    let request = TestHlsLoadingRequest(url: try YlHlsURLCodec.encode(origin, kind: .manifest, credentialsStripped: true), finished: finished)
    XCTAssertTrue(loader.startLoading(request))
    wait(for: [finished], timeout: 2)
    XCTAssertNil(request.error)
    XCTAssertEqual(HlsLoaderURLProtocol.capturedRequests.count, 2)
    XCTAssertNil(HlsLoaderURLProtocol.capturedRequests.last?.value(forHTTPHeaderField: "X-Session"))
    XCTAssertEqual(HlsLoaderURLProtocol.capturedRequests.last?.value(forHTTPHeaderField: "X-Client"), "ordinary")
    let child = try XCTUnwrap(String(data: request.received, encoding: .utf8)?.split(separator: "\n").last.flatMap { URL(string: String($0)) })
    XCTAssertTrue(YlHlsURLCodec.credentialsStripped(child))
  }

  func testPreflightCachesRewrittenTopLevelManifest() throws {
    let configuration = HlsLoaderURLProtocol.configuration { _, source in
      source.respond(
        headers: ["Content-Type": "application/vnd.apple.mpegurl"],
        data: Data("#EXTM3U\nsegment.ts\n".utf8)
      )
    }
    let loader = try makeLoader(session: configuration)
    try loader.preflight(cancellationToken: YlOpenCancellationToken())
    XCTAssertEqual(HlsLoaderURLProtocol.capturedRequests.count, 1)

    let finished = expectation(description: "cached manifest")
    let request = TestHlsLoadingRequest(
      url: try loader.encodedAssetURL(),
      finished: finished
    )
    XCTAssertTrue(loader.startLoading(request))
    wait(for: [finished], timeout: 1)

    XCTAssertEqual(HlsLoaderURLProtocol.capturedRequests.count, 1)
    XCTAssertTrue(
      String(data: request.received, encoding: .utf8)?
        .contains("http://127.0.0.1:") == true
    )
  }

  func testCancelAllFinishesOnceAndIgnoresLateCompletion() throws {
    let configuration = HlsLoaderURLProtocol.configuration { _, _ in }
    let loader = try makeLoader(session: configuration)
    let finished = expectation(description: "cancelled")
    let request = TestHlsLoadingRequest(
      url: try loader.encodedAssetURL(),
      finished: finished
    )
    XCTAssertTrue(loader.startLoading(request))

    loader.cancelAll()
    wait(for: [finished], timeout: 1)
    HlsLoaderURLProtocol.sendLateCompletion()

    XCTAssertEqual(request.error?.code, "network.cancelled")
    XCTAssertEqual(request.finishCount, 1)
  }

  private func makeLoader(
    session: URLSessionConfiguration,
    originURL: URL = URL(string: "https://media.test/live/master.m3u8")!
  ) throws -> YlHlsResourceLoader {
    try YlHlsResourceLoader(
      originURL: originURL,
      headers: [
        "Authorization": "Bearer test",
        "X-Client": "ios",
        "Range": "bytes=99-",
      ],
      configuration: .init(map: [
        "connectTimeoutMs": 500,
        "readTimeoutMs": 500,
      ]),
      sessionConfiguration: session
    )
  }
}
