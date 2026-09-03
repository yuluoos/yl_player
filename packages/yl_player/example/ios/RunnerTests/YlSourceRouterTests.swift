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

  func testRemoteMkvVodRoutesToNetworkFallback() {
    let source = YlIosSourceDescriptor(
      uri: "https://media.test/movie.mkv",
      kind: "network",
      formatHint: "matroska",
      isLive: false,
      hasHeaders: true
    )

    XCTAssertEqual(YlSourceRouter.route(source), .networkMatroska)
  }

  func testAutomaticRemoteMkvRoutesToNetworkFallback() {
    let source = YlIosSourceDescriptor(
      uri: "https://media.test/movie.mkv?token=secret",
      kind: "network",
      formatHint: "automatic",
      isLive: false,
      hasHeaders: false
    )

    XCTAssertEqual(YlSourceRouter.route(source), .networkMatroska)
  }

  func testRemoteMkvLiveIsRejected() {
    let source = YlIosSourceDescriptor(
      uri: "https://media.test/live.mkv",
      kind: "network",
      formatHint: "matroska",
      isLive: true,
      hasHeaders: false
    )

    XCTAssertEqual(
      YlSourceRouter.route(source).rejectionCode,
      "container.network_mkv_live_unsupported"
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
