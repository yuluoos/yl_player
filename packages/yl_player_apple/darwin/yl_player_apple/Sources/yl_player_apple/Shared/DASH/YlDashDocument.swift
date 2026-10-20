import yl_player_media_core
import Foundation
import CryptoKit

/// Deliberately bounded, network-free XML tree. No XML text reaches diagnostics.
final class YlDashNode {
  let name: String
  let attributes: [String: String]
  var children: [YlDashNode] = []
  var text = ""
  init(_ name: String, _ attributes: [String: String]) {
    self.name = name; self.attributes = attributes
  }
  func nodes(_ name: String) -> [YlDashNode] { children.filter { $0.name == name } }
  func one(_ name: String) throws -> YlDashNode? {
    let matches = nodes(name)
    guard matches.count <= 1 else { throw YlDashBounds.unsupported }
    return matches.first
  }
}

// Only parser-owned reasons may cross the compiler's sanitizing boundary.
// No XML, URL or underlying parser prose is retained in this value.
enum YlDashAdmissionError: Error {
  case invalidManifest, dynamicManifest, protectedManifest, segmentBase, manifestTooLarge
  var nativeError: NativePlayerError {
    switch self {
    case .invalidManifest:
      return NativePlayerError(category: "container", code: "container.dash_manifest_invalid",
        message: "The DASH manifest could not be parsed. Ask the provider for a valid UTF-8 MPD.")
    case .dynamicManifest:
      return NativePlayerError(category: "container", code: "container.dash_dynamic_unsupported",
        message: "Dynamic DASH manifests are not supported by this playback path. Choose a static DASH VOD source.")
    case .protectedManifest:
      return NativePlayerError(category: "container", code: "container.dash_protection_unsupported",
        message: "The DASH manifest contains a protected-content declaration unsupported by this playback path. Choose a compatible source.")
    case .segmentBase:
      return NativePlayerError(category: "container", code: "container.dash_segment_base_unsupported",
        message: "DASH SegmentBase addressing is not supported by this playback path. Choose a compatible SegmentTemplate or SegmentList source.")
    case .manifestTooLarge:
      return NativePlayerError(category: "resource", code: "resource.dash_manifest_too_large",
        message: "The DASH manifest exceeds the 2 MiB input limit. Ask the provider for a smaller manifest.")
    }
  }
}

