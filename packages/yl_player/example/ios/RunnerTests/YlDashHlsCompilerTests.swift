@testable import yl_player_apple
import XCTest

final class YlDashHlsCompilerTests: XCTestCase {
  private let source = URL(string: "https://origin.test/dash/manifest.mpd")!
  private func period(_ inner: String? = nil, base: String = "", start: Int = 0) -> String {
    """
    <Period start="PT\(start)S" duration="PT4S">\(base)<AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1.42c01e" width="320" height="180"><Representation id="v" bandwidth="350000">\(inner ?? "<SegmentTemplate timescale=\"1\" duration=\"2\" initialization=\"init-$RepresentationID$.mp4\" media=\"seg-$Number%03d$.m4s\"/>")</Representation></AdaptationSet></Period>
    """
  }
  private func mpd(_ periods: String, duration: Int = 4) -> String {
    "<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" type=\"static\" mediaPresentationDuration=\"PT\(duration)S\">\(periods)</MPD>"
  }
  private func compile(_ xml: String, stripped: Bool = false, final: URL? = nil,
    seen: ((URL, Bool) -> Void)? = nil) throws -> YlDashHlsPresentation {
    try YlDashHlsCompiler.compile(data: Data(xml.utf8), finalManifestURL: final ?? source,
      sourceURL: source, credentialsStripped: stripped,
      manifestURL: { URL(string: "https://virtual.test/\($0).m3u8")! },
      mediaURL: { url, strip in seen?(url, strip); return url })
  }
  private func video(_ result: YlDashHlsPresentation) -> String {
    String(data: result.manifests[URL(string: "https://virtual.test/video.m3u8")!]!, encoding: .utf8)!
  }
  private func reject(_ xml: String, file: StaticString = #filePath, line: UInt = #line) {
    var emitted = 0
    XCTAssertThrowsError(try compile(xml, seen: { _, _ in emitted += 1 }), file: file, line: line) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "container.unsupported", file: file, line: line)
      XCTAssertFalse(String(describing: error).contains("origin.test"), file: file, line: line)
    }
    XCTAssertEqual(emitted, 0, "Unsupported MPD must fail before media emission", file: file, line: line)
  }
  func testSinglePeriodProducesMapDurationsAndRewrittenManifestReference() throws {
    var resources: [String] = []
    let p = try compile(mpd(period()), seen: { resources.append($0.absoluteString); XCTAssertFalse($1) })
    XCTAssertEqual(p.durationUs, 4_000_000)
    XCTAssertEqual(p.manifests.count, 2)
    XCTAssertEqual(resources, ["https://origin.test/dash/init-v.mp4", "https://origin.test/dash/seg-001.m4s", "https://origin.test/dash/seg-002.m4s"])
    XCTAssertTrue(video(p).contains("#EXT-X-MAP:URI=\"https://origin.test/dash/init-v.mp4\""))
    XCTAssertEqual(video(p).components(separatedBy: "#EXTINF:2.000000,").count - 1, 2)
    XCTAssertTrue(video(p).hasSuffix("#EXT-X-ENDLIST\n"))
    let master = String(data: p.manifests[p.rootURL]!, encoding: .utf8)!
    let child = URL(string: master.components(separatedBy: "\n").first { $0.hasPrefix("ylhls:") }!)!
    XCTAssertNotNil(p.manifests[try YlHlsURLCodec.decode(child)])
  }
  func testTwoPeriodsHaveOneDiscontinuityAndDistinctInitialization() throws {
    let p = try compile(mpd(period(base: "<BaseURL>one/</BaseURL>") + period(base: "<BaseURL>two/</BaseURL>", start: 4), duration: 8))
    XCTAssertEqual(p.durationUs, 8_000_000)
    XCTAssertEqual(video(p).components(separatedBy: "#EXT-X-DISCONTINUITY\n").count - 1, 1)
    XCTAssertTrue(video(p).contains("/one/init-v.mp4")); XCTAssertTrue(video(p).contains("/two/init-v.mp4"))
  }
  func testTimelineTimeAndFiniteNegativeRepeat() throws {
    let xml = mpd(period("<SegmentTemplate timescale=\"10\" initialization=\"init.mp4\" media=\"$Time$-$Bandwidth$.m4s\"><SegmentTimeline><S t=\"0\" d=\"20\" r=\"-1\"/></SegmentTimeline></SegmentTemplate>"))
    let p = try compile(xml)
    XCTAssertTrue(video(p).contains("/0-350000.m4s")); XCTAssertTrue(video(p).contains("/20-350000.m4s"))
  }
  func testSegmentListRetainsExplicitInitializationAndMediaRanges() throws {
    let p = try compile(mpd(period("<SegmentList timescale=\"1\" duration=\"2\"><Initialization sourceURL=\"all.mp4\" range=\"0-99\"/><SegmentURL media=\"all.mp4\" mediaRange=\"100-199\"/><SegmentURL media=\"all.mp4\" mediaRange=\"200-399\"/></SegmentList>")))
    XCTAssertTrue(video(p).contains("BYTERANGE=\"100@0\""))
    XCTAssertTrue(video(p).contains("#EXT-X-BYTERANGE:200@200"))
  }
  func testCrossOriginAncestryCannotRegainCredentialsAndDuplicateUsesStrictest() throws {
    let first = period()
    let second = period(base: "<BaseURL>https://foreign.test/</BaseURL>", start: 4).replacingOccurrences(of: "<Representation ", with: "<Representation ").replacingOccurrences(of: "<SegmentTemplate", with: "<BaseURL>https://origin.test/dash/</BaseURL><SegmentTemplate")
    var strips: [Bool] = []
    let p = try compile(mpd(first + second, duration: 8), seen: { _, s in strips.append(s) })
    XCTAssertTrue(strips.allSatisfy { $0 }); XCTAssertEqual(p.strippedResources.count, 3)
  }
  func testRedirectStrippingAndFinalOriginDifferenceAreSticky() throws {
    for final in [source, URL(string: "https://cdn.test/m.mpd")!] {
      var stripped: [Bool] = []
      _ = try compile(mpd(period()), stripped: final == source, final: final, seen: { _, s in stripped.append(s) })
      XCTAssertTrue(stripped.allSatisfy { $0 })
    }
  }
  func testRejectsDynamicDRMPTOAndMissingInitialization() {
    let valid = mpd(period())
    reject(valid.replacingOccurrences(of: "static", with: "dynamic"))
    reject(valid.replacingOccurrences(of: "<Representation", with: "<ContentProtection/><Representation"))
    reject(valid.replacingOccurrences(of: "timescale=\"1\"", with: "timescale=\"1\" presentationTimeOffset=\"1\""))
    reject(valid.replacingOccurrences(of: "initialization=\"init-$RepresentationID$.mp4\"", with: ""))
  }
  func testRejectsGapsOverlapsAndUnverifiedTail() {
    reject(mpd(period(start: 1)))
    reject(mpd(period() + period(start: 3), duration: 8))
    reject(mpd(period().replacingOccurrences(of: "duration=\"2\"", with: "duration=\"3\"")))
    reject(mpd(period("<SegmentTemplate initialization=\"i\" media=\"$Time$\"><SegmentTimeline><S t=\"1\" d=\"4\"/></SegmentTimeline></SegmentTemplate>")))
  }
  func testRejectsMultipleVariantsSegmentBaseAndRemoteFeatures() {
    let p = period()
    reject(mpd(p.replacingOccurrences(of: "</AdaptationSet>", with: "<Representation id=\"other\"/></AdaptationSet>")))
    for node in ["SegmentBase", "UTCTiming", "EssentialProperty", "Location", "ContentSteering"] {
      reject(mpd(p).replacingOccurrences(of: "</MPD>", with: "<\(node)/></MPD>"))
    }
  }
  func testRejectsUnsafeURLsDTDDepthAndLargePayload() {
    reject("<!DOCTYPE MPD [<!ENTITY x SYSTEM 'https://origin.test/secret'>]>" + mpd(period()))
    reject(mpd(period(base: "<BaseURL>https://user:pass@origin.test/</BaseURL>")))
    reject(mpd(period(base: "<BaseURL>file:///tmp/</BaseURL>")))
    reject(mpd(String(repeating: "<meta>", count: 65) + String(repeating: "</meta>", count: 65) + period()))
    reject(String(repeating: " ", count: 2 * 1024 * 1024 + 1))
  }
  func testRejectsHugeRepeatsFormattingURIAndIntegerOverflow() {
    reject(mpd(period("<SegmentTemplate initialization=\"i\" media=\"$Time$\"><SegmentTimeline><S d=\"1\" r=\"9223372036854775807\"/></SegmentTimeline></SegmentTemplate>")))
    reject(mpd(period().replacingOccurrences(of: "%03d", with: "%999999999d")))
    reject(mpd(period(base: "<BaseURL>https://origin.test/" + String(repeating: "x", count: 8193) + "</BaseURL>")))
    reject(mpd(period().replacingOccurrences(of: "timescale=\"1\"", with: "timescale=\"9223372036854775807\"")))
  }
  func testTemplateInheritanceKeepsParentTimelineAndOverridesStartNumber() throws {
    let inherited = "<SegmentTemplate timescale=\"10\" initialization=\"init-$RepresentationID$.mp4\" media=\"$Number$-$Time$.m4s\"><SegmentTimeline><S d=\"20\" r=\"1\"/></SegmentTimeline></SegmentTemplate>"
    let xml = mpd(period("<SegmentTemplate startNumber=\"7\"/>")
      .replacingOccurrences(of: "<Representation", with: inherited + "<Representation"))
    let playlist = video(try compile(xml))
    XCTAssertTrue(playlist.contains("/7-0.m4s")); XCTAssertTrue(playlist.contains("/8-20.m4s"))
  }
  func testAVTracksPreserveFractionalSampleDurationsAcrossTwoPeriods() throws {
    let audio = "<AdaptationSet contentType=\"audio\" mimeType=\"audio/mp4\"><Representation id=\"a\" codecs=\"mp4a.40.2\" bandwidth=\"64000\" audioSamplingRate=\"48000\"><SegmentTemplate timescale=\"48000\" initialization=\"a-init.mp4\" media=\"a-$Time$.m4s\"><SegmentTimeline><S t=\"0\" d=\"47104\"/><S d=\"48128\" r=\"2\"/><S d=\"512\"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet>"
    let one = period().replacingOccurrences(of: "</Period>", with: audio + "</Period>")
    let two = one.replacingOccurrences(of: "start=\"PT0S\"", with: "start=\"PT4S\"")
    let result = try compile(mpd(one + two, duration: 8))
    XCTAssertEqual(result.manifests.count, 3); XCTAssertEqual(result.durationUs, 8_000_000)
    let playlist = String(data: result.manifests[URL(string: "https://virtual.test/audio.m3u8")!]!, encoding: .utf8)!
    XCTAssertEqual(playlist.components(separatedBy: "#EXTINF:").count - 1, 10)
    XCTAssertEqual(playlist.components(separatedBy: "#EXT-X-DISCONTINUITY\n").count - 1, 1)
    XCTAssertTrue(playlist.contains("#EXTINF:0.010667,"))
    reject(mpd(one + two.replacingOccurrences(of: "48000", with: "44100"), duration: 8))
    reject(mpd(one + period(start: 4), duration: 8))
  }
  func testTrackChangesAndMultipleBaseURLsAreRejected() {
    let main = period().replacingOccurrences(of: "<Representation", with: "<Role schemeIdUri=\"urn:mpeg:dash:role:2011\" value=\"main\"/><Representation")
    let alternate = period(start: 4).replacingOccurrences(of: "<Representation", with: "<Role schemeIdUri=\"urn:mpeg:dash:role:2011\" value=\"alternate\"/><Representation")
    reject(mpd(main + alternate, duration: 8))
    reject(mpd(period() + period(start: 4).replacingOccurrences(of: "width=\"320\"", with: "width=\"640\""), duration: 8))
    reject(mpd(period(base: "<BaseURL>a/</BaseURL><BaseURL>b/</BaseURL>")))
    reject(mpd(period()).replacingOccurrences(of: "<Period ", with: "<Period xmlns:xlink=\"http://www.w3.org/1999/xlink\" xlink:href=\"https://origin.test/secret\" "))
  }
  func testAggregateSegmentAndURIBudgetsRejectBeforeMediaEmission() {
    let template = "<SegmentTemplate initialization=\"i\" media=\"$Number$.m4s\" timescale=\"100000\" duration=\"1\"/>"
    var emitted = 0
    XCTAssertThrowsError(try compile(mpd(period(template)), seen: { _, _ in emitted += 1 }))
    XCTAssertEqual(emitted, 0)
    let long = String(repeating: "a", count: 8000)
    let big = "<SegmentTemplate initialization=\"i\" media=\"" + long + "$Number$.m4s\" timescale=\"1000\" duration=\"4\"/>"
    XCTAssertThrowsError(try compile(mpd(period(big)), seen: { _, _ in emitted += 1 }))
    XCTAssertEqual(emitted, 0)
  }
  func testElementAndPeriodBudgetsRejectWithoutUnboundedExpansion() {
    reject(mpd(String(repeating: "<meta/>", count: 100001) + period()))
    reject(mpd((0..<65).map { period(start: $0 * 4) }.joined(), duration: 260))
  }
  func testGeneratedPlaylistBudgetAndIdentityCollisionFailSafely() {
    let xml = mpd(period("<SegmentTemplate initialization=\"i\" media=\"$Number$.m4s\" timescale=\"1000\" duration=\"4\"/>"))
    XCTAssertThrowsError(try YlDashHlsCompiler.compile(data: Data(xml.utf8), finalManifestURL: source, sourceURL: source, credentialsStripped: false,
      manifestURL: { URL(string: "https://virtual.test/\($0).m3u8")! },
      mediaURL: { _, _ in URL(string: "https://proxy.test/" + String(repeating: "x", count: 8000))! })) { error in
        XCTAssertEqual((error as? NativePlayerError)?.code, "container.unsupported")
      }
    XCTAssertThrowsError(try YlDashHlsCompiler.compile(data: Data(mpd(period()).utf8), finalManifestURL: source, sourceURL: source, credentialsStripped: false,
      manifestURL: { _ in URL(string: "https://virtual.test/same.m3u8")! }, mediaURL: { u, _ in u }))
  }
  func testProxyClosureReceivesEveryInitializationAndMediaAndErrorsAreSanitized() throws {
    let p = try YlDashHlsCompiler.compile(data: Data(mpd(period()).utf8), finalManifestURL: source, sourceURL: source, credentialsStripped: false,
      manifestURL: { URL(string: "https://virtual.test/\($0).m3u8")! },
      mediaURL: { u, _ in URL(string: "http://127.0.0.1:12345/" + u.lastPathComponent)! })
    XCTAssertFalse(video(p).contains("origin.test"))
    XCTAssertTrue(video(p).contains("http://127.0.0.1:12345/init-v.mp4"))
    XCTAssertThrowsError(try YlDashHlsCompiler.compile(data: Data(mpd(period()).utf8), finalManifestURL: source, sourceURL: source, credentialsStripped: false,
      manifestURL: { _ in throw NSError(domain: "https://origin.test/secret", code: 1) }, mediaURL: { u, _ in u })) { error in
        XCTAssertEqual((error as? NativePlayerError)?.code, "container.unsupported")
        XCTAssertFalse(String(describing: error).contains("secret"))
      }
  }

  func testRejectsUnsupportedSegmentTimingAtEveryInheritanceScope() {
    for attribute in ["eptDelta=\"1\"", "pdDelta=\"-1\"", "endNumber=\"1\""] {
      let leaf = mpd(period())
      reject(leaf.replacingOccurrences(of: "<SegmentTemplate ", with: "<SegmentTemplate \(attribute) "))
      for marker in ["<Period ", "<AdaptationSet ", "<Representation "] {
        reject(leaf.replacingOccurrences(of: marker, with: "<SegmentTemplate \(attribute)/>" + marker))
      }
      let list = "<SegmentList duration=\"2\"><Initialization sourceURL=\"i.mp4\"/><SegmentURL media=\"one.m4s\"/><SegmentURL media=\"two.m4s\"/></SegmentList>"
      reject(mpd(period(list.replacingOccurrences(of: "<SegmentList ", with: "<SegmentList \(attribute) "))))
      for marker in ["<Period ", "<AdaptationSet ", "<Representation "] {
        reject(mpd(period(list)).replacingOccurrences(of: marker, with: "<SegmentList \(attribute)/>" + marker))
      }
    }
  }
  func testRejectsExplicitTimelineNumberAndUnknownSampleSemantics() {
    for attribute in ["n=\"7\"", "k=\"2\""] {
      let timeline = "<SegmentTimeline><S \(attribute) d=\"2\" r=\"1\"/></SegmentTimeline>"
      let template = "<SegmentTemplate initialization=\"i.mp4\" media=\"seg-$Number$.m4s\">" + timeline + "</SegmentTemplate>"
      reject(mpd(period(template)))
      for marker in ["<Period ", "<AdaptationSet ", "<Representation "] {
        reject(mpd(period()).replacingOccurrences(of: marker, with: template + marker))
      }
      let list = "<SegmentList>" + timeline + "<Initialization sourceURL=\"i.mp4\"/><SegmentURL media=\"one.m4s\"/><SegmentURL media=\"two.m4s\"/></SegmentList>"
      reject(mpd(period(list)))
    }
  }

}
