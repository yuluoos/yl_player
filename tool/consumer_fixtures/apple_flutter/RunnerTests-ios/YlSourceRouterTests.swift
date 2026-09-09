@testable import yl_player_apple
import XCTest

final class YlSourceRouterTests: XCTestCase {
  func testLocalMkvRoutesToFallback() {
    let source = YlAppleSourceDescriptor(
      uri: "file:///tmp/movie.mkv",
      kind: .file,
      formatHint: .automatic,
      intent: .automatic, headers: [:]
    )

    XCTAssertEqual(YlSourceRouter.route(source), .localMatroska)
  }

  func testExplicitLocalMatroskaRoutesToFallback() {
    let source = YlAppleSourceDescriptor(
      uri: "file:///tmp/movie.bin",
      kind: .file,
      formatHint: .matroska,
      intent: .automatic, headers: [:]
    )

    XCTAssertEqual(YlSourceRouter.route(source), .localMatroska)
  }

  func testRemoteMkvVodRoutesToNetworkFallback() {
    let source = YlAppleSourceDescriptor(
      uri: "https://media.test/movie.mkv",
      kind: .network,
      formatHint: .matroska,
      intent: .automatic, headers: ["X-Test": "test"]
    )

    XCTAssertEqual(YlSourceRouter.route(source), .networkMatroska)
  }

  func testAutomaticRemoteMkvRoutesToNetworkFallback() {
    let source = YlAppleSourceDescriptor(
      uri: "https://media.test/movie.mkv?token=secret",
      kind: .network,
      formatHint: .automatic,
      intent: .automatic, headers: [:]
    )

    XCTAssertEqual(YlSourceRouter.route(source), .networkMatroska)
  }

  func testRemoteMkvLiveIsRejected() {
    let source = YlAppleSourceDescriptor(
      uri: "https://media.test/live.mkv",
      kind: .network,
      formatHint: .matroska,
      intent: .live, headers: [:]
    )

    XCTAssertEqual(
      YlSourceRouter.route(source).rejectionCode,
      "container.network_mkv_live_unsupported"
    )
  }

  func testHeaderedHlsRoutesToResourceLoader() {
    let source = YlAppleSourceDescriptor(
      uri: "https://media.test/movie.m3u8",
      kind: .network,
      formatHint: .hls,
      intent: .live, headers: ["X-Test": "test"]
    )

    XCTAssertEqual(YlSourceRouter.route(source), .headeredHls)
  }

  func testHeaderedProgressiveMp4StaysRejected() {
    let source = YlAppleSourceDescriptor(
      uri: "https://media.test/movie.mp4",
      kind: .network,
      formatHint: .automatic,
      intent: .automatic, headers: ["X-Test": "test"]
    )

    XCTAssertEqual(
      YlSourceRouter.route(source).rejectionCode,
      "container.headers_require_fallback"
    )
  }

  func testHttpFlvRoutesToSequentialFallback() {
    let source = YlAppleSourceDescriptor(
      uri: "https://media.test/live.flv?token=secret",
      kind: .network,
      formatHint: .automatic,
      intent: .live, headers: ["X-Test": "test"]
    )

    XCTAssertEqual(YlSourceRouter.route(source), .networkFlv)
  }

  func testExplicitHttpFlvHintRoutesWithoutFlvExtension() {
    let source = YlAppleSourceDescriptor(
      uri: "https://media.test/live?id=42",
      kind: .network,
      formatHint: .flv,
      intent: .live, headers: [:]
    )

    XCTAssertEqual(YlSourceRouter.route(source), .networkFlv)
  }

  func testHlsRemainsOnAvPlayer() {
    let source = YlAppleSourceDescriptor(
      uri: "https://media.test/live.m3u8",
      kind: .network,
      formatHint: .hls,
      intent: .live, headers: [:]
    )

    XCTAssertEqual(YlSourceRouter.route(source), .avPlayer)
  }

  func testMalformedUriIsRejected() {
    let source = YlAppleSourceDescriptor(
      uri: "not a uri",
      kind: .network,
      formatHint: .automatic,
      intent: .automatic, headers: [:]
    )

    XCTAssertEqual(YlSourceRouter.route(source).rejectionCode, "source.invalid_uri")
  }
}
