@testable import yl_player_ios
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
  func testManifestUsesHeadersAndRewritesChildURL() throws {
    let configuration = HlsLoaderURLProtocol.configuration { request, source in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
      source.respond(
        headers: ["Content-Type": "application/vnd.apple.mpegurl"],
        data: Data("#EXTM3U\nchild.m3u8\n".utf8)
      )
    }
    let loader = makeLoader(session: configuration)
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

  func testMediaRangeOwnsRangeHeaderAndStripsCrossOriginCredential() throws {
    let configuration = HlsLoaderURLProtocol.configuration { request, source in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=2-4")
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client"), "ios")
      source.respond(
        status: 206,
        headers: [
          "Content-Type": "video/mp2t",
          "Content-Range": "bytes 2-4/8",
          "Content-Length": "3",
          "Accept-Ranges": "bytes",
        ],
        data: Data("XYZ".utf8)
      )
    }
    let loader = makeLoader(session: configuration)
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

    XCTAssertEqual(request.received, Data("XYZ".utf8))
    XCTAssertEqual(request.contentLength, 8)
    XCTAssertTrue(request.byteRangeAccessSupported)
  }

  func testRangeRequestSafelySlicesAFull200Response() throws {
    let configuration = HlsLoaderURLProtocol.configuration { request, source in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=2-3")
      source.respond(
        headers: [
          "Content-Type": "video/mp2t",
          "Content-Length": "5",
        ],
        data: Data("ABCDE".utf8)
      )
    }
    let loader = makeLoader(session: configuration)
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

    XCTAssertEqual(request.received, Data("CD".utf8))
    XCTAssertEqual(request.contentLength, 5)
    XCTAssertFalse(request.byteRangeAccessSupported)
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
      let loader = makeLoader(session: configuration)
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
      let loader = makeLoader(session: configuration)
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

  func testPreflightCachesRewrittenTopLevelManifest() throws {
    let configuration = HlsLoaderURLProtocol.configuration { _, source in
      source.respond(
        headers: ["Content-Type": "application/vnd.apple.mpegurl"],
        data: Data("#EXTM3U\nsegment.ts\n".utf8)
      )
    }
    let loader = makeLoader(session: configuration)
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
    XCTAssertTrue(String(data: request.received, encoding: .utf8)?.contains("ylhls://") == true)
  }

  func testCancelAllFinishesOnceAndIgnoresLateCompletion() throws {
    let configuration = HlsLoaderURLProtocol.configuration { _, _ in }
    let loader = makeLoader(session: configuration)
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

  private func makeLoader(session: URLSessionConfiguration) -> YlHlsResourceLoader {
    YlHlsResourceLoader(
      originURL: URL(string: "https://media.test/live/master.m3u8")!,
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
