@testable import yl_player_ios
import XCTest

final class YlHlsManifestRewriterTests: XCTestCase {
  func testURLCodecRoundTripsHTTPAndHTTPSURLs() throws {
    for source in [
      "https://media.test/live/segment%201.ts?token=a%2Fb#part",
      "http://127.0.0.1:8080/master.m3u8",
    ] {
      let original = try XCTUnwrap(URL(string: source))
      let encoded = try YlHlsURLCodec.encode(original)

      XCTAssertEqual(encoded.scheme, "ylhls")
      XCTAssertEqual(try YlHlsURLCodec.decode(encoded), original)
    }
  }

  func testURLCodecRejectsNonHTTPDestinations() throws {
    XCTAssertThrowsError(
      try YlHlsURLCodec.encode(URL(string: "file:///tmp/master.m3u8")!)
    ) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "container.hls_url_invalid")
    }

    let payload = Data("file:///tmp/key.bin".utf8)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    XCTAssertThrowsError(
      try YlHlsURLCodec.decode(URL(string: "ylhls://resource/\(payload)")!)
    ) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "container.hls_url_invalid")
    }
  }

  func testRewritesEverySupportedManifestURIForm() throws {
    let manifest = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",URI="audio/index.m3u8"
    #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=86000,URI="iframe.m3u8"
    #EXT-X-SESSION-KEY:METHOD=AES-128,URI="https://keys.test/session.key"
    #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
    #EXT-X-MAP:URI="init.mp4?version=2"
    #EXT-X-PART:DURATION=0.333,URI="parts/part0.m4s"
    #EXT-X-PRELOAD-HINT:TYPE=PART,URI="?next=part1"
    #EXT-X-RENDITION-REPORT:URI="../other/live.m3u8",LAST-MSN=12
    #EXT-X-STREAM-INF:BANDWIDTH=1280000
    variant/main.m3u8
    #EXTINF:4.0,
    https://cdn.test/video/segment.ts?x=1
    """
    let baseURL = try XCTUnwrap(URL(
      string: "https://media.test/live/master.m3u8?auth=top"
    ))

    let rewrittenData = try YlHlsManifestRewriter.rewrite(
      data: Data(manifest.utf8),
      baseURL: baseURL
    )
    let rewritten = try XCTUnwrap(String(data: rewrittenData, encoding: .utf8))
    let encodedURLs = try internalURLs(in: rewritten)
    let decoded = try encodedURLs.map(YlHlsURLCodec.decode)

    XCTAssertEqual(Set(decoded.map(\.absoluteString)), Set([
      "https://media.test/live/audio/index.m3u8",
      "https://media.test/live/iframe.m3u8",
      "https://keys.test/session.key",
      "https://media.test/live/key.bin",
      "https://media.test/live/init.mp4?version=2",
      "https://media.test/live/parts/part0.m4s",
      "https://media.test/live/master.m3u8?next=part1",
      "https://media.test/other/live.m3u8",
      "https://media.test/live/variant/main.m3u8",
      "https://cdn.test/video/segment.ts?x=1",
    ]))
  }

  func testPreservesCRLFAndTrailingNewline() throws {
    let manifest = "#EXTM3U\r\n#EXTINF:4,\r\nsegment.ts\r\n"

    let rewritten = try YlHlsManifestRewriter.rewrite(
      data: Data(manifest.utf8),
      baseURL: URL(string: "https://media.test/live/index.m3u8")!
    )
    let text = try XCTUnwrap(String(data: rewritten, encoding: .utf8))

    XCTAssertTrue(text.hasSuffix("\r\n"))
    XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
  }

  func testMalformedUTF8ReturnsStableManifestError() {
    XCTAssertThrowsError(try YlHlsManifestRewriter.rewrite(
      data: Data([0x23, 0xFF, 0x0A]),
      baseURL: URL(string: "https://media.test/master.m3u8")!
    )) { error in
      XCTAssertEqual((error as? NativePlayerError)?.category, "container")
      XCTAssertEqual((error as? NativePlayerError)?.code, "container.hls_manifest_invalid")
    }
  }

  private func internalURLs(in manifest: String) throws -> [URL] {
    let expression = try NSRegularExpression(pattern: "ylhls://[^\\\"\\s,]+")
    let range = NSRange(manifest.startIndex..., in: manifest)
    return expression.matches(in: manifest, range: range).compactMap { match in
      guard let swiftRange = Range(match.range, in: manifest) else { return nil }
      return URL(string: String(manifest[swiftRange]))
    }
  }
}