enum YlDashBounds {
  static let maxDocument = 2 * 1024 * 1024
  static let maxSegments = 100_000
  static let maxAudioTracks = 16
  static let maxVideoVariants = 16
  static let maxRepresentations = 256
  static let maxURI = 8192
  static let maxTotalURI = 4 * 1024 * 1024
  static var unsupported: NativePlayerError {
    NativePlayerError(category: "container", code: "container.unsupported",
      message: "The DASH presentation is unsupported.")
  }
  /// RFC 5646 well-formedness only; no registry lookup or canonicalization.
  static func audioLanguage(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128, value.utf8.allSatisfy({ $0 < 128 }) else { return false }
    let lower = value.lowercased()
    let grandfathered: Set<String> = ["en-gb-oed", "i-ami", "i-bnn", "i-default", "i-enochian", "i-hak", "i-klingon", "i-lux", "i-mingo", "i-navajo", "i-pwn", "i-tao", "i-tay", "i-tsu", "sgn-be-fr", "sgn-be-nl", "sgn-ch-de", "art-lojban", "cel-gaulish", "no-bok", "no-nyn", "zh-guoyu", "zh-hakka", "zh-min", "zh-min-nan", "zh-xiang"]
    if grandfathered.contains(lower) { return true }
    let parts = lower.components(separatedBy: "-")
    func alpha(_ p: String) -> Bool { !p.isEmpty && p.utf8.allSatisfy { (97...122).contains($0) } }
    func digit(_ p: String) -> Bool { !p.isEmpty && p.utf8.allSatisfy { (48...57).contains($0) } }
    guard parts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8 && $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) } }) else { return false }
    if parts[0] == "x" { return parts.count > 1 }
    guard parts[0].count >= 2, alpha(parts[0]) else { return false }
    var at = 1
    if parts[0].count <= 3 {
      var count = 0
      while at < parts.count && count < 3 && parts[at].count == 3 && alpha(parts[at]) { at += 1; count += 1 }
    }
    if at < parts.count && parts[at].count == 4 && alpha(parts[at]) { at += 1 }
    if at < parts.count && ((parts[at].count == 2 && alpha(parts[at])) || (parts[at].count == 3 && digit(parts[at]))) { at += 1 }
    var variants = Set<String>()
    while at < parts.count && (parts[at].count >= 5 || (parts[at].count == 4 && digit(String(parts[at].prefix(1))))) {
      guard variants.insert(parts[at]).inserted else { return false }; at += 1
    }
    var singletons = Set<String>()
    while at < parts.count && parts[at].count == 1 && parts[at] != "x" {
      guard singletons.insert(parts[at]).inserted else { return false }; at += 1
      let start = at
      while at < parts.count && parts[at].count >= 2 { at += 1 }
      if start == at { return false }
    }
    if at < parts.count && parts[at] == "x" { return at + 1 < parts.count }
    return at == parts.count
  }
  static func add(_ a: Int64, _ b: Int64) throws -> Int64 {
    let r = a.addingReportingOverflow(b)
    guard !r.overflow else { throw unsupported }; return r.partialValue
  }
  static func multiply(_ a: Int64, _ b: Int64) throws -> Int64 {
    let r = a.multipliedReportingOverflow(by: b)
    guard !r.overflow else { throw unsupported }; return r.partialValue
  }
  /// Exact nonnegative rational conversion. Reduce both numerator factors before
  /// multiplication, so representable results never fail on an intermediate product.
  static func rescaleExact(_ value: Int64, from: Int64, to: Int64) throws -> Int64 {
    guard value >= 0, from > 0, to > 0 else { throw unsupported }
    func gcd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
      var a = lhs, b = rhs
      while b != 0 { let remainder = a % b; a = b; b = remainder }
      return a
    }
    let first = gcd(value, from)
    let numerator = value / first, denominator = from / first
    let second = gcd(to, denominator)
    guard denominator / second == 1 else { throw unsupported }
    return try multiply(numerator, to / second)
  }
  static func number(_ value: String?, default fallback: Int64? = nil) throws -> Int64 {
    guard let value = value else {
      guard let fallback = fallback else { throw unsupported }; return fallback
    }
    guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
          let result = Int64(value) else { throw unsupported }
    return result
  }
  static func duration(_ value: String) throws -> Int64 {
    // Fixed day/hour/minute/second durations only; no calendar or floating arithmetic.
    let pattern = #"^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)(?:\.(\d{1,6}))?S)?)?$"#
    let regex = try NSRegularExpression(pattern: pattern)
    let ns = value as NSString
    guard let m = regex.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)),
          (1...4).contains(where: { m.range(at: $0).location != NSNotFound }) else { throw unsupported }
    var seconds: Int64 = 0
    for (i, multiplier) in [(1, Int64(86400)), (2, 3600), (3, 60), (4, 1)] {
      if m.range(at: i).location != NSNotFound {
        seconds = try add(seconds, multiply(number(ns.substring(with: m.range(at: i))), multiplier))
      }
    }
    var us = try multiply(seconds, 1_000_000)
    if m.range(at: 5).location != NSNotFound {
      let fraction = ns.substring(with: m.range(at: 5))
      us = try add(us, number(fraction + String(repeating: "0", count: 6 - fraction.count)))
    }
    return us
  }
  static func url(_ value: String, relativeTo base: URL? = nil) throws -> URL {
    guard !value.isEmpty, value.utf16.count <= maxURI,
          !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
          let result = URL(string: value, relativeTo: base)?.absoluteURL,
          result.absoluteString.utf16.count <= maxURI,
          ["http", "https"].contains(result.scheme?.lowercased() ?? ""),
          result.host?.isEmpty == false, result.user == nil, result.password == nil,
          result.fragment == nil else { throw unsupported }
    return result
  }
}

