@testable import yl_player_macos
import Foundation
import XCTest

final class YlMacosNetworkTests: XCTestCase {
  private func descriptor(
    _ uri: String,
    kind: String = "network",
    hint: String = "automatic",
    live: Bool = false,
    headers: Bool = false
  ) -> YlMacosSourceDescriptor {
    YlMacosSourceDescriptor(
      uri: uri,
      kind: kind,
      formatHint: hint,
      isLive: live,
      hasHeaders: headers
    )
  }

  func testRoutesSupportedFallbackAndHeaderedSources() {
    XCTAssertEqual(
      YlSourceRouter.route(descriptor("file:///tmp/movie.mkv", kind: "file")),
      .localMatroska
    )
    XCTAssertEqual(
      YlSourceRouter.route(descriptor("https://media.test/movie.mkv")),
      .networkMatroska
    )
    XCTAssertEqual(
      YlSourceRouter.route(descriptor("https://media.test/live.flv", live: true)),
      .networkFlv
    )
    XCTAssertEqual(
      YlSourceRouter.route(descriptor(
        "https://media.test/live.m3u8",
        hint: "hls",
        live: true,
        headers: true
      )),
      .headeredHls
    )
  }

  func testRejectsHeadersForUnsupportedProgressiveMedia() {
    XCTAssertEqual(
      YlSourceRouter.route(descriptor(
        "https://media.test/movie.mp4",
        headers: true
      )).rejectionCode,
      "container.headers_require_fallback"
    )
  }

  func testCrossOriginRedirectStripsCredentialHeaders() throws {
    let policy = YlNetworkRequestPolicy(recipe: YlNetworkRequestRecipe(
      url: URL(string: "https://a.test/live")!,
      headers: [
        "Authorization": "Bearer secret",
        "Cookie": "sid=secret",
        "Proxy-Authorization": "Basic secret",
        "User-Agent": "yl-test",
      ],
      configuration: YlNetworkConfiguration(map: [:]),
      mode: .randomAccessVOD
    ))
    _ = try policy.request(offset: 0, validator: nil)
    let response = HTTPURLResponse(
      url: URL(string: "https://a.test/live")!,
      statusCode: 302,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!

    let redirected = try policy.redirectRequest(
      from: URL(string: "https://a.test/live")!,
      response: response,
      to: URL(string: "https://b.test/live")!
    )

    XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(redirected.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(redirected.value(forHTTPHeaderField: "Proxy-Authorization"))
    XCTAssertEqual(redirected.value(forHTTPHeaderField: "User-Agent"), "yl-test")
  }

  func testRangeValidationRejectsNonzeroHTTP200() throws {
    let policy = YlNetworkRequestPolicy(recipe: YlNetworkRequestRecipe(
      url: URL(string: "https://media.test/movie.mkv")!,
      headers: [:],
      configuration: YlNetworkConfiguration(map: [:]),
      mode: .randomAccessVOD
    ))
    let response = HTTPURLResponse(
      url: URL(string: "https://media.test/movie.mkv")!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Length": "123"]
    )!

    XCTAssertThrowsError(try policy.validate(response: response, requestedOffset: 40)) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "network.range_not_supported")
    }
  }

  func testRingBufferEnforcesCapacityAndCancellation() throws {
    let ring = YlByteRingBuffer(capacity: 4)
    XCTAssertEqual(try ring.append(Data([1, 2, 3, 4]), at: 0), 4)
    XCTAssertEqual(try ring.append(Data([5]), at: 4), 0)
    XCTAssertEqual(ring.bufferedBytes, 4)

    ring.cancel()
    var byte: UInt8 = 0
    XCTAssertThrowsError(try withUnsafeMutableBytes(of: &byte) { try ring.read(into: $0) })
  }
}
