@testable import yl_player_ios
import XCTest

final class YlSourceRouterTests: XCTestCase {
  func testLocalMkvRoutesToFallback() {
    let source = YlIosSourceDescriptor(
      uri: "file:///tmp/movie.mkv",
      kind: "file",
      formatHint: "automatic",
      isLive: false,
      hasHeaders: false
    )

    XCTAssertEqual(YlSourceRouter.route(source), .localMatroska)
  }

  func testExplicitLocalMatroskaRoutesToFallback() {
    let source = YlIosSourceDescriptor(
      uri: "file:///tmp/movie.bin",
      kind: "file",
      formatHint: "matroska",
      isLive: false,
      hasHeaders: false
    )

    XCTAssertEqual(YlSourceRouter.route(source), .localMatroska)
  }

  func testRemoteMkvStaysRejected() {
    let source = YlIosSourceDescriptor(
      uri: "https://media.test/movie.mkv",
      kind: "network",
      formatHint: "matroska",
      isLive: false,
      hasHeaders: false
    )

    XCTAssertEqual(
      YlSourceRouter.route(source).rejectionCode,
      "container.native_fallback_required"
    )
  }

  func testCustomHeadersStayRejected() {
    let source = YlIosSourceDescriptor(
      uri: "https://media.test/movie.m3u8",
      kind: "network",
      formatHint: "hls",
      isLive: true,
      hasHeaders: true
    )

    XCTAssertEqual(
      YlSourceRouter.route(source).rejectionCode,
      "container.headers_require_fallback"
    )
  }

  func testHlsRemainsOnAvPlayer() {
    let source = YlIosSourceDescriptor(
      uri: "https://media.test/live.m3u8",
      kind: "network",
      formatHint: "hls",
      isLive: true,
      hasHeaders: false
    )

    XCTAssertEqual(YlSourceRouter.route(source), .avPlayer)
  }

  func testMalformedUriIsRejected() {
    let source = YlIosSourceDescriptor(
      uri: "not a uri",
      kind: "network",
      formatHint: "automatic",
      isLive: false,
      hasHeaders: false
    )

    XCTAssertEqual(YlSourceRouter.route(source).rejectionCode, "source.invalid_uri")
  }
}