final class YlDashXMLReader: NSObject, XMLParserDelegate {
  // Addressing/timing nodes are a closed subset. Validate each declaration before
  // inheritance, so an unsupported ancestor cannot disappear under an override.
  private static let segmentAttributes: [String: Set<String>] = [
    "SegmentTemplate": ["timescale", "presentationTimeOffset", "duration", "startNumber", "initialization", "media"],
    "SegmentBase": ["timescale", "presentationTimeOffset", "indexRange", "indexRangeExact"],
    "SegmentList": ["timescale", "presentationTimeOffset", "duration", "startNumber"],
    "SegmentTimeline": [],
    "S": ["t", "d", "r"],
  ]
  private var namespaceBindings: [String: String] = [:]
  func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
    namespaceBindings[prefix] = namespaceURI
  }
  func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
    namespaceBindings.removeValue(forKey: prefix)
  }
  var allowSegmentBase = false
  var root: YlDashNode?
  var stack: [YlDashNode] = []
  var count = 0
  var invalid = false
  var rejection: YlDashAdmissionError?
  func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes: [String: String]) {
    count += 1
    let forbidden: Set<String> = ["ContentProtection", "SegmentBase", "UTCTiming", "Location",
      "PatchLocation", "ContentSteering", "EssentialProperty", "Subset", "SubRepresentation",
      "SegmentURLIndex", "RepresentationIndex", "BitstreamSwitching"]
    guard count <= 100_000, stack.count < 64,
          namespaceURI == nil || namespaceURI == "" || namespaceURI == "urn:mpeg:dash:schema:mpd:2011" else {
      invalid = true; parser.abortParsing(); return
    }
    if forbidden.contains(name) && !(name == "SegmentBase" && allowSegmentBase) {
      if root?.name == "MPD" {
        if name == "ContentProtection" { rejection = .protectedManifest }
        if name == "SegmentBase" { rejection = .segmentBase }
      }
      invalid = true; parser.abortParsing(); return
    }
    // XML Schema location is inert root metadata. Never fetch it, and do not
    // admit arbitrary qualified attributes or a spoofed namespace binding.
    func isSchemaLocation(_ attribute: String) -> Bool {
      let pieces = attribute.split(separator: ":", omittingEmptySubsequences: false)
      return root == nil && name == "MPD" && pieces.count == 2 && pieces[1] == "schemaLocation" &&
        namespaceBindings[String(pieces[0])] == "http://www.w3.org/2001/XMLSchema-instance"
    }
    guard !attributes.keys.contains(where: { $0.contains(":") && !$0.hasPrefix("xmlns") && !isSchemaLocation($0) }),
          !attributes.keys.contains(where: { ["availabilityTimeOffset", "availabilityTimeComplete", "index"].contains($0) || ($0 == "indexRange" && !(name == "SegmentBase" && allowSegmentBase)) }) else {
      invalid = true; parser.abortParsing(); return
    }
    if let allowed = Self.segmentAttributes[name],
       !attributes.keys.allSatisfy({ allowed.contains($0) || $0 == "xmlns" || $0.hasPrefix("xmlns:") }) {
      invalid = true; parser.abortParsing(); return
    }
    let node = YlDashNode(name, attributes)
    if let parent = stack.last { parent.children.append(node) }
    else if root == nil { root = node }
    else { invalid = true; parser.abortParsing(); return }
    stack.append(node)
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) {
    // Only BaseURL carries meaningful text. Input byte cap bounds all other text.
    if stack.last?.name == "BaseURL" {
      guard (stack.last?.text.utf16.count ?? 0) + string.utf16.count <= YlDashBounds.maxURI else {
        invalid = true; parser.abortParsing(); return
      }
      stack.last?.text += string
    }
  }
  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
    if !stack.isEmpty { stack.removeLast() }
  }
  static func parse(_ data: Data, allowSegmentBase: Bool = false) throws -> YlDashNode {
    guard data.count <= YlDashBounds.maxDocument else { throw YlDashAdmissionError.manifestTooLarge }
    guard let text = String(data: data, encoding: .utf8) else { throw YlDashAdmissionError.invalidManifest }
    guard !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { throw YlDashBounds.unsupported }
    let reader = YlDashXMLReader()
    reader.allowSegmentBase = allowSegmentBase
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.shouldReportNamespacePrefixes = true
    parser.shouldResolveExternalEntities = false
    parser.delegate = reader
    let parsed = parser.parse()
    if let rejection = reader.rejection { throw rejection }
    // An intentional policy abort is not evidence of malformed XML.
    guard !reader.invalid else { throw YlDashBounds.unsupported }
    guard parsed else { throw YlDashAdmissionError.invalidManifest }
    guard let root = reader.root, root.name == "MPD" else { throw YlDashBounds.unsupported }
    return root
  }
}

