@testable import yl_player_apple
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
      XCTAssertEqual(encoded.lastPathComponent, original.lastPathComponent)
      XCTAssertEqual(encoded.pathExtension, original.pathExtension)
      XCTAssertEqual(
        try YlHlsURLCodec.resourceKind(encoded),
        original.pathExtension == "m3u8" ? .manifest : .media
      )
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
    let keyKinds = try encodedURLs.filter {
      try YlHlsURLCodec.resourceKind($0) == .key
    }
    XCTAssertEqual(keyKinds.count, 2)
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

  func testTagSemanticsClassifyExtensionlessAndQueryOnlyResources() throws {
    let manifest = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",URI="audio-playlist"
    #EXT-X-PRELOAD-HINT:TYPE=PART,URI="?next=part1"
    #EXT-X-STREAM-INF:BANDWIDTH=1280000
    video-playlist
    #EXTINF:4,
    segment-without-extension
    """
    let baseURL = URL(string: "https://media.test/live/master.m3u8")!
    let rewritten = try YlHlsManifestRewriter.rewrite(
      data: Data(manifest.utf8),
      baseURL: baseURL,
      mediaURL: { url in
        URL(string: "http://127.0.0.1:9999/\(url.lastPathComponent)")!
      }
    )
    let text = try XCTUnwrap(String(data: rewritten, encoding: .utf8))

    XCTAssertTrue(text.contains("URI=\"ylhls://"))
    XCTAssertTrue(text.contains("URI=\"http://127.0.0.1:9999/master.m3u8\""))
    XCTAssertTrue(text.contains("ylhls://resource/"))
    XCTAssertTrue(text.contains("/manifest/video-playlist"))
    XCTAssertTrue(text.contains("http://127.0.0.1:9999/segment-without-extension"))
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

  func testMissingExtM3UMarkerReturnsStableManifestError() {
    XCTAssertThrowsError(try YlHlsManifestRewriter.rewrite(
      data: Data("segment.ts\n".utf8),
      baseURL: URL(string: "https://media.test/master.m3u8")!
    )) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "container.hls_manifest_invalid")
    }
  }

  func testManagedTransportStreamPlaylistBuildsSeekableTimeline() throws {
    let manifest = """
    #EXTM3U
    #EXT-X-TARGETDURATION:5
    #EXT-X-MEDIA-SEQUENCE:17
    #EXTINF:4.0,
    segment-17.ts
    #EXTINF:3.5,
    segment-18.ts?token=one
    #EXTINF:5.0,
    segment-19.ts
    #EXT-X-ENDLIST
    """

    let playlist = try YlHlsMediaPlaylist.parse(
      data: Data(manifest.utf8),
      baseURL: URL(string: "http://127.0.0.1:8080/media/index.m3u8")!
    )

    XCTAssertEqual(playlist.durationUs, 12_500_000)
    XCTAssertEqual(playlist.segments.map(\.startUs), [0, 4_000_000, 7_500_000])
    XCTAssertEqual(playlist.segmentIndex(containing: 0), 0)
    XCTAssertEqual(playlist.segmentIndex(containing: 3_999_999), 0)
    XCTAssertEqual(playlist.segmentIndex(containing: 4_000_000), 1)
    XCTAssertEqual(playlist.segmentIndex(containing: 12_500_000), 2)
    XCTAssertEqual(
      playlist.segments[1].url.absoluteString,
      "http://127.0.0.1:8080/media/segment-18.ts?token=one"
    )
  }

  func testManagedTransportStreamPlaylistRejectsUnsupportedHlsFeatures() throws {
    let baseURL = URL(string: "http://127.0.0.1:8080/media/index.m3u8")!
    let unsupported = [
      "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nvariant.m3u8\n",
      "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:4,\na.ts\n#EXT-X-ENDLIST\n",
      "#EXTM3U\n#EXTINF:4,\na.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:4,\nb.ts\n#EXT-X-ENDLIST\n",
      "#EXTM3U\n#EXTINF:4,\nhttps://other.test/a.ts\n#EXT-X-ENDLIST\n",
    ]

    for manifest in unsupported {
      XCTAssertThrowsError(try YlHlsMediaPlaylist.parse(
        data: Data(manifest.utf8),
        baseURL: baseURL
      )) { error in
        XCTAssertEqual(
          (error as? NativePlayerError)?.code,
          "container.hls_managed_unsupported"
        )
      }
    }
  }

  func testManagedTransportStreamByteSourceConcatenatesAndSeeksByTime() throws {
    let baseURL = URL(string: "http://127.0.0.1:8080/media/index.m3u8")!
    let playlist = try YlHlsMediaPlaylist.parse(
      data: Data("""
      #EXTM3U
      #EXTINF:4,
      a.ts
      #EXTINF:3,
      b.ts
      #EXTINF:5,
      c.ts
      #EXT-X-ENDLIST
      """.utf8),
      baseURL: baseURL
    )
    let payloads = ["a.ts": Data("AAAA".utf8), "b.ts": Data("BBB".utf8),
                    "c.ts": Data("CCCCC".utf8)]
    let source = YlHlsSegmentByteSource(playlist: playlist) { url in
      try XCTUnwrap(payloads[url.lastPathComponent])
    }
    defer { source.cancel() }

    var initial = [UInt8](repeating: 0, count: 16)
    let initialCount = try initial.withUnsafeMutableBytes { try source.read(into: $0) }
    XCTAssertEqual(String(decoding: initial.prefix(initialCount), as: UTF8.self), "AAAABBBCCCCC")
    XCTAssertEqual(source.durationUs, 12_000_000)

    XCTAssertEqual(try source.seek(toMediaTimeUs: 5_500_000), 4_000_000)
    var afterSeek = [UInt8](repeating: 0, count: 8)
    let seekCount = try afterSeek.withUnsafeMutableBytes { try source.read(into: $0) }
    XCTAssertEqual(String(decoding: afterSeek.prefix(seekCount), as: UTF8.self), "BBBCCCCC")
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
