@testable import yl_player_macos
import Foundation
import XCTest

final class YlMacosHlsTests: XCTestCase {
  func testSensitiveHeadersRemainSameOriginAndAreRemovedCrossOrigin() {
    let policy = YlHlsHeaderPolicy(
      originURL: URL(string: "https://media.test:443/master.m3u8")!,
      headers: [
        "Authorization": "Bearer secret",
        "Cookie": "sid=secret",
        "Proxy-Authorization": "Basic secret",
        "X-Client": "yl-test",
      ]
    )

    let same = policy.headers(for: URL(string: "https://MEDIA.TEST/segment.ts")!)
    XCTAssertEqual(same["Authorization"], "Bearer secret")
    XCTAssertEqual(same["Cookie"], "sid=secret")

    let cross = policy.headers(for: URL(string: "https://cdn.test/segment.ts")!)
    XCTAssertNil(cross["Authorization"])
    XCTAssertNil(cross["Cookie"])
    XCTAssertNil(cross["Proxy-Authorization"])
    XCTAssertEqual(cross["X-Client"], "yl-test")
  }

  func testManifestRewriterResolvesPlaylistAndMediaURLs() throws {
    let input = Data("""
      #EXTM3U
      #EXT-X-STREAM-INF:BANDWIDTH=1000
      child/index.m3u8
      #EXTINF:2.0,
      segment.ts
      """.utf8)

    let output = try YlHlsManifestRewriter.rewrite(
      data: input,
      baseURL: URL(string: "https://media.test/root/master.m3u8")!
    )
    let text = String(decoding: output, as: UTF8.self)

    XCTAssertTrue(text.contains("ylhls://resource/"))
    XCTAssertTrue(text.contains("/manifest/index.m3u8"))
    XCTAssertTrue(text.contains("/media/segment.ts"))
  }
}
