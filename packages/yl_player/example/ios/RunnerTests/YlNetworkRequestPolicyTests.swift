@testable import yl_player_ios
import Foundation
import XCTest

final class YlNetworkRequestPolicyTests: XCTestCase {
  private func makePolicy(
    url: String = "https://media.test/movie.mkv?token=secret#fragment",
    headers: [String: String] = [:],
    maxRedirects: Int = 5
  ) -> YlNetworkRequestPolicy {
    YlNetworkRequestPolicy(
      recipe: YlNetworkRequestRecipe(
        url: URL(string: url)!,
        headers: headers,
        configuration: YlNetworkConfiguration(map: [
          "maxRedirects": maxRedirects,
        ])
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
    XCTAssertEqual(received.diagnostic, "HTTP 403 https://media.test/movie.mkv")
  }
}
