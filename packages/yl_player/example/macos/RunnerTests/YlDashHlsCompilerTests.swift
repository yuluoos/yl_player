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
  private func reject(_ xml: String, code: String = "container.unsupported", file: StaticString = #filePath, line: UInt = #line) {
    var emitted = 0
    XCTAssertThrowsError(try compile(xml, seen: { _, _ in emitted += 1 }), file: file, line: line) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, code, file: file, line: line)
      XCTAssertFalse(String(describing: error).contains("origin.test"), file: file, line: line)
    }
    XCTAssertEqual(emitted, 0, "Unsupported MPD must fail before media emission", file: file, line: line)
  }
  func testAdmissionReasonsSurviveSafePublicationWithoutSourceDetails() {
    let cases: [(String, String, String)] = [
      ("<MPD><private-secret>", "container.dash_manifest_invalid", "valid UTF-8 MPD"),
      ("<MPD type=\"dynamic\"/>", "container.dash_dynamic_unsupported", "static DASH"),
      (mpd("<ContentProtection value=\"private-secret\"/>"), "container.dash_protection_unsupported", "protected-content declaration"),
      (mpd("<SegmentBase indexRange=\"private-secret\"/>"), "container.dash_segment_base_unsupported", "SegmentTemplate or SegmentList"),
      (String(repeating: " ", count: 2 * 1024 * 1024 + 1), "resource.dash_manifest_too_large", "2 MiB")
    ]
    for (xml, code, guidance) in cases {
      var emitted = 0
      XCTAssertThrowsError(try compile(xml, seen: { _, _ in emitted += 1 })) { error in
        XCTAssertEqual((error as? NativePlayerError)?.code, code)
        let failure = YlAppleSafeDiagnostics.failure(error, scope: .command)
        XCTAssertEqual(failure.code, code)
        XCTAssertEqual(failure.category, code.hasPrefix("resource.") ? .resource : .container)
        XCTAssertFalse(failure.retryable)
        XCTAssertTrue(failure.message.contains(guidance), failure.message)
        XCTAssertFalse(failure.message.contains("private-secret"))
        XCTAssertFalse(failure.message.contains("origin.test"))
        XCTAssertTrue(failure.diagnosticId.hasPrefix("apple-"))
      }
      XCTAssertEqual(emitted, 0)
    }
    XCTAssertThrowsError(try YlDashHlsCompiler.compile(data: Data([0xff]), finalManifestURL: source,
      sourceURL: source, credentialsStripped: false,
      manifestURL: { _ in self.source }, mediaURL: { url, _ in url })) {
        XCTAssertEqual(($0 as? NativePlayerError)?.code, "container.dash_manifest_invalid")
    }
  }

  func testAdmissionClassificationDoesNotGuessFromUnsupportedOrCallbackErrors() {
    for xml in ["<MPD type=\"private-secret\"/>", "<other/>",
      "<MPD xmlns=\"urn:private-secret\"><ContentProtection/></MPD>",
      mpd("<ContentProtection xmlns=\"urn:private-secret\"/>"),
      mpd("<SegmentBase xmlns=\"urn:private-secret\"/>"),
      mpd("<Location>private-secret</Location>"),
      "<!DOCTYPE MPD>" + mpd(period())] {
      reject(xml)
    }
    for code in ["container.dash_manifest_invalid", "container.dash_dynamic_unsupported",
      "container.dash_protection_unsupported", "container.dash_segment_base_unsupported",
      "resource.dash_manifest_too_large"] {
      XCTAssertThrowsError(try YlDashHlsCompiler.compile(data: Data(mpd(period()).utf8), finalManifestURL: source,
        sourceURL: source, credentialsStripped: false,
        manifestURL: { _ in throw NativePlayerError(category: "container", code: code, message: "private-secret") },
        mediaURL: { url, _ in url })) {
          XCTAssertEqual(($0 as? NativePlayerError)?.code, "container.unsupported")
      }
    }
  }

  func testFixedProjectionMatchesSemanticIdentityAcrossReorderAndMissingPeriod() throws {
    let xml = mpd(ladder(rendition("low") + rendition("high", width: 640, bandwidth: 700000))
      + ladder(rendition("renamed-high", width: 640, bandwidth: 700000) + rendition("renamed-low"), start: 4)
      + ladder(rendition("only-low"), start: 8), duration: 12)
    let result = try YlDashHlsCompiler.compile(data: Data(xml.utf8), finalManifestURL: source,
      sourceURL: source, credentialsStripped: false, fixedTrackId: "dash-video-w640-h360-b700000",
      manifestURL: { URL(string: "https://virtual.test/\($0).m3u8")! }, mediaURL: { url, _ in url })
    let paths = result.manifests.filter { $0.key != result.rootURL }.values.map { String(decoding: $0, as: UTF8.self) }
    XCTAssertFalse(paths.isEmpty)
    for path in paths {
      XCTAssertTrue(path.contains("init-high.mp4"))
      XCTAssertTrue(path.contains("init-renamed-high.mp4"))
      XCTAssertFalse(path.contains("init-low.mp4"))
      XCTAssertFalse(path.contains("init-renamed-low.mp4"))
      XCTAssertTrue(path.contains("init-only-low.mp4"))
    }
    XCTAssertEqual(result.videoCatalog.tracks(at: 0).map(\.width), [320, 640])
    XCTAssertEqual(result.videoCatalog.tracks(at: 8_000_000).map(\.width), [320])
  }

  func testFixedProjectionRejectsAmbiguityIncompatibilityAndCapsAcrossWholeProgram() throws {
    let high = rendition("high", width: 640, bandwidth: 700000)
    let cases = [mpd(ladder(rendition("a") + rendition("b"))),
      mpd(ladder(rendition("a") + high.replacingOccurrences(of: "width=\"640\"", with: "width=\"641\""))),
      mpd(ladder(high) + ladder(rendition("low"), start: 4), duration: 8)]
    for (index, xml) in cases.enumerated() {
      var resources = 0
      XCTAssertThrowsError(try YlDashHlsCompiler.compile(data: Data(xml.utf8), finalManifestURL: source,
        sourceURL: source, credentialsStripped: false,
        videoConstraints: index == 2 ? .init(maxWidth: 320, maxHeight: nil, maxBitrate: nil) : .unconstrained,
        fixedTrackId: index == 0 ? "dash-video-w320-h180-b350000" : "dash-video-w640-h360-b700000",
        manifestURL: { URL(string: "https://virtual.test/\($0).m3u8")! }, mediaURL: { url, _ in resources += 1; return url }))
      XCTAssertEqual(resources, 0)
    }
  }

  func testCatalogStableNumericIdentitySortingAndVideoOnlyBitrate() throws {
    let low = "dash-video-w320-h180-b350000", high = "dash-video-w640-h360-b700000"
    let xml = mpd(ladder(rendition("secret-high", width: 640, bandwidth: 700000) + rendition("private-low"), audio: true)
      + ladder(rendition("reordered-low") + rendition("renamed-high", width: 640, bandwidth: 700000), start: 4, audio: true), duration: 8)
    let catalog = try compile(xml).videoCatalog
    for time: Int64 in [-1, 0, 3_999_999, 4_000_000, 8_000_000, Int64.max] {
      let tracks = catalog.tracks(at: time)
      XCTAssertEqual(tracks.map(\.id), [low, high])
      XCTAssertEqual(tracks.map(\.bitrate), [350000, 700000])
      XCTAssertEqual(tracks.map(\.width), [320, 640])
      XCTAssertEqual(tracks.map(\.height), [180, 360])
      XCTAssertEqual(tracks.map(\.codec), ["avc1.42c01e", "avc1.42c01e"])
      XCTAssertTrue(tracks.allSatisfy { !$0.isSelected && $0.label == nil && $0.language == nil })
    }
  }

  func testCatalogTracksDisappearAndReappearAtExactPeriodBoundaries() throws {
    let high = rendition("first", width: 640, bandwidth: 700000)
    let catalog = try compile(mpd(ladder(high) + ladder(rendition("low"), start: 4)
      + ladder(rendition("again", width: 640, bandwidth: 700000), start: 8), duration: 12)).videoCatalog
    for time: Int64 in [Int64.min, 0, 3_999_999, 8_000_000, 12_000_000, Int64.max] {
      XCTAssertEqual(catalog.tracks(at: time).map(\.id), ["dash-video-w640-h360-b700000"])
    }
    for time: Int64 in [4_000_000, 7_999_999] {
      XCTAssertEqual(catalog.tracks(at: time).map(\.id), ["dash-video-w320-h180-b350000"])
    }
  }

  func testCatalogPreservesSubMillisecondBoundsThroughCapProjection() throws {
    let segment = "<SegmentTemplate timescale=\"1000000\" duration=\"4000500\" initialization=\"init.mp4\" media=\"$Number$.m4s\"/>"
    let one = ladder(rendition("first", bandwidth: 350000, template: segment))
      .replacingOccurrences(of: "duration=\"PT4S\"", with: "duration=\"PT4.000500S\"")
    let two = ladder(rendition("second", bandwidth: 340000, template: segment), start: 4)
      .replacingOccurrences(of: "start=\"PT4S\"", with: "start=\"PT4.000500S\"")
      .replacingOccurrences(of: "duration=\"PT4S\"", with: "duration=\"PT4.000500S\"")
    let xml = "<MPD type=\"static\" mediaPresentationDuration=\"PT8.001S\">" + one + two + "</MPD>"
    for caps in [YlAppleVideoConstraints.unconstrained, .init(maxWidth: 320, maxHeight: 180, maxBitrate: 350000)] {
      let catalog = try YlDashHlsCompiler.compile(data: Data(xml.utf8), finalManifestURL: source,
        sourceURL: source, credentialsStripped: false, videoConstraints: caps,
        manifestURL: { URL(string: "https://virtual.test/\($0).m3u8")! }, mediaURL: { url, _ in url }).videoCatalog
      XCTAssertEqual(catalog.tracks(at: 4_000_499).first?.bitrate, 350000)
      XCTAssertEqual(catalog.tracks(at: 4_000_500).first?.bitrate, 340000)
    }
  }

  func testCatalogDeduplicatesLegacyQualityWithoutChangingCompiledPaths() throws {
    let first = rendition("a"), second = rendition("b", extra: "audioSamplingRate=\"1\"")
    let result = try compile(mpd(ladder(first + second)))
    XCTAssertEqual(result.videoCatalog.tracks(at: 0).map(\.id), ["dash-video-w320-h180-b350000"])
    XCTAssertEqual(result.manifests.count, 3, "Display deduplication must preserve both admitted media paths")
  }

  func testCatalogPreservesLegacyVaryingBitratesAcross64Periods() throws {
    let xml = mpd((0..<64).map { ladder(rendition("v\($0)", bandwidth: 350000 + $0), start: $0 * 4) }.joined(), duration: 256)
    let catalog = try compile(xml).videoCatalog
    for index in 0..<64 {
      XCTAssertEqual(catalog.tracks(at: Int64(index) * 4_000_000).first?.bitrate, 350000 + index)
    }
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
    reject(valid.replacingOccurrences(of: "static", with: "dynamic"), code: "container.dash_dynamic_unsupported")
    reject(valid.replacingOccurrences(of: "<Representation", with: "<ContentProtection/><Representation"), code: "container.dash_protection_unsupported")
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
      reject(mpd(p).replacingOccurrences(of: "</MPD>", with: "<\(node)/></MPD>"), code: node == "SegmentBase" ? "container.dash_segment_base_unsupported" : "container.unsupported")
    }
  }
  func testRejectsUnsafeURLsDTDDepthAndLargePayload() {
    reject("<!DOCTYPE MPD [<!ENTITY x SYSTEM 'https://origin.test/secret'>]>" + mpd(period()))
    reject(mpd(period(base: "<BaseURL>https://user:pass@origin.test/</BaseURL>")))
    reject(mpd(period(base: "<BaseURL>file:///tmp/</BaseURL>")))
    reject(mpd(String(repeating: "<meta>", count: 65) + String(repeating: "</meta>", count: 65) + period()))
    reject(String(repeating: " ", count: 2 * 1024 * 1024 + 1), code: "resource.dash_manifest_too_large")
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
  func testVariantsRejectAmbiguousAndIncompatibleLaddersBeforeEmission() {
    let low = rendition("a"), high = rendition("b", width: 640, bandwidth: 700000)
    reject(mpd(ladder(low + rendition("duplicate"))))
    reject(mpd(ladder(low + high.replacingOccurrences(of: "<Representation ", with: "<Representation codecs=\"avc1.64001e\" "))))
    reject(mpd(ladder(low + high.replacingOccurrences(of: "<SegmentTemplate", with: "<Role value=\"alternate\"/><SegmentTemplate"))))
    reject(mpd(ladder(low + high.replacingOccurrences(of: "<SegmentTemplate", with: "<SupplementalProperty schemeIdUri=\"urn:mpeg:mpegB:cicp:TransferCharacteristics\" value=\"16\"/><SegmentTemplate"))))
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


  private func changingPaths(_ result: YlDashHlsPresentation) throws -> [String] {
    let master = String(data: result.manifests[result.rootURL]!, encoding: .utf8)!
    return try master.split(separator: "\n").filter { $0.hasPrefix("ylhls:") }.map {
      let url = try YlHlsURLCodec.decode(URL(string: String($0))!)
      return String(data: try XCTUnwrap(result.manifests[url]), encoding: .utf8)!
    }
  }
  private func assertPath(_ text: String, _ ids: [String], file: StaticString = #filePath, line: UInt = #line) {
    let periods = text.components(separatedBy: "#EXT-X-DISCONTINUITY\n")
    XCTAssertEqual(periods.count, ids.count, file: file, line: line)
    for (period, id) in zip(periods, ids) {
      XCTAssertTrue(period.contains("#EXT-X-MAP:URI=\"https://origin.test/dash/init-\(id).mp4\""), file: file, line: line)
      for number in 1...2 { XCTAssertTrue(period.contains("/\(id)-\(number).m4s\n"), file: file, line: line) }
      XCTAssertEqual(period.components(separatedBy: "#EXTINF:2.000000,\n").count - 1, 2, file: file, line: line)
    }
  }
  func testChangingLaddersRemoveAndAddQualityByIdentityWithRenamedReorderedIDs() throws {
    let low = rendition("old-low"), high = rendition("old-high", width: 640, bandwidth: 700000)
    let removed = try compile(mpd(ladder(high + low) + ladder(rendition("new-low"), start: 4), duration: 8))
    let removedPaths = try changingPaths(removed)
    XCTAssertEqual(removedPaths.count, 2)
    if removedPaths.count == 2 {
      assertPath(removedPaths[0], ["old-low", "new-low"])
      assertPath(removedPaths[1], ["old-high", "new-low"])
    }
    let added = try changingPaths(compile(mpd(ladder(low) + ladder(rendition("new-high", width: 640, bandwidth: 700000) + rendition("new-low"), start: 4), duration: 8)))
    XCTAssertEqual(added.count, 2)
    if added.count == 2 {
      assertPath(added[0], ["old-low", "new-low"])
      assertPath(added[1], ["old-low", "new-high"])
    }
    // Bandwidth participates in identity even when the dimensions are equal.
    let changed = try changingPaths(compile(mpd(ladder(low + high) + ladder(rendition("new-low") + rendition("new-high", width: 640, bandwidth: 800000), start: 4), duration: 8)))
    XCTAssertEqual(changed.count, 3)
    if changed.count == 3 {
      assertPath(changed[0], ["old-low", "new-low"])
      assertPath(changed[1], ["old-high", "new-low"])
      assertPath(changed[2], ["old-high", "new-high"])
    }
  }
  func testChangingSingletonsDeduplicateBothDirectionsAndKeepVideoIdentity() throws {
    for widths in [[640, 320], [320, 640]] {
      let xml = mpd(ladder(rendition("first", width: widths[0])) + ladder(rendition("second", width: widths[1]), start: 4), duration: 8)
      let result = try compile(xml)
      XCTAssertEqual(result.manifests.count, 2)
      let playlist = try XCTUnwrap(result.manifests[URL(string: "https://virtual.test/video.m3u8")!])
      assertPath(String(data: playlist, encoding: .utf8)!, ["first", "second"])
    }
  }
  func testChangingPathsUseFloorThenMinimumAndMasterEnvelopes() throws {
    let first = ladder(rendition("low", bandwidth: 900000) + rendition("high", width: 1280, bandwidth: 700000), audio: true)
    let second = ladder(rendition("middle", width: 640, bandwidth: 400000), start: 4, audio: true).replacingOccurrences(of: "64000", with: "128000")
    let result = try compile(mpd(first + second, duration: 8))
    let paths = try changingPaths(result)
    XCTAssertEqual(paths.count, 2) // low and middle anchors map to the same complete sequence.
    if paths.count == 2 {
      assertPath(paths[0], ["low", "middle"])
      assertPath(paths[1], ["high", "middle"])
    }
    let master = String(data: result.manifests[result.rootURL]!, encoding: .utf8)!
    XCTAssertTrue(master.contains("BANDWIDTH=964000,CODECS=\"avc1.42c01e,mp4a.40.2\",RESOLUTION=640x360"))
    XCTAssertTrue(master.contains("BANDWIDTH=764000,CODECS=\"avc1.42c01e,mp4a.40.2\",RESOLUTION=1280x720"))
    XCTAssertEqual(result.manifests.count, 4)
    XCTAssertFalse(master.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
  }
  func testChangingLaddersAcceptEquivalentDeclaredFrameRatesAndSquareSAR() throws {
    let one = ladder(rendition("a", extra: "frameRate=\"24\" sar=\"1:1\""))
    for rate in ["24/1", "48/2"] {
      let two = ladder(rendition("b", width: 640, extra: "frameRate=\"\(rate)\""), start: 4)
      assertPath(video(try compile(mpd(one + two, duration: 8))), ["a", "b"])
    }
  }
  func testChangingSingletonCannotBypassConservativeFamilyValidation() {
    let first = ladder(rendition("a") + rendition("b", width: 640, bandwidth: 700000))
    let singleton = ladder(rendition("c"), start: 4)
    for attribute in ["videoRange=\"PQ\"", "colourPrimaries=\"9\"", "transferCharacteristics=\"16\"", "matrixCoefficients=\"9\"", "sar=\"2:1\"", "sar=\"0:0\"", "codecs=\"avc1.64001e\"", "frameRate=\"25\""] {
      reject(mpd(first + singleton.replacingOccurrences(of: "<Representation ", with: "<Representation \(attribute) "), duration: 8))
    }
    reject(mpd(first + singleton.replacingOccurrences(of: "<SegmentTemplate", with: "<Role value=\"alternate\"/><SegmentTemplate"), duration: 8))
    reject(mpd(first + singleton.replacingOccurrences(of: "<SegmentTemplate", with: "<SupplementalProperty schemeIdUri=\"range\" value=\"SDR\"/><SegmentTemplate"), duration: 8))
    reject(mpd(first + singleton.replacingOccurrences(of: "height=\"180\"", with: "height=\"181\""), duration: 8))
    let changing = mpd(ladder(rendition("a")) + ladder(rendition("b", width: 640), start: 4), duration: 8)
    for codec in ["avc1.6e001e", "avc1.7a001e", "avc1.f4001e"] {
      reject(changing.replacingOccurrences(of: "avc1.42c01e", with: codec))
    }
    for node in ["<MPD ", "<Period ", "<AdaptationSet "] {
      reject(changing.replacingOccurrences(of: node, with: node + "videoRange=\"SDR\" "))
    }
  }
  func testChangingLaddersRejectUnequalMissingAndMalformedFrameRates() {
    let one = ladder(rendition("a", extra: "frameRate=\"24\""))
    for attribute in ["", "frameRate=\"25\"", "frameRate=\"24/0\"", "frameRate=\"0\"", "frameRate=\"24/1/1\"", "frameRate=\"1.5\""] {
      reject(mpd(one + ladder(rendition("b", width: 640, extra: attribute), start: 4), duration: 8))
    }
    let missing = ladder(rendition("a"))
    reject(mpd(missing + ladder(rendition("b", width: 640, extra: "frameRate=\"24\""), start: 4), duration: 8))
  }
  func testChangingLaddersBoundGlobalUnionBeforeEitherURLClosure() throws {
    func document(_ count: Int) -> String {
      mpd((1...count).map { ladder(rendition("v\($0)", width: $0 * 32), start: ($0 - 1) * 4) }.joined(), duration: count * 4)
    }
    XCTAssertEqual(try compile(document(16)).manifests.count, 2)
    var manifestCalls = 0, mediaCalls = 0
    XCTAssertThrowsError(try YlDashHlsCompiler.compile(data: Data(document(17).utf8), finalManifestURL: source, sourceURL: source, credentialsStripped: false,
      manifestURL: { name in manifestCalls += 1; return URL(string: "https://virtual.test/\(name).m3u8")! },
      mediaURL: { url, _ in mediaCalls += 1; return url }))
    XCTAssertEqual(manifestCalls, 0); XCTAssertEqual(mediaCalls, 0)
  }
  func testLegacySingletonBandwidthChangesRemainAcceptedFor64Periods() throws {
    let periods = (0..<64).map { ladder(rendition("v\($0)", bandwidth: 350000 + $0), start: $0 * 4) }.joined()
    let result = try compile(mpd(periods, duration: 256))
    XCTAssertEqual(result.manifests.count, 2)
    XCTAssertEqual(video(result).components(separatedBy: "#EXT-X-DISCONTINUITY\n").count - 1, 63)
  }
  func testChangingLaddersPreserveStrictestSharedCredentialHistory() throws {
    let low = rendition("a")
    let later = ladder(rendition("b", width: 640), start: 4).replacingOccurrences(of: "<AdaptationSet", with: "<BaseURL>https://foreign.test/</BaseURL><AdaptationSet").replacingOccurrences(of: "<SegmentTemplate", with: "<BaseURL>https://origin.test/dash/</BaseURL><SegmentTemplate").replacingOccurrences(of: "init-$RepresentationID$.mp4", with: "init-a.mp4")
    var shared: [Bool] = []
    _ = try compile(mpd(ladder(low) + later, duration: 8), seen: { url, stripped in if url.lastPathComponent == "init-a.mp4" { shared.append(stripped) } })
    XCTAssertEqual(shared, [true, true])
  }
  func testChangingLaddersShareInputAndExpandedPlaylistBudgets() {
    let dense = "<SegmentTemplate timescale=\"15000\" duration=\"1\" initialization=\"i\" media=\"$Number$\"/>"
    reject(mpd(ladder(rendition("a", template: dense)) + ladder(rendition("b", width: 640, template: dense), start: 4), duration: 8))
    let long = "<SegmentTemplate timescale=\"75\" duration=\"1\" initialization=\"i\" media=\"" + String(repeating: "x", count: 8000) + "$Number$\"/>"
    reject(mpd(ladder(rendition("a", template: long)) + ladder(rendition("b", width: 640, template: long), start: 4), duration: 8))
    let template = "<SegmentTemplate timescale=\"25\" duration=\"1\" initialization=\"i\" media=\"$Number$\"/>"
    let one = ladder(rendition("a", template: template) + rendition("b", width: 640, template: template) + rendition("c", width: 960, template: template))
    let two = ladder(rendition("d", template: template), start: 4)
    XCTAssertNoThrow(try compile(mpd(one + two, duration: 8)))
    var emitted = 0
    XCTAssertThrowsError(try YlDashHlsCompiler.compile(data: Data(mpd(one + two, duration: 8).utf8), finalManifestURL: source, sourceURL: source, credentialsStripped: false,
      manifestURL: { URL(string: "https://virtual.test/\($0).m3u8")! },
      mediaURL: { _, _ in emitted += 1; return URL(string: "https://proxy.test/" + String(repeating: "x", count: 8000))! }))
    XCTAssertGreaterThan(emitted, 400, "The cumulative registry budget must reject after two individually valid playlists")
  }


  func testChangingLaddersRejectDuplicateQualityWithIrrelevantAudioDeclarationsBeforeURLClosures() throws {
    let first = rendition("alpha")
    let alternatives = [
      rendition("beta", extra: "audioSamplingRate=\"1\""),
      rendition("beta").replacingOccurrences(of: "<SegmentTemplate", with: "<AudioChannelConfiguration schemeIdUri=\"urn:mpeg:dash:23003:3:audio_channel_configuration:2011\" value=\"2\"/><SegmentTemplate"),
    ]
    for second in alternatives {
      for duplicates in [first + second, second + first] {
        // The legacy homogeneous route retains its pre-existing admission domain.
        XCTAssertNoThrow(try compile(mpd(ladder(duplicates))))
        for duplicatePeriod in [0, 1] {
          let one = ladder(duplicatePeriod == 0 ? duplicates : rendition("high", width: 640))
          let two = ladder(duplicatePeriod == 1 ? duplicates : rendition("high", width: 640), start: 4)
          var manifestCalls = 0, mediaCalls = 0
          XCTAssertThrowsError(try YlDashHlsCompiler.compile(data: Data(mpd(one + two, duration: 8).utf8), finalManifestURL: source, sourceURL: source, credentialsStripped: false,
            manifestURL: { name in manifestCalls += 1; return URL(string: "https://virtual.test/\(name).m3u8")! },
            mediaURL: { url, _ in mediaCalls += 1; return url })) { error in
              XCTAssertEqual((error as? NativePlayerError)?.code, "container.unsupported")
            }
          XCTAssertEqual(manifestCalls, 0)
          XCTAssertEqual(mediaCalls, 0)
        }
      }
    }
  }

  func testLoadCapsIntersectAtInclusiveVideoBandwidthBoundaryAcrossAllPeriods() throws {
    let xml = mpd(ladder(rendition("low") + rendition("high", width: 640, bandwidth: 700000), audio: true)
      + ladder(rendition("new-high", width: 640, bandwidth: 700000) + rendition("new-low"), start: 4, audio: true), duration: 8)
    for cap in [YlAppleVideoConstraints(maxWidth: 320, maxHeight: 180, maxBitrate: 350000),
                .init(maxWidth: 320, maxHeight: nil, maxBitrate: nil),
                .init(maxWidth: nil, maxHeight: 180, maxBitrate: nil),
                .init(maxWidth: nil, maxHeight: nil, maxBitrate: 350000)] {
      let result = try YlDashHlsCompiler.compile(data: Data(xml.utf8), finalManifestURL: source,
        sourceURL: source, credentialsStripped: false, videoConstraints: cap,
        manifestURL: { URL(string: "https://virtual.test/\($0).m3u8")! }, mediaURL: { url, _ in url })
      for time: Int64 in [0, 3_999_999, 4_000_000, 8_000_000] {
        XCTAssertEqual(result.videoCatalog.tracks(at: time).map(\.id), ["dash-video-w320-h180-b350000"])
      }
      let paths = try changingPaths(result)
      XCTAssertEqual(paths.count, 1)
      for path in paths { assertPath(path, ["low", "new-low"]); XCTAssertFalse(path.contains("high")) }
      let master = String(decoding: result.manifests[result.rootURL]!, as: UTF8.self)
      XCTAssertTrue(master.contains("BANDWIDTH=414000"))
      XCTAssertEqual(result.manifests.count, 3)
    }
  }
  func testLoadCapsRejectEmptyPeriodAndOriginalUnsupportedFamilyBeforeAnyEmission() {
    let low = rendition("low"), high = rendition("high", width: 640, bandwidth: 700000)
    let cases: [(String, String)] = [
      (mpd(ladder(low) + ladder(high, start: 4), duration: 8), "decoder.quality_constraint_unsupported"),
      (mpd(ladder(high) + ladder(low, start: 4), duration: 8), "decoder.quality_constraint_unsupported"),
      (mpd(ladder(low + high.replacingOccurrences(of: "<Representation ", with: "<Representation sar=\"2:1\" "))), "container.unsupported"),
      (mpd(ladder(low)).replacingOccurrences(of: "avc1.42c01e", with: "avc1.6e001e"), "container.unsupported")]
    for (xml, code) in cases {
      var manifests = 0, media = 0
      XCTAssertThrowsError(try YlDashHlsCompiler.compile(data: Data(xml.utf8), finalManifestURL: source,
        sourceURL: source, credentialsStripped: false,
        videoConstraints: .init(maxWidth: 320, maxHeight: 180, maxBitrate: 350000),
        manifestURL: { name in manifests += 1; return URL(string: "https://virtual.test/\(name).m3u8")! },
        mediaURL: { url, _ in media += 1; return url })) { error in
          XCTAssertEqual((error as? NativePlayerError)?.code, code)
        }
      XCTAssertEqual(manifests, 0); XCTAssertEqual(media, 0)
    }
  }

  func testLoadCapsRetainCredentialHistoryAndSanitizeInjectedSemanticErrors() throws {
    let high = rendition("high", width: 640, bandwidth: 700000)
      .replacingOccurrences(of: "<SegmentTemplate", with: "<BaseURL>https://foreign.test/</BaseURL><SegmentTemplate")
      .replacingOccurrences(of: "init-$RepresentationID$.mp4", with: "https://origin.test/dash/init-low.mp4")
    let xml = mpd(ladder(rendition("low") + high))
    var stripped: [Bool] = []
    _ = try YlDashHlsCompiler.compile(data: Data(xml.utf8), finalManifestURL: source, sourceURL: source,
      credentialsStripped: false, videoConstraints: .init(maxWidth: 320, maxHeight: nil, maxBitrate: nil),
      manifestURL: { URL(string: "https://virtual.test/\($0).m3u8")! },
      mediaURL: { url, value in if url.lastPathComponent == "init-low.mp4" { stripped.append(value) }; return url })
    XCTAssertEqual(stripped, [true], "Filtering must not erase stricter provenance from the original high track")
    XCTAssertThrowsError(try YlDashHlsCompiler.compile(data: Data(xml.utf8), finalManifestURL: source, sourceURL: source,
      credentialsStripped: false, videoConstraints: .init(maxWidth: 320, maxHeight: nil, maxBitrate: nil),
      manifestURL: { _ in throw NativePlayerError(category: "decoder", code: "decoder.quality_constraint_unsupported", message: "https://private.test?token=secret") },
      mediaURL: { url, _ in url })) { error in
        XCTAssertEqual((error as? NativePlayerError)?.code, "container.unsupported")
        XCTAssertFalse((error as? NativePlayerError)?.message.contains("private") ?? true)
      }
  }
  func testLoadCapsConstrainedLegacyCannotBypassUnionOrOriginalInputBudgets() {
    let union = (0..<17).map { ladder(rendition("v\($0)", bandwidth: 350000 + $0), start: $0 * 4) }.joined()
    let dense = "<SegmentTemplate timescale=\"15000\" duration=\"1\" initialization=\"i\" media=\"$Number$\"/>"
    for xml in [mpd(union, duration: 68), mpd(ladder(rendition("low", template: dense) + rendition("high", width: 640, bandwidth: 700000, template: dense)))] {
      var calls = 0
      XCTAssertThrowsError(try YlDashHlsCompiler.compile(data: Data(xml.utf8), finalManifestURL: source, sourceURL: source,
        credentialsStripped: false, videoConstraints: .init(maxWidth: nil, maxHeight: nil, maxBitrate: 350000),
        manifestURL: { name in calls += 1; return URL(string: "https://virtual.test/\(name).m3u8")! },
        mediaURL: { url, _ in calls += 1; return url }))
      XCTAssertEqual(calls, 0)
    }
  }

}
