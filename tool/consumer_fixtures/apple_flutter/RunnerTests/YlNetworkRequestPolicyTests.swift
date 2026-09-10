@testable import yl_player_apple
import Foundation
import XCTest

final class YlNetworkRequestPolicyTests: XCTestCase {
  private func makePolicy(
    url: String = "https://media.test/movie.mkv?token=secret#fragment",
    headers: [String: String] = [:],
    maxRedirects: Int = 5,
    mode: YlNetworkInputMode = .randomAccessVOD
  ) -> YlNetworkRequestPolicy {
    YlNetworkRequestPolicy(
      recipe: YlNetworkRequestRecipe(
        url: URL(string: url)!,
        headers: headers,
        configuration: YlNetworkConfiguration(map: [
          "maxRedirects": maxRedirects,
        ]),
        mode: mode
      )
    )
  }

  private func response(
    _ url: String = "https://media.test/movie.mkv",
    status: Int,
    headers: [String: String] = [:]
  ) -> HTTPURLResponse {
    HTTPURLResponse(
      url: URL(string: url)!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
  }

  private func error(
    from body: () throws -> Any
  ) -> NativePlayerError {
    do {
      _ = try body()
      XCTFail("Expected NativePlayerError")
      return NativePlayerError(category: "test", code: "test.missing", message: "")
    } catch let error as NativePlayerError {
      return error
    } catch {
      XCTFail("Unexpected error: \(error)")
      return NativePlayerError(category: "test", code: "test.unexpected", message: "")
    }
  }

  func testRequestOwnsRangeAndUsesStrongValidator() throws {
    let policy = makePolicy(headers: [
      "rAnGe": "bytes=99-100",
      "User-Agent": "TVBox",
      "X-Token": "visible",
    ])
    let initial = try policy.request(offset: 0, validator: nil)
    XCTAssertEqual(initial.httpMethod, "GET")
    XCTAssertEqual(initial.value(forHTTPHeaderField: "Range"), "bytes=0-")
    XCTAssertEqual(initial.value(forHTTPHeaderField: "User-Agent"), "TVBox")

    let validator = YlNetworkResponseMetadata(
      responseStart: 0,
      resourceLength: 200,
      supportsRandomAccess: true,
      etag: "\"version-1\"",
      lastModified: "Wed, 02 Sep 2026 10:00:00 GMT",
      isEOF: false
    )
    let resumed = try policy.request(offset: 41, validator: validator)
    XCTAssertEqual(resumed.value(forHTTPHeaderField: "Range"), "bytes=41-")
    XCTAssertEqual(resumed.value(forHTTPHeaderField: "If-Range"), "\"version-1\"")
  }

  func testSequentialLiveRequestNeverUsesRangeHeaders() throws {
    let policy = makePolicy(
      headers: ["Range": "bytes=99-", "If-Range": "secret"],
      mode: .sequentialLive
    )

    let request = try policy.request(offset: 0, validator: nil)

    XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
    XCTAssertNil(request.value(forHTTPHeaderField: "If-Range"))
  }

  func testWeakETagFallsBackToLastModifiedWhenLengthKnown() throws {
    let policy = makePolicy()
    let validator = YlNetworkResponseMetadata(
      responseStart: 0,
      resourceLength: 200,
      supportsRandomAccess: true,
      etag: "W/\"weak\"",
      lastModified: "Wed, 02 Sep 2026 10:00:00 GMT",
      isEOF: false
    )
    let request = try policy.request(offset: 10, validator: validator)
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "If-Range"),
      "Wed, 02 Sep 2026 10:00:00 GMT"
    )
  }

  func testValid206ParsesContentRangeAndValidators() throws {
    let policy = makePolicy()
    _ = try policy.request(offset: 40, validator: nil)
    let metadata = try policy.validate(
      response: response(status: 206, headers: [
        "Content-Range": "bytes 40-99/200",
        "Content-Length": "60",
        "ETag": "\"version-1\"",
        "Last-Modified": "Wed, 02 Sep 2026 10:00:00 GMT",
      ]),
      requestedOffset: 40
    )
    XCTAssertEqual(metadata.responseStart, 40)
    XCTAssertEqual(metadata.resourceLength, 200)
    XCTAssertTrue(metadata.supportsRandomAccess)
    XCTAssertEqual(metadata.etag, "\"version-1\"")
    XCTAssertFalse(metadata.isEOF)
  }

  func testOffsetZero200IsSequentialAndUsesContentLength() throws {
    let metadata = try makePolicy().validate(
      response: response(status: 200, headers: ["Content-Length": "123"]),
      requestedOffset: 0
    )
    XCTAssertEqual(metadata.responseStart, 0)
    XCTAssertEqual(metadata.resourceLength, 123)
    XCTAssertFalse(metadata.supportsRandomAccess)
    XCTAssertFalse(metadata.isEOF)
  }

  func testNonzero200IsRangeNotSupported() {
    let received = error {
      try makePolicy().validate(
        response: response(status: 200, headers: ["Content-Length": "123"]),
        requestedOffset: 40
      )
    }
    XCTAssertEqual(received.category, "network")
    XCTAssertEqual(received.code, "network.range_not_supported")
  }

  func testExactLength416IsEOF() throws {
    let policy = makePolicy()
    let validator = YlNetworkResponseMetadata(
      responseStart: 0,
      resourceLength: 123,
      supportsRandomAccess: true,
      etag: "\"version-1\"",
      lastModified: nil,
      isEOF: false
    )
    _ = try policy.request(offset: 123, validator: validator)
    let metadata = try policy.validate(
      response: response(status: 416, headers: ["Content-Range": "bytes */123"]),
      requestedOffset: 123
    )
    XCTAssertTrue(metadata.isEOF)
    XCTAssertEqual(metadata.resourceLength, 123)
    XCTAssertTrue(metadata.supportsRandomAccess)
  }

  func testInvalidContentRangeAndUnexpected416AreRangeInvalid() {
    let policy = makePolicy()
    XCTAssertEqual(
      error {
        try policy.validate(
          response: response(status: 206, headers: [
            "Content-Range": "bytes 39-99/200",
          ]),
          requestedOffset: 40
        )
      }.code,
      "network.range_invalid"
    )
    XCTAssertEqual(
      error {
        try policy.validate(
          response: response(status: 416, headers: [
            "Content-Range": "bytes */123",
          ]),
          requestedOffset: 122
        )
      }.code,
      "network.range_invalid"
    )
  }

  func testSameOriginRedirectRetainsCredentialsAndRebuildsRange() throws {
    let policy = makePolicy(headers: [
      "Authorization": "Bearer secret",
      "Cookie": "sid=secret",
      "Proxy-Authorization": "Basic secret",
    ])
    _ = try policy.request(offset: 9, validator: nil)
    let redirected = try policy.redirectRequest(
      from: URL(string: "https://media.test/movie.mkv")!,
      response: response(status: 302),
      to: URL(string: "https://media.test/path/movie.mkv")!
    )
    XCTAssertEqual(redirected.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    XCTAssertEqual(redirected.value(forHTTPHeaderField: "Cookie"), "sid=secret")
    XCTAssertEqual(redirected.value(forHTTPHeaderField: "Range"), "bytes=9-")
  }

  func testCrossOriginRedirectStripsCredentials() throws {
    let policy = makePolicy(headers: [
      "Authorization": "Bearer secret",
      "Cookie": "sid=secret",
      "Proxy-Authorization": "Basic secret",
      "User-Agent": "TVBox",
    ])
    _ = try policy.request(offset: 0, validator: nil)
    let redirected = try policy.redirectRequest(
      from: URL(string: "https://media.test/movie.mkv")!,
      response: response(status: 302),
      to: URL(string: "https://cdn.test/movie.mkv")!
    )
    XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(redirected.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(redirected.value(forHTTPHeaderField: "Proxy-Authorization"))
    XCTAssertEqual(redirected.value(forHTTPHeaderField: "User-Agent"), "TVBox")
  }

  func testCredentialsStayStrippedAfterCrossOriginRedirectChain() throws {
    let policy = makePolicy(headers: [
      "Authorization": "Bearer secret",
      "Cookie": "sid=secret",
      "Proxy-Authorization": "Basic secret",
      "User-Agent": "TVBox",
    ])
    _ = try policy.request(offset: 0, validator: nil)
    let redirectResponse = response(status: 302)
    _ = try policy.redirectRequest(
      from: URL(string: "https://media.test/movie.mkv")!,
      response: redirectResponse,
      to: URL(string: "https://cdn.test/movie.mkv")!
    )

    let secondRedirect = try policy.redirectRequest(
      from: URL(string: "https://cdn.test/movie.mkv")!,
      response: redirectResponse,
      to: URL(string: "https://cdn.test/final.mkv")!
    )

    XCTAssertNil(secondRedirect.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(secondRedirect.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(secondRedirect.value(forHTTPHeaderField: "Proxy-Authorization"))
    XCTAssertEqual(secondRedirect.value(forHTTPHeaderField: "User-Agent"), "TVBox")
  }

  func testRedirectLimitAndSchemeValidationUseSanitizedDiagnostics() throws {
    let policy = makePolicy(maxRedirects: 1)
    _ = try policy.request(offset: 0, validator: nil)
    _ = try policy.redirectRequest(
      from: URL(string: "https://media.test/movie.mkv")!,
      response: response(status: 302),
      to: URL(string: "https://cdn.test/movie.mkv?credential=secret")!
    )
    let limit = error {
      try policy.redirectRequest(
        from: URL(string: "https://cdn.test/movie.mkv")!,
        response: response(status: 302),
        to: URL(string: "https://last.test/movie.mkv?credential=secret")!
      )
    }
    XCTAssertEqual(limit.code, "network.redirect_limit")
    XCTAssertFalse(limit.diagnostic?.contains("secret") ?? true)

    let invalid = error {
      try makePolicy().redirectRequest(
        from: URL(string: "https://media.test/movie.mkv")!,
        response: response(status: 302),
        to: URL(string: "file:///private/movie.mkv?credential=secret")!
      )
    }
    XCTAssertEqual(invalid.code, "network.invalid_redirect")
    XCTAssertFalse(invalid.diagnostic?.contains("secret") ?? true)
  }

  func testHttpStatusDiagnosticContainsNoQueryOrCredentials() {
    let policy = makePolicy(headers: ["Authorization": "Bearer secret"])
    let received = error {
      try policy.validate(
        response: response(
          "https://media.test/movie.mkv?token=secret#fragment",
          status: 403
        ),
        requestedOffset: 0
      )
    }
    XCTAssertEqual(received.code, "network.http_status")
    XCTAssertEqual(received.diagnostic, "HTTP 403 network.request")
  }
  func testReturnOriginAndRetryDoNotRestoreStrippedCredentials() throws {
    let policy = makePolicy(headers: ["aUtHoRiZaTiOn": "private", "User-Agent": "visible"])
    let original = URL(string: "https://media.test/movie.mkv")!
    let other = URL(string: "https://cdn.test/movie.mkv")!
    XCTAssertEqual(try policy.request(offset: 0, validator: nil).value(forHTTPHeaderField: "Authorization"), "private")
    _ = try policy.redirectRequest(from: original, response: response(status: 302), to: other)
    let returned = try policy.redirectRequest(from: other, response: response(status: 302), to: original)
    XCTAssertNil(returned.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(returned.value(forHTTPHeaderField: "User-Agent"), "visible")
    let retry = try policy.request(offset: 0, validator: nil)
    XCTAssertNil(retry.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(retry.value(forHTTPHeaderField: "User-Agent"), "visible")
  }

  func testArbitraryCredentialNamesRemainClassifiedAcrossReaderReopen() throws {
    let original = URL(string: "https://media.test/movie.mkv")!
    let other = URL(string: "https://cdn.test/movie.mkv")!
    let recipe = YlNetworkRequestRecipe(url: original, headers: ["X-Display": "visible"],
      credentials: ["X-Custom-Identity": "private"], configuration: YlNetworkConfiguration(map: [:]))
    let policy = YlNetworkRequestPolicy(recipe: recipe)
    XCTAssertEqual(try policy.request(offset: 0, validator: nil).value(forHTTPHeaderField: "x-custom-identity"), "private")
    let same = try policy.redirectRequest(from: original, response: response(status: 302), to: original.appendingPathComponent("next"))
    XCTAssertEqual(same.value(forHTTPHeaderField: "X-Custom-Identity"), "private")
    let cross = try policy.redirectRequest(from: original, response: response(status: 302), to: other)
    XCTAssertNil(cross.value(forHTTPHeaderField: "X-Custom-Identity"))
    let reopened = try YlNetworkRequestPolicy(recipe: recipe).request(offset: 12, validator: nil)
    XCTAssertNil(reopened.value(forHTTPHeaderField: "X-Custom-Identity"))
    XCTAssertEqual(reopened.value(forHTTPHeaderField: "X-Display"), "visible")
    XCTAssertEqual(reopened.value(forHTTPHeaderField: "Range"), "bytes=12-")
    let fresh = YlNetworkRequestRecipe(url: original, headers: [:], credentials: recipe.credentials,
      configuration: recipe.configuration)
    XCTAssertEqual(try YlNetworkRequestPolicy(recipe: fresh).request(offset: 0, validator: nil).value(forHTTPHeaderField: "X-Custom-Identity"), "private")
  }

  func testManagedRetryStatusAllowlistExcludesPermanentServerFailures() {
    for status in [408, 429, 500, 502, 503, 504] {
      XCTAssertTrue(YlNetworkRequestPolicy.isRetryableStatus(status))
    }
    for status in [401, 403, 404, 501, 505, 599] {
      XCTAssertFalse(YlNetworkRequestPolicy.isRetryableStatus(status), "HTTP \(status)")
    }
  }

  func testRetryCannotReplenishOriginalResourceRedirectBudget() throws {
    let policy = makePolicy(maxRedirects: 1)
    let original = URL(string: "https://media.test/movie.mkv")!
    let next = original.appendingPathComponent("next")
    _ = try policy.request(offset: 0, validator: nil)
    _ = try policy.redirectRequest(from: original, response: response(status: 302), to: next)
    _ = try policy.request(offset: 0, validator: nil)
    XCTAssertEqual(error {
      try policy.redirectRequest(from: original, response: response(status: 302), to: next)
    }.code, "network.redirect_limit")
  }

  func testManagedBackoffRetryAfterAndClockAreDeterministic() {
    let now = Date(timeIntervalSince1970: 1_441_282_080)
    let policy = YlManagedRequestPolicy(now: { now })
    let config = YlNetworkConfiguration(options: .init(connectTimeoutMs: 90000, readTimeoutMs: 120000,
      maxRetries: 30, baseRetryDelayMs: 500, maxRetryDelayMs: 2000, maxRedirects: 30))
    XCTAssertEqual(config.connectTimeoutMs, 90000)
    XCTAssertEqual(config.maxRedirects, 30)
    XCTAssertEqual((1...5).map { policy.retryDelay(attempt: $0, configuration: config, retryAfter: nil) }, [500, 1000, 2000, 2000, 2000])
    for raw in ["garbage", "-1", "1.5", ""] {
      XCTAssertEqual(policy.retryDelay(attempt: 2, configuration: config, retryAfter: raw), 1000)
    }
    XCTAssertEqual(policy.retryDelay(attempt: 2, configuration: config, retryAfter: "0"), 0)
    XCTAssertEqual(policy.retryDelay(attempt: 2, configuration: config, retryAfter: "2"), 2000)
    XCTAssertNil(policy.retryDelay(attempt: 2, configuration: config, retryAfter: "3"))
    XCTAssertNil(policy.retryDelay(attempt: 2, configuration: config, retryAfter: String(repeating: "9", count: 100)))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
    for (offset, expected) in [(-10.0, Optional<Int64>(0)), (1, 1000), (3, nil)] {
      XCTAssertEqual(policy.retryDelay(attempt: 1, configuration: config,
        retryAfter: formatter.string(from: now.addingTimeInterval(offset))), expected)
    }
    let overflow = YlNetworkConfiguration(options: .init(connectTimeoutMs: 1, readTimeoutMs: 1,
      maxRetries: 50, baseRetryDelayMs: Int64.max / 2 + 1, maxRetryDelayMs: Int64.max, maxRedirects: 0))
    XCTAssertEqual(policy.retryDelay(attempt: 2, configuration: overflow, retryAfter: nil), Int64.max)
  }

  func testManagedClockFencesCancelledAndReplacedDeadlines() {
    var callbacks = [() -> Void]()
    var scheduled = [Int64]()
    var cancelled = 0
    var fired = [String]()
    let policy = YlManagedRequestPolicy(schedule: { delay, callback in
      scheduled.append(delay); callbacks.append(callback)
      return { cancelled += 1 }
    })
    policy.arm(after: 10) { fired.append("connect") }
    policy.arm(after: 20) { fired.append("redirect-connect") }
    callbacks[0]()
    policy.arm(after: 30) { fired.append("read") }
    callbacks[1]()
    callbacks[2]()
    policy.arm(after: 40) { fired.append("retry") }
    policy.cancel()
    callbacks[3]()
    XCTAssertEqual(scheduled, [10, 20, 30, 40])
    XCTAssertEqual(fired, ["read"])
    XCTAssertEqual(cancelled, 4)
  }

  func testManagedIntentRetainsBudgetsAndTerminalFailureAcrossReopen() {
    let intent = YlManagedRequestIntent()
    XCTAssertTrue(intent.followRedirect(maximum: 1))
    XCTAssertFalse(intent.followRedirect(maximum: 1))
    XCTAssertEqual(intent.nextRetry(maximum: 1), 1)
    XCTAssertNil(intent.nextRetry(maximum: 1))
    intent.fail(NativePlayerError(category: "network", code: "network.retry_exhausted", message: "Failed"))
    intent.completed()
    XCTAssertNotNil(intent.terminalFailure)
    XCTAssertNil(intent.nextRetry(maximum: 100))
    XCTAssertFalse(intent.followRedirect(maximum: 100))
    let fresh = YlManagedRequestIntent()
    XCTAssertEqual(fresh.nextRetry(maximum: 1), 1)
    fresh.completed()
    XCTAssertEqual(fresh.nextRetry(maximum: 1), 1)
  }

  func testManagedTransientEligibilityExcludesAuthenticationCertificatesCancellationAndNonIdempotentMethods() {
    for code in [URLError.Code.timedOut, .cannotFindHost, .networkConnectionLost] {
      XCTAssertTrue(YlManagedRequestPolicy.isTransient(URLError(code), method: "HEAD"))
      XCTAssertFalse(YlManagedRequestPolicy.isTransient(URLError(code), method: "POST"))
    }
    for code in [URLError.Code.cancelled, .userAuthenticationRequired, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .badURL, .unsupportedURL] {
      XCTAssertFalse(YlManagedRequestPolicy.isTransient(URLError(code)))
    }
  }

  func testImmutableOriginContextClassifiesCaseInsensitiveCollisionAndAllOriginDimensions() throws {
    let original = URL(string: "https://MEDIA.test:443/start")!
    let context = YlManagedRequestContext(sourceOrigin: try XCTUnwrap(YlRequestOrigin(url: original)),
      ordinaryHeaders: ["x-private": "shadow", "Cookie": "secret", "X-Display": "visible"],
      credentials: ["X-Private": "credential"], credentialsAllowed: true, redirectsFollowed: 0)
    XCTAssertEqual(context.headers["X-Private"], "credential")
    XCTAssertNil(context.headers["x-private"])
    XCTAssertTrue(context.child(at: URL(string: "../relative", relativeTo: original)!.absoluteURL).credentialsAllowed)
    for url in ["http://media.test/start", "https://other.test/start", "https://media.test:444/start"] {
      let stripped = context.child(at: URL(string: url)!, redirect: true)
      XCTAssertEqual(stripped.headers, ["X-Display": "visible"])
      XCTAssertFalse(stripped.child(at: original).credentialsAllowed)
      XCTAssertEqual(stripped.redirectsFollowed, 1)
    }
    XCTAssertTrue(context.credentialsAllowed)
  }

  func testZeroRedirectBudgetRejectsFirstRedirect() throws {
    let policy = makePolicy(maxRedirects: 0)
    let url = URL(string: "https://media.test/movie.mkv")!
    _ = try policy.request(offset: 0, validator: nil)
    XCTAssertEqual(error { try policy.redirectRequest(from: url, response: response(status: 302), to: url) }.code,
      "network.redirect_limit")
  }

  func testManagedFramingHandlesFragmentedInformationalFixedChunkedAndCloseBodies() throws {
    let url = URL(string: "https://media.test/bytes")!
    let cases = [
      "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc",
      "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: next\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc",
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nab\r\n1;ext=x\r\nc\r\n0\r\nX-End: yes\r\n\r\n",
      "HTTP/1.0 200 OK\r\n\r\nabc"
    ]
    for raw in cases {
      let parser = YlHTTPResponseParser(url: url)
      var events = [YlHTTPResponseParser.Event]()
      for byte in raw.utf8 { events += try parser.receive(Data([byte])) }
      events += try parser.endOfStream()
      var body = Data(); var headers = 0; var completed = 0
      for event in events {
        switch event {
        case .headers(let response): XCTAssertEqual(response.statusCode, 200); headers += 1
        case .body(let data): body.append(data)
        case .complete: completed += 1
        }
      }
      XCTAssertEqual(body, Data("abc".utf8))
      XCTAssertEqual(headers, 1); XCTAssertEqual(completed, 1)
    }
  }

  func testManagedFramingRejectsAmbiguityOverflowInvalidChunkAndUnsupportedEncoding() {
    let prefix = "HTTP/1.1 200 OK\r\n"
    let invalid = [
      prefix + "Content-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n",
      prefix + "Content-Length: 3\r\nContent-Length: 3\r\n\r\n",
      prefix + "Content-Length: 999999999999999999999999\r\n\r\n",
      prefix + "Content-Encoding: gzip\r\n\r\n",
      prefix + "Invalid Header: x\r\n\r\n",
      prefix + "Transfer-Encoding: gzip, chunked\r\n\r\n",
      prefix + "Transfer-Encoding: chunked\r\n\r\nxyz\r\n",
      prefix + "Transfer-Encoding: chunked\r\n\r\nFFFFFFFFFFFFFFFFFFFFFFFF\r\n",
      prefix + "Transfer-Encoding: chunked\r\n\r\n1\r\nxNO",
      prefix + "Transfer-Encoding: chunked\r\n\r\n0\r\nContent-Length: 9\r\n\r\n",
      "HTTP/1.1 101 Switching Protocols\r\n\r\n",
      "HTTP/1.1 100 Continue\r\nContent-Length: 1\r\n\r\n",
      prefix + "Transfer-Encoding: chunked\r\n\r\n1;bad\u{0}extension\r\n",
      prefix + "Content-Length: 1\r\n\r\nextra"
    ]
    for raw in invalid {
      let parser = YlHTTPResponseParser(url: URL(string: "https://media.test/bytes")!)
      XCTAssertThrowsError(try parser.receive(Data(raw.utf8))) { error in
        XCTAssertNotNil(error as? NativePlayerError)
      }
    }
  }

  func testManagedFramingBoundsAggregateHeadersAndDetectsPrematureEOF() throws {
    let url = URL(string: "https://media.test/bytes")!
    let huge = YlHTTPResponseParser(url: url)
    XCTAssertThrowsError(try huge.receive(Data(("HTTP/1.1 200 OK\r\nX-Pad: " + String(repeating: "x", count: 65536)).utf8)))
    let informational = YlHTTPResponseParser(url: url)
    XCTAssertThrowsError(try informational.receive(Data(String(repeating: "HTTP/1.1 100 Continue\r\nX-Pad: " + String(repeating: "x", count: 1024) + "\r\n\r\n", count: 64).utf8)))
    for raw in ["HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\na",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\na"] {
      let parser = YlHTTPResponseParser(url: url)
      _ = try parser.receive(Data(raw.utf8))
      XCTAssertThrowsError(try parser.endOfStream()) { error in
        XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
      }
    }
  }

  func testManagedRequestSerializationOwnsFramingAndRejectsHeaderInjection() throws {
    var request = URLRequest(url: URL(string: "https://media.test:444/path?q=one")!)
    request.setValue("wrong", forHTTPHeaderField: "Host")
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    request.setValue("bytes=12-", forHTTPHeaderField: "Range")
    let wire = String(decoding: try YlManagedHTTPTransport.serialize(request), as: UTF8.self)
    XCTAssertTrue(wire.contains("GET /path?q=one HTTP/1.1\r\n"))
    XCTAssertTrue(wire.contains("Host: media.test:444\r\n"))
    XCTAssertTrue(wire.contains("Accept-Encoding: identity\r\n"))
    XCTAssertTrue(wire.lowercased().contains("range: bytes=12-\r\n"))
    XCTAssertFalse(wire.contains("wrong")); XCTAssertFalse(wire.contains("gzip"))
    XCTAssertThrowsError(try YlHTTPResponseParser.validateHeader(name: "X-Key", value: "secret\r\nInjected: yes"))
    request.setValue("1", forHTTPHeaderField: "Content-Length")
    XCTAssertThrowsError(try YlManagedHTTPTransport.serialize(request))
  }

  func testManagedTransportRejectsRequiredProxyAndATSRestrictions() throws {
    let https = URL(string: "https://media.test/bytes")!
    let http = URL(string: "http://media.test/bytes")!
    XCTAssertThrowsError(try YlManagedTransportRestrictions.validate(url: https, ats: [:],
      proxySettings: ["HTTPSEnable": 1, "HTTPSProxy": "proxy.test", "HTTPSPort": 8080]))
    XCTAssertThrowsError(try YlManagedTransportRestrictions.validate(url: https, ats: [:],
      proxySettings: ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://proxy.test/config.pac"]))
    XCTAssertThrowsError(try YlManagedTransportRestrictions.validate(url: http, ats: [:], proxySettings: [:]))
    XCTAssertNoThrow(try YlManagedTransportRestrictions.validate(url: http,
      ats: ["NSAllowsArbitraryLoads": true], proxySettings: [:]))
    XCTAssertThrowsError(try YlManagedTransportRestrictions.validate(url: http,
      ats: ["NSAllowsArbitraryLoads": true, "NSExceptionDomains": ["media.test": [:]]], proxySettings: [:]))
    XCTAssertNoThrow(try YlManagedTransportRestrictions.validate(url: URL(string: "http://127.0.0.1/bytes")!,
      ats: ["NSAllowsLocalNetworking": true], proxySettings: [:]))
    XCTAssertThrowsError(try YlManagedTransportRestrictions.validate(url: https,
      ats: ["NSPinnedDomains": ["media.test": [:]]], proxySettings: [:]))
  }

}
