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

  private func rendition(_ id: String, width: Int = 320, bandwidth: Int = 350000,
    template: String? = nil, extra: String = "") -> String {
    "<Representation id=\"\(id)\" bandwidth=\"\(bandwidth)\" width=\"\(width)\" height=\"\(width * 9 / 16)\" \(extra)>\(template ?? "<SegmentTemplate timescale=\"1\" duration=\"2\" initialization=\"init-$RepresentationID$.mp4\" media=\"$RepresentationID$-$Number$.m4s\"/>")</Representation>"
  }
  private func ladder(_ representations: String, start: Int = 0, audio: Bool = false) -> String {
    let sound = audio ? "<AdaptationSet contentType=\"audio\" codecs=\"mp4a.40.2\" audioSamplingRate=\"48000\"><Representation id=\"a\" bandwidth=\"64000\"><SegmentTemplate duration=\"2\" initialization=\"a-init.mp4\" media=\"a-$Number$.m4s\"/></Representation></AdaptationSet>" : ""
    return "<Period start=\"PT\(start)S\" duration=\"PT4S\"><AdaptationSet contentType=\"video\" codecs=\"avc1.42c01e\">\(representations)</AdaptationSet>\(sound)</Period>"
  }
  func testVariantsMatchReorderedChangedIDsAcrossPeriodsAndShareAudio() throws {
    let one = ladder(rendition("low") + rendition("high", width: 640, bandwidth: 700000), audio: true)
    let two = ladder(rendition("new-high", width: 640, bandwidth: 700000) + rendition("new-low"), start: 4, audio: true)
    let result = try compile(mpd(one + two, duration: 8))
    XCTAssertEqual(result.durationUs, 8_000_000)
    XCTAssertEqual(result.manifests.count, 4)
    let master = String(data: result.manifests[result.rootURL]!, encoding: .utf8)!
    XCTAssertTrue(master.contains("BANDWIDTH=414000,CODECS=\"avc1.42c01e,mp4a.40.2\",RESOLUTION=320x180,AUDIO=\"audio\""))
    XCTAssertTrue(master.contains("BANDWIDTH=764000,CODECS=\"avc1.42c01e,mp4a.40.2\",RESOLUTION=640x360,AUDIO=\"audio\""))
    XCTAssertEqual(master.components(separatedBy: "#EXT-X-MEDIA:").count - 1, 1)
    let urls = try master.split(separator: "\n").filter { $0.hasPrefix("ylhls:") }.map { try YlHlsURLCodec.decode(URL(string: String($0))!) }
    XCTAssertEqual(urls.count, 2)
    let playlists = urls.map { String(data: result.manifests[$0]!, encoding: .utf8)! }
    for (index, name) in ["low", "high"].enumerated() {
      XCTAssertTrue(playlists[index].contains("/init-\(name).mp4"))
      XCTAssertTrue(playlists[index].contains("/init-new-\(name).mp4"))
      XCTAssertEqual(playlists[index].components(separatedBy: "#EXTINF:2.000000,").count - 1, 4)
      XCTAssertEqual(playlists[index].components(separatedBy: "#EXT-X-DISCONTINUITY\n").count - 1, 1)
      XCTAssertFalse(playlists[index].contains("#EXT-X-INDEPENDENT-SEGMENTS"))
    }
  }
  func testVariantsAcceptExactEquivalentTimescalesAndNoAudio() throws {
    let scaled = "<SegmentTemplate timescale=\"90000\" duration=\"180000\" initialization=\"i.mp4\" media=\"$Number$.m4s\"/>"
    let result = try compile(mpd(ladder(rendition("a") + rendition("b", width: 640, bandwidth: 700000, template: scaled))))
    XCTAssertEqual(result.manifests.count, 3)
    let master = String(data: result.manifests[result.rootURL]!, encoding: .utf8)!
    XCTAssertFalse(master.contains("AUDIO="))
    XCTAssertTrue(master.contains("BANDWIDTH=700000,CODECS=\"avc1.42c01e\",RESOLUTION=640x360"))
  }
  func testVariantsRejectAmbiguousChangedAndIncompatibleLaddersBeforeEmission() {
    let low = rendition("a"), high = rendition("b", width: 640, bandwidth: 700000)
    reject(mpd(ladder(low + rendition("duplicate"))))
    reject(mpd(ladder(low + high.replacingOccurrences(of: "<Representation ", with: "<Representation codecs=\"avc1.64001e\" "))))
    reject(mpd(ladder(low + high.replacingOccurrences(of: "<SegmentTemplate", with: "<Role value=\"alternate\"/><SegmentTemplate"))))
    reject(mpd(ladder(low + high.replacingOccurrences(of: "<SegmentTemplate", with: "<SupplementalProperty schemeIdUri=\"urn:mpeg:mpegB:cicp:TransferCharacteristics\" value=\"16\"/><SegmentTemplate"))))
    for second in [low, low + high.replacingOccurrences(of: "700000", with: "800000"), low + high + rendition("c", width: 1280, bandwidth: 1400000)] {
      reject(mpd(ladder(low + high) + ladder(second, start: 4), duration: 8))
    }
    reject(mpd(ladder(low + high, audio: true) + ladder(low + high, start: 4), duration: 8))
  }
  func testVariantsRejectSubMicrosecondMisalignmentWithoutDoubleRounding() {
    // Both first durations round to 2.000000; equality must use exact fractions.
    let timeline = "<SegmentTemplate timescale=\"10000000\" initialization=\"i.mp4\" media=\"$Time$.m4s\"><SegmentTimeline><S d=\"20000001\"/><S d=\"19999999\"/></SegmentTimeline></SegmentTemplate>"
    reject(mpd(ladder(rendition("a") + rendition("b", width: 640, bandwidth: 700000, template: timeline))))
    reject(mpd(ladder(rendition("a") + rendition("b", width: 640, bandwidth: 700000).replacingOccurrences(of: "duration=\"2\"", with: "duration=\"1\""))))
  }
  func testVariantsShareGeneratedRegistryBudget() {
    let template = "<SegmentTemplate timescale=\"50\" duration=\"1\" initialization=\"i\" media=\"$Number$\"/>"
    let variants = (1...3).map { rendition("v\($0)", width: $0 * 320, bandwidth: $0 * 350000, template: template) }.joined()
    XCTAssertThrowsError(try YlDashHlsCompiler.compile(data: Data(mpd(ladder(variants)).utf8), finalManifestURL: source, sourceURL: source, credentialsStripped: false,
      manifestURL: { URL(string: "https://virtual.test/\($0).m3u8")! },
      mediaURL: { _, _ in URL(string: "https://proxy.test/" + String(repeating: "x", count: 8000))! })) { error in
        XCTAssertEqual((error as? NativePlayerError)?.code, "container.unsupported")
      }
  }
  func testVariantsShareStrictestCredentialHistoryAcrossAllRenditions() throws {
    let low = rendition("a")
    let high = rendition("b", width: 640, bandwidth: 700000).replacingOccurrences(of: "<SegmentTemplate", with: "<BaseURL>https://foreign.test/</BaseURL><SegmentTemplate").replacingOccurrences(of: "init-$RepresentationID$.mp4", with: source.deletingLastPathComponent().appendingPathComponent("init-a.mp4").absoluteString)
    var shared: [Bool] = []
    _ = try compile(mpd(ladder(low + high)), seen: { u, stripped in if u.lastPathComponent == "init-a.mp4" { shared.append(stripped) } })
    XCTAssertEqual(shared, [true, true])
  }
  func testVariantsChargeAggregateSegmentURIBudgetsAndRepresentationLimit() throws {
    let dense = "<SegmentTemplate timescale=\"15000\" duration=\"1\" initialization=\"i\" media=\"$Number$\"/>"
    reject(mpd(ladder(rendition("a", template: dense) + rendition("b", width: 640, bandwidth: 700000, template: dense))))
    let long = "<SegmentTemplate timescale=\"75\" duration=\"1\" initialization=\"i\" media=\"" + String(repeating: "x", count: 8000) + "$Number$\"/>"
    reject(mpd(ladder(rendition("a", template: long) + rendition("b", width: 640, bandwidth: 700000, template: long))))
    let tooMany = (1...17).map { rendition("v\($0)", width: $0 * 32, bandwidth: $0 * 10000) }.joined()
    reject(mpd(ladder(tooMany)))
    let maximum = (1...16).map { rendition("v\($0)", width: $0 * 32, bandwidth: $0 * 10000) }.joined()
    let atLimit = (0..<16).map { ladder(maximum, start: $0 * 4) }.joined()
    XCTAssertEqual(try compile(mpd(atLimit, duration: 64)).manifests.count, 17)
    reject(mpd(atLimit + ladder(maximum, start: 64), duration: 68))
  }

}