struct YlDashResource {
  let url: URL
  let range: String?
}
struct YlDashSegment {
  let resource: YlDashResource
  let ticks: Int64
  let scale: Int64
  func aligned(with other: YlDashSegment) -> Bool {
    // Reduce before comparing: neither Double rounding nor cross-product overflow.
    func gcd(_ a: Int64, _ b: Int64) -> Int64 {
      var a = a; var b = b
      while b != 0 { let remainder = a % b; a = b; b = remainder }
      return a
    }
    let left = gcd(ticks, scale), right = gcd(other.ticks, other.scale)
    return ticks / left == other.ticks / right && scale / left == other.scale / right
  }
}
/// Reduced rational media origin; equality is exact without cross multiplication.
struct YlDashMediaOrigin: Equatable {
  let ticks: Int64
  let scale: Int64
  init(ticks: Int64, scale: Int64) {
    var a = ticks, b = scale
    while b != 0 { let remainder = a % b; a = b; b = remainder }
    self.ticks = ticks / a; self.scale = scale / a
  }
}
struct YlDashTrack {
  let contentId: String
  let language: String?
  /// A content/configuration identity, independent of URLs and XML ordering.
  var audioIdentity: String {
    let fields = [contentId, language?.lowercased() ?? "", roles.joined(separator: ","), codec, String(samplingRate), channels]
    let key = fields.map { "\($0.utf8.count):\($0)" }.joined()
    return "dash-audio-" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  var audioLabel: String {
    ([language ?? "Audio"] + roles + (contentId.isEmpty ? [] : [contentId])).joined(separator: " · ")
  }
  let mediaOrigin: YlDashMediaOrigin
  let codec: String
  let width: Int64
  let height: Int64
  let samplingRate: Int64
  let channels: String
  let roles: [String]
  let bandwidth: Int64
  let frameRate: String?
  let squarePixels: Bool
  let hasRangeDeclaration: Bool
  let initialization: YlDashResource
  let segments: [YlDashSegment]
  func matches(_ other: YlDashTrack) -> Bool {
    codec == other.codec && width == other.width && height == other.height
      && samplingRate == other.samplingRate && channels == other.channels && roles == other.roles
  }
}
struct YlDashPeriod {
  let startUs: Int64
  let endUs: Int64
  let videos: [YlDashTrack]
  let audios: [YlDashTrack]
}

final class YlDashDocument {
  let source: URL
  var stripped = Set<String>()
  private var uriUnits = 0
  private var segmentCount = 0
  private var representationCount = 0
  private let indexes: [YlDashIndexRequest: YlDashResolvedIndex]
  init(source: URL, indexes: [YlDashIndexRequest: YlDashResolvedIndex] = [:]) {
    self.source = source; self.indexes = indexes
  }
  /// Discovery is bounded and network-free; full track/timeline admission still
  /// happens for every original representation before any quality projection.
  func indexRequests(_ data: Data, final: URL, credentialsStripped: Bool) throws -> [YlDashIndexRequest] {
    let root = try YlDashXMLReader.parse(data, allowSegmentBase: true)
    if root.attributes["type"] == "dynamic" { throw YlDashAdmissionError.dynamicManifest }
    guard root.attributes["type", default: "static"] == "static" else { throw YlDashBounds.unsupported }
    let roots = try base(root, (final, credentialsStripped || YlRequestOrigin(url: final) != YlRequestOrigin(url: source)))
    let periods = root.nodes("Period")
    guard !periods.isEmpty, periods.count <= 64 else { throw YlDashBounds.unsupported }
    var result: [YlDashIndexRequest] = []
    var seen = Set<YlDashIndexRequest>(), count = 0, byteCount = 0
    for period in periods {
      let periodBase = try base(period, roots)
      for adaptation in period.nodes("AdaptationSet") {
        let adaptationBase = try base(adaptation, periodBase)
        for representation in adaptation.nodes("Representation") {
          count += 1
          guard count <= YlDashBounds.maxRepresentations else { throw YlDashBounds.unsupported }
          let info = try segmentInfo([root, period, adaptation, representation])
          if info.mode != "SegmentBase" { continue }
          let location = try base(representation, adaptationBase)
          let request = try indexRequest(info, location)
          if seen.insert(request).inserted {
            guard request.length <= 4 * 1024 * 1024 - byteCount else { throw YlDashSidxError.limitExceeded }
            byteCount += request.length; result.append(request)
          }
        }
      }
    }
    return result
  }
  private func indexRequest(_ info: SegmentInfo, _ location: (URL, Bool)) throws -> YlDashIndexRequest {
    guard let range = info.attributes["indexRange"], info.initialization != nil,
      info.attributes["indexRangeExact"] == nil || ["true", "false", "1", "0"].contains(info.attributes["indexRangeExact"]!) else { throw YlDashAdmissionError.segmentBase }
    let resource = try resource(nil, range, location)
    let parts = resource.range!.split(separator: "@")
    let length = Int(parts[0])!, start = Int64(parts[1])!
    guard length <= YlDashSidx.maxIndexBytes else { throw YlDashSidxError.limitExceeded }
    return YlDashIndexRequest(url: resource.url, start: start, length: length,
      credentialsStripped: stripped.contains(resource.url.absoluteString))
  }
  private func record(_ value: String, base: URL, inherited: Bool, isResource: Bool = true) throws -> URL {
    let url = try YlDashBounds.url(value, relativeTo: base)
    let units = url.absoluteString.utf16.count
    guard units <= YlDashBounds.maxTotalURI - uriUnits else { throw YlDashBounds.unsupported }
    uriUnits += units
    if isResource && (inherited || YlRequestOrigin(url: url) != YlRequestOrigin(url: source)) { stripped.insert(url.absoluteString) }
    return url
  }
  private func base(_ node: YlDashNode, _ parent: (URL, Bool)) throws -> (URL, Bool) {
    guard let element = try node.one("BaseURL") else { return parent }
    let url = try record(element.text.trimmingCharacters(in: .whitespacesAndNewlines), base: parent.0, inherited: parent.1, isResource: false)
    return (url, parent.1 || YlRequestOrigin(url: url) != YlRequestOrigin(url: source))
  }
  func parse(_ data: Data, final: URL, credentialsStripped: Bool) throws -> ([YlDashPeriod], Int64) {
    _ = try YlDashBounds.url(source.absoluteString); _ = try YlDashBounds.url(final.absoluteString)
    let root = try YlDashXMLReader.parse(data, allowSegmentBase: !indexes.isEmpty)
    if root.attributes["type"] == "dynamic" { throw YlDashAdmissionError.dynamicManifest }
    guard root.attributes["type", default: "static"] == "static" else { throw YlDashBounds.unsupported }
    let total = try root.attributes["mediaPresentationDuration"].map(YlDashBounds.duration)
    let roots = try base(root, (final, credentialsStripped || YlRequestOrigin(url: final) != YlRequestOrigin(url: source)))
    let periods = root.nodes("Period")
    guard !periods.isEmpty, periods.count <= 64 else { throw YlDashBounds.unsupported }
    var end: Int64 = 0
    var result: [YlDashPeriod] = []
    for (index, period) in periods.enumerated() {
      let start = try period.attributes["start"].map(YlDashBounds.duration) ?? end
      guard start == end else { throw YlDashBounds.unsupported }
      let nextStart = try (index + 1 < periods.count ? periods[index + 1].attributes["start"] : nil).map(YlDashBounds.duration)
      let declaredDuration = try period.attributes["duration"].map(YlDashBounds.duration)
        ?? nextStart.map { $0 - start } ?? (index + 1 == periods.count ? total.map { $0 - start } : nil)
      let duration: Int64
      if let declaredDuration { duration = declaredDuration }
      else {
        guard index + 1 == periods.count else { throw YlDashBounds.unsupported }
        duration = try inferredDuration(root, period)
      }
      guard duration > 0 else { throw YlDashBounds.unsupported }
      end = try YlDashBounds.add(start, duration)
      let periodBase = try base(period, roots)
      var videos: [YlDashTrack] = []; var audios: [YlDashTrack] = []
      var audioContentIds = Set<String>()
      for adaptation in period.nodes("AdaptationSet") {
        let representations = adaptation.nodes("Representation")
        guard !representations.isEmpty,
              representations.count <= YlDashBounds.maxVideoVariants,
              representations.count <= YlDashBounds.maxRepresentations - representationCount else { throw YlDashBounds.unsupported }
        representationCount += representations.count
        let adaptationBase = try base(adaptation, periodBase)
        var tracks: [YlDashTrack] = []
        var adaptationKind: String?
        for representation in representations {
          let ancestors = [root, period, adaptation, representation]
          var attributes: [String: String] = [:]
          for node in [adaptation, representation] { attributes.merge(node.attributes) { _, new in new } }
          let mime = attributes["mimeType"]
          let kind = attributes["contentType"] ?? (mime == "video/mp4" ? "video" : mime == "audio/mp4" ? "audio" : "")
          guard kind == "video" || kind == "audio", mime == nil || mime == "\(kind)/mp4",
                adaptationKind == nil || adaptationKind == kind else { throw YlDashBounds.unsupported }
          adaptationKind = kind
          if representations.count > 1 {
            // Do not silently turn format/range descriptors into an AVC/SDR promise.
            guard kind == "video", ancestors.allSatisfy({ $0.nodes("SupplementalProperty").isEmpty }),
                  !ancestors.contains(where: { node in
                    ["videoRange", "colourPrimaries", "transferCharacteristics", "matrixCoefficients"].contains(where: { node.attributes[$0] != nil })
                  }) else { throw YlDashBounds.unsupported }
          }
          let location = try base(representation, adaptationBase)
          tracks.append(try buildTrack(ancestors, attributes, kind, duration, location))
        }
        if adaptationKind == "video" {
          guard videos.isEmpty else { throw YlDashBounds.unsupported }
          videos = tracks
        } else {
          guard tracks.count == 1, audios.count < YlDashBounds.maxAudioTracks else { throw YlDashBounds.unsupported }
          let audio = tracks[0]
          if !audio.contentId.isEmpty {
            guard audioContentIds.insert(audio.contentId).inserted else { throw YlDashBounds.unsupported }
          }
          guard !audios.contains(where: { $0.audioIdentity == audio.audioIdentity }) else { throw YlDashBounds.unsupported }
          audios.append(audio)
        }
      }
      guard let firstVideo = videos.first,
        videos.allSatisfy({ $0.mediaOrigin == firstVideo.mediaOrigin }),
        audios.allSatisfy({ $0.mediaOrigin == firstVideo.mediaOrigin }) else { throw YlDashBounds.unsupported }
      if videos.count > 1 {
        let first = videos[0]
        for (index, track) in videos.enumerated() {
          guard track.codec == first.codec, track.roles == first.roles,
                track.segments.count == first.segments.count,
                zip(track.segments, first.segments).allSatisfy({ $0.aligned(with: $1) }),
                !videos.prefix(index).contains(where: { track.matches($0) && track.bandwidth == $0.bandwidth }) else { throw YlDashBounds.unsupported }
        }
        // Stable quality identity, independent of XML ordering and Representation IDs.
        videos.sort { ($0.width, $0.height, $0.bandwidth) < ($1.width, $1.height, $1.bandwidth) }
      }
      if let previous = result.last {
        guard Set(audios.map(\.audioIdentity)) == Set(previous.audios.map(\.audioIdentity)) else { throw YlDashBounds.unsupported }
      }
      // Main first, then a stable identity order. Reordered Periods never swap audio.
      audios.sort {
        let left = $0.roles.isEmpty || $0.roles.contains("main")
        let right = $1.roles.isEmpty || $1.roles.contains("main")
        return left != right ? left : $0.audioIdentity < $1.audioIdentity
      }
      result.append(YlDashPeriod(startUs: start, endUs: end, videos: videos, audios: audios))
    }
    guard total == nil || total == end else { throw YlDashBounds.unsupported }
    return (result, end)
  }
  private struct SegmentInfo {
    let mode: String
    let attributes: [String: String]
    let timeline: YlDashNode?
    let initialization: YlDashNode?
    let urls: [YlDashNode]
  }
  private func segmentInfo(_ ancestors: [YlDashNode]) throws -> SegmentInfo {
    var mode: String?; var segmentAttrs: [String: String] = [:]
    var timeline: YlDashNode?; var initialization: YlDashNode?; var urls: [YlDashNode] = []
    for node in ancestors {
      for name in ["SegmentTemplate", "SegmentList", "SegmentBase"] {
        if let segment = try node.one(name) {
          if name == "SegmentBase" {
            guard segment.children.allSatisfy({ $0.name == "Initialization" }) else { throw YlDashBounds.unsupported }
          }
          guard mode == nil || mode == name else { throw YlDashBounds.unsupported }; mode = name
          segmentAttrs.merge(segment.attributes) { _, new in new }
          if let value = try segment.one("SegmentTimeline") { timeline = value }
          if let value = try segment.one("Initialization") { initialization = value }
          if !segment.nodes("SegmentURL").isEmpty { urls = segment.nodes("SegmentURL") }
        }
      }
    }
    guard let mode = mode else { throw YlDashBounds.unsupported }
    return SegmentInfo(mode: mode, attributes: segmentAttrs, timeline: timeline,
      initialization: initialization, urls: urls)
  }
  private struct TimelineRun {
    let start: Int64
    let duration: Int64
    let count: Int64
  }
  // Used by both duration inference and media expansion. Never expand repetitions here.
  private func timelineRuns(_ timeline: YlDashNode, offset: Int64, end: Int64?,
    budget: Int) throws -> [TimelineRun] {
    let entries = timeline.nodes("S")
    guard entries.count == timeline.children.count, !entries.isEmpty else { throw YlDashBounds.unsupported }
    var cursor = offset, remaining = Int64(budget)
    var runs: [TimelineRun] = []
    for (index, entry) in entries.enumerated() {
      let t = try YlDashBounds.number(entry.attributes["t"], default: index == 0 ? 0 : cursor)
      let d = try YlDashBounds.number(entry.attributes["d"])
      guard t == cursor, d > 0 else { throw YlDashBounds.unsupported }
      let count: Int64
      if entry.attributes["r"] == "-1" {
        let boundary: Int64
        if index + 1 < entries.count { boundary = try YlDashBounds.number(entries[index + 1].attributes["t"]) }
        else if let end { boundary = end }
        else { throw YlDashBounds.unsupported }
        guard boundary > t, (boundary - t) % d == 0 else { throw YlDashBounds.unsupported }
        count = (boundary - t) / d
      } else { count = try YlDashBounds.add(YlDashBounds.number(entry.attributes["r"], default: 0), 1) }
      guard count > 0, count <= remaining else { throw YlDashBounds.unsupported }
      cursor = try YlDashBounds.add(t, YlDashBounds.multiply(d, count))
      guard end == nil || cursor <= end! else { throw YlDashBounds.unsupported }
      remaining -= count
      runs.append(TimelineRun(start: t, duration: d, count: count))
    }
    guard end == nil || cursor == end! else { throw YlDashBounds.unsupported }
    return runs
  }
  private func inferredDuration(_ root: YlDashNode, _ period: YlDashNode) throws -> Int64 {
    var duration: Int64?
    var remaining = YlDashBounds.maxSegments - segmentCount
    var representations = 0
    for adaptation in period.nodes("AdaptationSet") {
      let tracks = adaptation.nodes("Representation")
      guard !tracks.isEmpty, tracks.count <= YlDashBounds.maxVideoVariants,
        tracks.count <= YlDashBounds.maxRepresentations - representationCount - representations else { throw YlDashBounds.unsupported }
      representations += tracks.count
      for track in tracks {
        let info = try segmentInfo([root, period, adaptation, track])
        guard let timeline = info.timeline else { throw YlDashBounds.unsupported }
        let scale = try YlDashBounds.number(info.attributes["timescale"], default: 1)
        let offset = try YlDashBounds.number(info.attributes["presentationTimeOffset"], default: 0)
        guard scale > 0 else { throw YlDashBounds.unsupported }
        let runs = try timelineRuns(timeline, offset: offset, end: nil, budget: remaining)
        let last = runs.last!
        let end = try YlDashBounds.add(last.start, YlDashBounds.multiply(last.duration, last.count))
        let candidate = try YlDashBounds.rescaleExact(end - offset, from: scale, to: 1_000_000)
        guard candidate > 0 else { throw YlDashBounds.unsupported }
        guard duration == nil || duration == candidate else { throw YlDashBounds.unsupported }
        duration = candidate
        for run in runs { remaining -= Int(run.count) }
      }
    }
    guard let duration else { throw YlDashBounds.unsupported }
    return duration
  }
  private func buildTrack(_ ancestors: [YlDashNode], _ attrs: [String: String], _ kind: String,
    _ duration: Int64, _ location: (URL, Bool)) throws -> YlDashTrack {
    guard let codec = attrs["codecs"],
      (kind == "video" ? codec.range(of: #"^avc[13]\.[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil : codec == "mp4a.40.2") else { throw YlDashBounds.unsupported }
    let width = try YlDashBounds.number(attrs["width"], default: 0)
    let height = try YlDashBounds.number(attrs["height"], default: 0)
    let rate = try YlDashBounds.number(attrs["audioSamplingRate"], default: 0)
    let bandwidth = try YlDashBounds.number(attrs["bandwidth"])
    guard bandwidth > 0, bandwidth <= 1_000_000_000, (kind == "video" ? width > 0 && height > 0 && width <= 65535 && height <= 65535 : rate > 0 && rate <= 768000) else { throw YlDashBounds.unsupported }
    var channels = ""
    var roles: [String] = []
    for node in ancestors {
      for role in node.nodes("Role") {
        guard role.attributes["schemeIdUri", default: "urn:mpeg:dash:role:2011"] == "urn:mpeg:dash:role:2011",
              let value = role.attributes["value"],
              ["main", "alternate", "supplementary", "commentary", "dub", "caption", "subtitle", "description", "enhanced-audio-intelligibility", "emergency"].contains(value) else { throw YlDashBounds.unsupported }
        roles.append(value)
      }
      if let config = try node.one("AudioChannelConfiguration") {
        guard config.attributes["schemeIdUri"] == "urn:mpeg:dash:23003:3:audio_channel_configuration:2011" else { throw YlDashBounds.unsupported }
        let number = try YlDashBounds.number(config.attributes["value"])
        guard number > 0, number <= 8 else { throw YlDashBounds.unsupported }; channels = String(number)
      }
    }
    let info = try segmentInfo(ancestors)
    let mode = info.mode, segmentAttrs = info.attributes
    let timeline = info.timeline, initialization = info.initialization, urls = info.urls
    var scale = try YlDashBounds.number(segmentAttrs["timescale"], default: 1)
    guard scale > 0 else { throw YlDashBounds.unsupported }
    var offset = try YlDashBounds.number(segmentAttrs["presentationTimeOffset"], default: 0)
    var indexed: YlDashResolvedIndex?
    if mode == "SegmentBase" {
      let request = try indexRequest(info, location)
      guard let resolved = indexes[request],
        resolved.index.earliestPresentationTimeTicks <= UInt64(Int64.max) else { throw YlDashBounds.unsupported }
      let indexScale = Int64(resolved.index.timescale)
      let indexOffset = Int64(resolved.index.earliestPresentationTimeTicks)
      guard YlDashMediaOrigin(ticks: offset, scale: scale) == YlDashMediaOrigin(ticks: indexOffset, scale: indexScale) else { throw YlDashBounds.unsupported }
      scale = indexScale; offset = indexOffset; indexed = resolved
    }
    guard offset == 0 || timeline != nil || indexed != nil else { throw YlDashBounds.unsupported }
    let total = try YlDashBounds.rescaleExact(duration, from: 1_000_000, to: scale)
    let sampleEnd = try YlDashBounds.add(offset, total)
    var samples: [(Int64, Int64)] = []
    func append(_ start: Int64, _ d: Int64, _ count: Int64) throws {
      guard d > 0, count > 0, count <= Int64(YlDashBounds.maxSegments - segmentCount),
        try YlDashBounds.add(start, YlDashBounds.multiply(d, count)) <= sampleEnd else { throw YlDashBounds.unsupported }
      segmentCount += Int(count)
      for i in 0..<count { samples.append((try YlDashBounds.add(start, YlDashBounds.multiply(i, d)), d)) }
    }
    if let indexed {
      var time = offset
      for reference in indexed.index.references {
        guard reference.startsWithSAP, reference.sapType == 1, reference.sapDeltaTicks == 0,
          reference.offset <= UInt64(Int64.max), reference.length <= UInt64(Int64.max),
          reference.offset + reference.length <= UInt64(indexed.resourceLength) else { throw YlDashBounds.unsupported }
        try append(time, Int64(reference.durationTicks), 1)
        time = try YlDashBounds.add(time, Int64(reference.durationTicks))
      }
      guard time == sampleEnd else { throw YlDashBounds.unsupported }
    } else if let timeline = timeline {
      for run in try timelineRuns(timeline, offset: offset, end: sampleEnd,
        budget: YlDashBounds.maxSegments - segmentCount) {
        try append(run.start, run.duration, run.count)
      }
    } else {
      let d = try YlDashBounds.number(segmentAttrs["duration"])
      guard d > 0, total % d == 0 else { throw YlDashBounds.unsupported }
      try append(0, d, total / d)
    }
    let startNumber = try YlDashBounds.number(segmentAttrs["startNumber"], default: 1)
    let id = attrs["id", default: ""]
    let initResource: YlDashResource
    var segments: [YlDashSegment] = []
    if let indexed {
      guard let initialization, initialization.attributes["range"] != nil,
        initialization.attributes.keys.allSatisfy({ ["sourceURL", "range"].contains($0) }) else { throw YlDashBounds.unsupported }
      let originalInit = try resource(initialization.attributes["sourceURL"], initialization.attributes["range"], location)
      if originalInit.url == location.0 {
        initResource = YlDashResource(url: try record(indexed.effectiveURL.absoluteString,
          base: location.0, inherited: location.1 || indexed.credentialsStripped), range: originalInit.range)
      } else { initResource = originalInit }
      if initResource.url == indexed.effectiveURL, let range = initResource.range {
        let parts = range.split(separator: "@")
        guard try YlDashBounds.add(Int64(parts[0])!, Int64(parts[1])!) <= indexed.resourceLength else { throw YlDashBounds.unsupported }
      }
      for reference in indexed.index.references {
        let url = try record(indexed.effectiveURL.absoluteString, base: location.0,
          inherited: location.1 || indexed.credentialsStripped)
        segments.append(YlDashSegment(resource: .init(url: url, range: "\(reference.length)@\(reference.offset)"),
          ticks: Int64(reference.durationTicks), scale: scale))
      }
    } else if mode == "SegmentTemplate" {
      guard let initTemplate = segmentAttrs["initialization"], let media = segmentAttrs["media"] else { throw YlDashBounds.unsupported }
      let initName = try template(initTemplate, id: id, bandwidth: bandwidth, number: nil, time: nil)
      initResource = YlDashResource(url: try record(initName, base: location.0, inherited: location.1), range: nil)
      for (i, sample) in samples.enumerated() {
        let name = try template(media, id: id, bandwidth: bandwidth, number: YlDashBounds.add(startNumber, Int64(i)), time: sample.0)
        segments.append(YlDashSegment(resource: YlDashResource(url: try record(name, base: location.0, inherited: location.1), range: nil), ticks: sample.1, scale: scale))
      }
    } else {
      guard let initialization = initialization, urls.count == samples.count else { throw YlDashBounds.unsupported }
      initResource = try resource(initialization.attributes["sourceURL"], initialization.attributes["range"], location)
      for (i, node) in urls.enumerated() {
        guard node.attributes["index"] == nil, node.attributes["indexRange"] == nil else { throw YlDashBounds.unsupported }
        segments.append(YlDashSegment(resource: try resource(node.attributes["media"], node.attributes["mediaRange"], location), ticks: samples[i].1, scale: scale))
      }
    }
    let contentId = kind == "audio" ? ancestors[2].attributes["id", default: ""] : ""
    let language = kind == "audio" ? attrs["lang"] : nil
    guard contentId.utf8.count <= 128,
      !contentId.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw YlDashBounds.unsupported }
    if let language {
      guard YlDashBounds.audioLanguage(language) else { throw YlDashBounds.unsupported }
    }
    return YlDashTrack(contentId: contentId, language: language, mediaOrigin: .init(ticks: offset, scale: scale), codec: codec, width: width, height: height, samplingRate: rate,
      channels: channels, roles: kind == "audio" ? Array(Set(roles)).sorted() : roles.sorted(), bandwidth: bandwidth,
      frameRate: attrs["frameRate"],
      squarePixels: ancestors.allSatisfy { $0.attributes["sar"] == nil || $0.attributes["sar"] == "1:1" },
      hasRangeDeclaration: ancestors.contains { node in
        !node.nodes("SupplementalProperty").isEmpty ||
          ["videoRange", "colourPrimaries", "transferCharacteristics", "matrixCoefficients"].contains { node.attributes[$0] != nil }
      }, initialization: initResource, segments: segments)
  }
  private func resource(_ name: String?, _ range: String?, _ location: (URL, Bool)) throws -> YlDashResource {
    // An omitted/empty SegmentList reference identifies the effective base itself.
    // Keep recording it as a resource: budgets and sticky credential stripping apply.
    let reference = (name == nil || name == "") ? location.0.absoluteString : name!
    var normalized: String?
    if let range = range {
      let parts = range.split(separator: "-", omittingEmptySubsequences: false)
      guard parts.count == 2 else { throw YlDashBounds.unsupported }
      let start = try YlDashBounds.number(String(parts[0])); let end = try YlDashBounds.number(String(parts[1]))
      guard end >= start else { throw YlDashBounds.unsupported }
      normalized = "\(try YlDashBounds.add(end - start, 1))@\(start)"
    }
    return YlDashResource(url: try record(reference, base: location.0, inherited: location.1), range: normalized)
  }
  private func template(_ value: String, id: String, bandwidth: Int64, number: Int64?, time: Int64?) throws -> String {
    guard value.utf16.count <= YlDashBounds.maxURI else { throw YlDashBounds.unsupported }
    let parts = value.components(separatedBy: "$")
    guard parts.count % 2 == 1 else { throw YlDashBounds.unsupported }
    var output = ""
    for (index, part) in parts.enumerated() {
      let addition: String
      if index % 2 == 0 { addition = part }
      else if part.isEmpty { addition = "$" }
      else if part == "RepresentationID" { guard !id.isEmpty else { throw YlDashBounds.unsupported }; addition = id }
      else {
        let fields = part.components(separatedBy: "%")
        guard fields.count <= 2 else { throw YlDashBounds.unsupported }
        let n: Int64?
        switch fields[0] { case "Bandwidth": n = bandwidth; case "Number": n = number; case "Time": n = time; default: n = nil }
        guard let n = n else { throw YlDashBounds.unsupported }
        var width = 0
        if fields.count == 2 {
          let format = fields[1]
          guard format.hasPrefix("0"), format.hasSuffix("d"), format.count <= 4 else { throw YlDashBounds.unsupported }
          let parsed = try YlDashBounds.number(String(format.dropFirst().dropLast()))
          guard parsed > 0, parsed <= 20 else { throw YlDashBounds.unsupported }; width = Int(parsed)
        }
        let digits = String(n); addition = String(repeating: "0", count: max(0, width - digits.count)) + digits
      }
      guard addition.utf16.count <= YlDashBounds.maxURI - output.utf16.count else { throw YlDashBounds.unsupported }
      output += addition
    }
    return output
  }
}
